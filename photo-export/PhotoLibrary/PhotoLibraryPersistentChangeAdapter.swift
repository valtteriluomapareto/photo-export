import Combine
import Foundation
import Photos
import os

/// Production `PhotoLibraryChangeProviding`. Bridges PhotoKit's
/// `PHPhotoLibraryChangeObserver` callbacks plus
/// `PHPhotoLibrary.fetchPersistentChanges(since:)` into the
/// `Result`-typed publisher AutoSync consumes.
///
/// **Lifecycle.** Owned by `PhotoExportApp` for the app's lifetime. `start()`
/// registers as a PhotoKit observer and runs an immediate catch-up fetch — any
/// changes that landed while the app was quit are observed before the first user
/// interaction. `stop()` unregisters; tests call it on tear-down.
///
/// **Token persistence.** The adapter owns the *global* persistent-change
/// cursor: the most recent token it has consumed. Persisted via
/// `GlobalPhotoChangeTokenStore` (file-backed). On launch the persisted token
/// becomes the `since:` argument for catch-up. The per-destination
/// `lastDurablyRecordedToken` is a separate concept tracked by the reducer's
/// `advancePersistentChangeToken` effect after dirty IDs are durably written.
///
/// **Error mapping.** Plan §"Photo Library Changes" requires that the three
/// fetch failure modes (token-expired, token-invalid, details-unavailable) are
/// surfaced individually. We map `PHPhotosError.persistentChangeTokenExpired`
/// and `.persistentChangeDetailsUnavailable` directly; any other PhotoKit error
/// becomes `.tokenInvalid` so logs distinguish "OS recycled the token" from "we
/// got something we didn't expect." After any failure we rebase to
/// `currentChangeToken` so the same error can't loop forever; the reducer
/// schedules a `photosChangeFallback` debounce in response.
@MainActor
final class PhotoLibraryPersistentChangeAdapter: NSObject, PhotoLibraryChangeProviding,
  PHPhotoLibraryChangeObserver, ObservableObject
{
  /// Default cadence for the safety-net reconcile timer. macOS's
  /// `photoLibraryDidChange` callback can be silent for tens of minutes when
  /// Photos.app isn't running and iCloud syncs in the background (issue #69);
  /// fifteen minutes is short enough that a user who Cmd-tabs away for a
  /// coffee comes back to a fresh state, long enough that the periodic
  /// `fetchPersistentChanges` call is a rounding error on energy use.
  /// `nonisolated` so it's usable as a default-parameter value at non-actor
  /// call sites.
  nonisolated static let defaultReconcileInterval: TimeInterval = 15 * 60

  private let library: PHPhotoLibrary
  private let tokenStore: GlobalPhotoChangeTokenStore
  private let logger: Logger
  private let authorizationStatusPublisher: AnyPublisher<PHAuthorizationStatus, Never>?
  private let subject = PassthroughSubject<PhotoLibraryChangeOutcome, Never>()
  /// Notifies an external collaborator (production: `PhotoLibraryManager`) when a
  /// reconcile turned up actual changes, so the UI side can invalidate its caches
  /// and bump `libraryRevision`. AutoSync's own subscription is unaffected — it
  /// receives every successful event via `changes`. Optional because most tests
  /// don't need to observe the UI bridge.
  private let onPotentialLibraryChange: (@MainActor () -> Void)?
  private var lastToken: PHPersistentChangeToken?
  private var registered = false
  private var authorizationSubscription: AnyCancellable?
  private var scheduler: ReconciliationScheduler?

  /// Timestamp of the most recent successful `fetchPersistentChanges` call,
  /// whether or not it turned up changes. Drives the "Last checked iCloud …"
  /// line in Settings → Auto Export so the user can see the safety-net
  /// reconcile is alive.
  @Published private(set) var lastSuccessfulReconciliation: Date?

  var authorizationStatus: PHAuthorizationStatus {
    PHPhotoLibrary.authorizationStatus(for: .readWrite)
  }

  var changes: AnyPublisher<PhotoLibraryChangeOutcome, Never> {
    subject.eraseToAnyPublisher()
  }

  /// `authorizationStatusPublisher` lets the adapter retry registration after
  /// the user grants access from inside the app — without it, an adapter
  /// `start()`-ed during `.notDetermined` would stay un-registered until the
  /// next launch. `nil` is acceptable in tests where the fake never observes
  /// auth state; production wires `PhotoLibraryManager.$authorizationStatus`.
  ///
  /// `clock` and `reconcileInterval` drive the periodic safety-net reconcile
  /// (issue #69). `onPotentialLibraryChange` is invoked after any reconcile
  /// that turned up actual changes so the UI side can wake alongside AutoSync;
  /// production wires it to `PhotoLibraryManager.invalidateCache()`.
  init(
    library: PHPhotoLibrary = .shared(),
    tokenStore: GlobalPhotoChangeTokenStore,
    authorizationStatusPublisher: AnyPublisher<PHAuthorizationStatus, Never>? = nil,
    clock: AutoSyncClock,
    reconcileInterval: TimeInterval = PhotoLibraryPersistentChangeAdapter.defaultReconcileInterval,
    onPotentialLibraryChange: (@MainActor () -> Void)? = nil,
    logger: Logger = Logger(
      subsystem: "com.valtteriluoma.photo-export", category: "PhotoLibraryChanges")
  ) {
    self.library = library
    self.tokenStore = tokenStore
    self.authorizationStatusPublisher = authorizationStatusPublisher
    self.onPotentialLibraryChange = onPotentialLibraryChange
    self.logger = logger
    self.lastToken = tokenStore.load()
    super.init()
    self.scheduler = ReconciliationScheduler(
      clock: clock, interval: reconcileInterval
    ) { [weak self] in
      self?.fetchAndEmit()
    }
  }

  /// Register with PhotoKit and run an immediate catch-up fetch for any
  /// changes that landed since the last persisted token. Idempotent — safe to
  /// call multiple times. When access is not yet sufficient, subscribes to
  /// the authorization-status publisher and self-starts on the first
  /// sufficient value, so the user granting access from inside the app
  /// activates observation without an explicit re-call.
  func start() {
    guard !registered else { return }
    if PhotoLibraryManager.isAuthorizationSufficient(authorizationStatus) {
      registerAndCatchUp()
      return
    }
    logger.debug("Photo library not authorized yet; deferring registration")
    if authorizationSubscription == nil, let publisher = authorizationStatusPublisher {
      authorizationSubscription = publisher.sink { [weak self] status in
        dispatchPrecondition(condition: .onQueue(.main))
        MainActor.assumeIsolated {
          guard let self, !self.registered,
            PhotoLibraryManager.isAuthorizationSufficient(status)
          else { return }
          self.registerAndCatchUp()
          // One-shot: stop listening once we've registered.
          self.authorizationSubscription?.cancel()
          self.authorizationSubscription = nil
        }
      }
    }
  }

  /// Unregister from PhotoKit. Idempotent. Tests call this on tear-down; the
  /// app does not need to call it because the adapter lives for the process
  /// lifetime.
  func stop() {
    authorizationSubscription?.cancel()
    authorizationSubscription = nil
    scheduler?.stop()
    guard registered else { return }
    library.unregisterChangeObserver(self)
    registered = false
  }

  private func registerAndCatchUp() {
    library.register(self)
    registered = true
    fetchAndEmit()
    // Arm the safety-net reconcile *after* the initial catch-up: the catch-up
    // already covers anything that landed pre-launch, and starting the
    // scheduler later means the first periodic fire is `interval` seconds away
    // rather than running back-to-back with the catch-up.
    scheduler?.start()
  }

  // MARK: - PHPhotoLibraryChangeObserver

  nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
    Task { @MainActor [weak self] in
      self?.fetchAndEmit()
    }
  }

  // MARK: - Private

  /// Fetches changes since the last token, emits a single outcome, and
  /// advances the persisted token. On first run with no token, captures
  /// `currentChangeToken` as the silent baseline.
  private func fetchAndEmit() {
    let baseline: PHPersistentChangeToken
    if let token = lastToken {
      baseline = token
    } else {
      let current = library.currentChangeToken
      lastToken = current
      tokenStore.save(current)
      // First-time baseline capture is still a successful reconcile from the
      // user's perspective: we successfully consulted PhotoKit and confirmed
      // there's nothing new to act on yet.
      lastSuccessfulReconciliation = Date()
      return
    }

    do {
      let result = try library.fetchPersistentChanges(since: baseline)
      var inserted: Set<String> = []
      var updated: Set<String> = []
      var deleted: Set<String> = []
      var collectionChangesPresent = false
      var newestToken = baseline
      var detailsFailures = 0

      for change in result {
        newestToken = change.changeToken
        do {
          let assetDetails = try change.changeDetails(for: PHObjectType.asset)
          inserted.formUnion(assetDetails.insertedLocalIdentifiers)
          updated.formUnion(assetDetails.updatedLocalIdentifiers)
          deleted.formUnion(assetDetails.deletedLocalIdentifiers)
        } catch {
          detailsFailures += 1
        }
        do {
          let collectionDetails = try change.changeDetails(for: PHObjectType.assetCollection)
          if !collectionDetails.insertedLocalIdentifiers.isEmpty
            || !collectionDetails.updatedLocalIdentifiers.isEmpty
            || !collectionDetails.deletedLocalIdentifiers.isEmpty
          {
            collectionChangesPresent = true
          }
        } catch {
          detailsFailures += 1
        }
      }

      if detailsFailures > 0 {
        logger.error(
          "Per-change detail fetches failed (count=\(detailsFailures, privacy: .public)); rebasing token"
        )
        rebaseTokenAfterFailure()
        subject.send(.failure(.detailsUnavailable))
        return
      }

      let nextTokenData = try? NSKeyedArchiver.archivedData(
        withRootObject: newestToken, requiringSecureCoding: true)

      let event = PhotoLibraryPersistentChangeEvent(
        insertedLocalIdentifiers: inserted,
        updatedLocalIdentifiers: updated,
        deletedLocalIdentifiers: deleted,
        collectionChangesPresent: collectionChangesPresent,
        observedAt: Date(),
        nextToken: nextTokenData
      )

      lastToken = newestToken
      tokenStore.save(newestToken)
      lastSuccessfulReconciliation = Date()
      subject.send(.success(event))
      // Nudge the UI side iff the reconcile turned up actual changes. AutoSync
      // already received the event via `subject`; this callback is the
      // independent wake-up for `PhotoLibraryManager.libraryRevision` so the
      // grid/sidebar refresh alongside without requiring a separate PhotoKit
      // observer in the manager (issue #69).
      if !inserted.isEmpty || !updated.isEmpty || !deleted.isEmpty || collectionChangesPresent {
        onPotentialLibraryChange?()
      }
    } catch {
      let mapped = mapFetchError(error)
      logger.error(
        "fetchPersistentChanges failed: \(error.localizedDescription, privacy: .public) → \(String(describing: mapped), privacy: .public)"
      )
      rebaseTokenAfterFailure()
      subject.send(.failure(mapped))
    }
  }

  /// After any fetch failure we rebase to `currentChangeToken` so the next
  /// observer callback starts from a fresh point and can't loop forever
  /// re-emitting the same failure for the same range. The reducer's fallback
  /// path performs a bounded full reconciliation to cover whatever we missed.
  private func rebaseTokenAfterFailure() {
    let current = library.currentChangeToken
    lastToken = current
    tokenStore.save(current)
  }

  private func mapFetchError(_ error: Error) -> PhotoLibraryPersistentChangeFetchError {
    let nsError = error as NSError
    guard nsError.domain == PHPhotosErrorDomain else {
      return .tokenInvalid
    }
    switch PHPhotosError.Code(rawValue: nsError.code) {
    case .persistentChangeTokenExpired:
      return .tokenExpired
    case .persistentChangeDetailsUnavailable:
      return .detailsUnavailable
    default:
      return .tokenInvalid
    }
  }
}
