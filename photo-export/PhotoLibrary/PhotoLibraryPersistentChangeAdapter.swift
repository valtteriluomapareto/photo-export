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

  /// Optional explicit injection (tests). Production callers leave it `nil`
  /// so the singleton is resolved lazily inside `library` — that defers the
  /// first `PHPhotoLibrary.shared()` evaluation out of `init` and into the
  /// `.task` block where `start()` runs. Issue #92: the synchronous singleton
  /// init was hanging launch on macOS 15.7+ when triggered from `App.init`.
  private let explicitLibrary: PHPhotoLibrary?
  private lazy var library: PHPhotoLibrary = explicitLibrary ?? PHPhotoLibrary.shared()
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
    library: PHPhotoLibrary? = nil,
    tokenStore: GlobalPhotoChangeTokenStore,
    authorizationStatusPublisher: AnyPublisher<PHAuthorizationStatus, Never>? = nil,
    clock: AutoSyncClock,
    reconcileInterval: TimeInterval = PhotoLibraryPersistentChangeAdapter.defaultReconcileInterval,
    onPotentialLibraryChange: (@MainActor () -> Void)? = nil,
    logger: Logger = Logger(
      subsystem: "com.valtteriluoma.photo-export", category: "PhotoLibraryChanges")
  ) {
    self.explicitLibrary = library
    self.tokenStore = tokenStore
    self.authorizationStatusPublisher = authorizationStatusPublisher
    self.onPotentialLibraryChange = onPotentialLibraryChange
    self.logger = logger
    self.lastToken = tokenStore.load()
    super.init()
    self.scheduler = ReconciliationScheduler(
      clock: clock, interval: reconcileInterval
    ) { [weak self] in
      self?.fetchAndEmit(trigger: .safetyNet)
    }
  }

  /// Register with PhotoKit and run an immediate catch-up fetch for any
  /// changes that landed since the last persisted token. Idempotent — safe to
  /// call multiple times. Subscribes to the authorization-status publisher
  /// and reacts to *both* transitions: insufficient → sufficient registers
  /// and arms the safety-net reconcile; sufficient → insufficient tears down
  /// the scheduler and unregisters from PhotoKit so the 15-minute timer
  /// doesn't keep calling `fetchPersistentChanges` on a now-revoked library
  /// (issue #69 follow-up).
  func start() {
    if PhotoLibraryManager.isAuthorizationSufficient(authorizationStatus) {
      registerAndCatchUp()
    } else {
      logger.debug("Photo library not authorized yet; deferring registration")
    }
    if authorizationSubscription == nil, let publisher = authorizationStatusPublisher {
      authorizationSubscription = publisher.sink { [weak self] status in
        dispatchPrecondition(condition: .onQueue(.main))
        MainActor.assumeIsolated {
          self?.handleAuthorizationChange(status)
        }
      }
    }
  }

  private func handleAuthorizationChange(_ status: PHAuthorizationStatus) {
    let sufficient = PhotoLibraryManager.isAuthorizationSufficient(status)
    if sufficient, !registered {
      registerAndCatchUp()
    } else if !sufficient, registered {
      tearDownPhotoKitObservation()
    }
  }

  /// Stop the safety-net timer and unregister the change observer without
  /// dropping the authorization subscription — a re-grant should restore
  /// both. Separate from `stop()` (which is the full tear-down used by
  /// tests). Idempotent.
  private func tearDownPhotoKitObservation() {
    scheduler?.stop()
    guard registered else { return }
    library.unregisterChangeObserver(self)
    registered = false
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
    fetchAndEmit(trigger: .startup)
    // Arm the safety-net reconcile *after* the initial catch-up: the catch-up
    // already covers anything that landed pre-launch, and starting the
    // scheduler later means the first periodic fire is `interval` seconds away
    // rather than running back-to-back with the catch-up.
    scheduler?.start()
  }

  // MARK: - PHPhotoLibraryChangeObserver

  nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
    Task { @MainActor [weak self] in
      self?.fetchAndEmit(trigger: .observer)
    }
  }

  /// Why `fetchAndEmit` is called. Distinguishes the *normal* PhotoKit observer
  /// path (which already triggers `PhotoLibraryManager.photoLibraryDidChange` →
  /// `invalidateCache()` independently) from the *safety-net* paths added for
  /// issue #69 (startup catch-up, 15-min timer, become-active). On the observer
  /// path the UI side has already been woken; firing
  /// `onPotentialLibraryChange` again would double-invalidate the manager's
  /// caches and bump `libraryRevision` twice per real event.
  private enum ReconcileTrigger {
    /// `photoLibraryDidChange` callback from PhotoKit. The manager has its own
    /// observer for the same notification — don't double-wake the UI.
    case observer
    /// Initial catch-up at `start()`. Manager hasn't observed anything yet
    /// for the missed range, so the bridge should fire.
    case startup
    /// Periodic timer or become-active notification (both routed through
    /// `ReconciliationScheduler`). The whole point of these triggers is that
    /// PhotoKit's observer was silent — bridge to wake the UI.
    case safetyNet
  }

  // MARK: - Private

  /// Fetches changes since the last token, emits a single outcome, and
  /// advances the persisted token. On first run with no token, captures
  /// `currentChangeToken` as the silent baseline.
  ///
  /// `trigger` controls whether the UI bridge fires on success-with-changes
  /// — see `ReconcileTrigger`. On the `.observer` path the manager has
  /// already invalidated its caches via its own `photoLibraryDidChange`
  /// callback, so this method skips the bridge to avoid double-bumping
  /// `libraryRevision`.
  private func fetchAndEmit(trigger: ReconcileTrigger) {
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
      // UI-side bridge: only fires on the safety-net paths (`.startup`,
      // `.safetyNet`). On the `.observer` path the manager has already
      // invalidated its caches via its own change-observer callback — a second
      // invalidation would double-bump `libraryRevision`, trigger two
      // `MonthViewModel.refresh(for:)` runs back-to-back per real event, and
      // generally amplify work without changing outcomes.
      if trigger != .observer, event.requiresUIWake {
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
