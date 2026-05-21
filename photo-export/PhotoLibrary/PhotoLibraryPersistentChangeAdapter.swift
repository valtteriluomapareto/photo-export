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

  /// True while a catch-up `Task.detached` is in flight (dispatched but result
  /// not yet applied). Guards against `photoLibraryDidChange` flooding the
  /// dispatcher: with a large library and active iCloud sync, the observer
  /// can fire many times per second while a previous `fetchPersistentChanges`
  /// enumeration (XPC-heavy; minutes for 10k+ changes) is still running.
  /// Without this guard each callback spawns another concurrent `runCatchUp`
  /// — all racing for the same photo-daemon XPC channel, re-enumerating
  /// overlapping change ranges, and starving any user-initiated PhotoKit work
  /// (e.g. an in-progress export) of XPC bandwidth.
  ///
  /// The guard collapses N stacked triggers into at most two catch-ups: the
  /// running one + at most one follow-up (driven by `pendingFollowUpTrigger`).
  /// If further triggers arrive while the follow-up is running, the coalesce
  /// loop continues.
  private var inFlightCatchUp = false

  /// Trigger to fire as a follow-up catch-up once the in-flight one finishes,
  /// or `nil` if none is pending. Coalesced via
  /// `Self.coalescePending(_:incoming:)` so a non-observer trigger (which
  /// wants the UI bridge to fire) survives any observer triggers arriving
  /// alongside it.
  private var pendingFollowUpTrigger: ReconcileTrigger?

  /// Timestamp of the most recent successful `fetchPersistentChanges` call,
  /// whether or not it turned up changes. Drives the "Last checked iCloud …"
  /// line in Settings → Auto Export so the user can see the safety-net
  /// reconcile is alive.
  @Published private(set) var lastSuccessfulReconciliation: Date?

  /// Diagnostic record of the most recent catch-up attempt — duration, trigger,
  /// outcome. In-memory only (matches `lastSuccessfulReconciliation`); the
  /// persistent diagnostic channel is `os.Logger`. Settings → Auto Export and
  /// the Save Diagnostic Report exporter both consume this so a reporter can
  /// share "the fetch took N seconds and processed M changes" without copying
  /// raw Console snippets. Issue #92.
  @Published private(set) var lastCatchUpSummary: CatchUpSummary?

  /// `OSSignposter` for Instruments time-profile traces of catch-up. Begin/end
  /// intervals around `fetchPersistentChanges` itself and the per-change
  /// enumeration loop so a reporter who can attach Instruments can pinpoint
  /// which phase a stall is happening in. Issue #92.
  private static let signposter = OSSignposter(
    subsystem: "com.valtteriluoma.photo-export",
    category: "PhotoLibraryChanges.CatchUp")

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
  ///
  /// `Sendable` so the trigger can cross the main-actor → `Task.detached` →
  /// main-actor boundary used by the off-main catch-up dispatch (issue #92).
  /// `internal` rather than `private` so a unit test can exercise
  /// `coalescePending(_:incoming:)` against every case.
  enum ReconcileTrigger: Sendable {
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

    var displayLabel: String {
      switch self {
      case .observer: return "observer"
      case .startup: return "startup"
      case .safetyNet: return "safety net"
      }
    }
  }

  /// Diagnostic record of a single catch-up attempt. Surfaced via
  /// `lastCatchUpSummary`, the Settings → Auto Export status row, and the Save
  /// Diagnostic Report exporter so reporters can share concrete numbers
  /// ("the fetch took N seconds and processed M changes") without copying raw
  /// Console snippets. Issue #92.
  struct CatchUpSummary: Sendable, Equatable {
    let startedAt: Date
    let finishedAt: Date
    /// Human-readable trigger label (e.g. "startup", "safety net").
    let trigger: String
    let result: Result

    var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }

    enum Result: Sendable, Equatable {
      /// First launch with no stored token; captured `currentChangeToken` as
      /// the silent baseline. No enumeration ran.
      case capturedBaseline
      /// Successful enumeration. `count` is inserted+updated+deleted assets.
      case emittedChanges(count: Int)
      /// One or more per-change detail fetches failed; token rebased.
      case detailsUnavailable(failures: Int)
      /// `fetchPersistentChanges(since:)` itself threw; token rebased.
      case fetchError(description: String)
    }
  }

  // MARK: - Private

  /// Kicks off a catch-up attempt. On a fresh launch with no prior token, the
  /// baseline is captured synchronously and we return immediately. Otherwise
  /// the slow PhotoKit work — `fetchPersistentChanges(since:)` plus per-change
  /// `changeDetails(for:)` round-trips to `photolibraryd` — is dispatched off
  /// the main actor via `Task.detached`. The result is marshalled back to
  /// the main actor in `applyCatchUpResult`, which mutates `lastToken`, the
  /// token store, `lastSuccessfulReconciliation`, `lastCatchUpSummary`, and
  /// emits on `subject`.
  ///
  /// Issue #92: prior to this shape the entire fetch+enumerate path ran
  /// synchronously on the main actor (since the whole class is `@MainActor`),
  /// so a large change backlog or an unhealthy `photolibraryd` could beachball
  /// the UI for the full duration of the XPC round-trips. The reporter's
  /// sample showed >2,000 main-thread samples in `mach_msg2_trap` waiting on
  /// photolibraryd inside this exact code path.
  ///
  /// `trigger` controls whether the UI bridge fires on success-with-changes
  /// — see `ReconcileTrigger`. On the `.observer` path the manager has
  /// already invalidated its caches via its own `photoLibraryDidChange`
  /// callback, so this method skips the bridge to avoid double-bumping
  /// `libraryRevision`.
  private func fetchAndEmit(trigger: ReconcileTrigger) {
    // Coalesce against an in-flight catch-up. The baseline-capture branch below
    // doesn't dispatch a Task, so it's exempt from this guard (the token check
    // is synchronous and free).
    if inFlightCatchUp {
      pendingFollowUpTrigger = Self.coalescePending(
        pendingFollowUpTrigger, incoming: trigger)
      logger.debug(
        "Catch-up: trigger=\(trigger.displayLabel, privacy: .public) arrived while in flight; coalesced (pending=\(self.pendingFollowUpTrigger?.displayLabel ?? "nil", privacy: .public))"
      )
      return
    }

    let startedAt = Date()
    let baseline: PHPersistentChangeToken
    if let token = lastToken {
      baseline = token
    } else {
      // First-time baseline capture is still a successful reconcile from the
      // user's perspective: we successfully consulted PhotoKit and confirmed
      // there's nothing new to act on yet. This path is fast (no XPC
      // enumeration) so it stays on main.
      let current = library.currentChangeToken
      lastToken = current
      tokenStore.save(current)
      let finishedAt = Date()
      lastSuccessfulReconciliation = finishedAt
      lastCatchUpSummary = CatchUpSummary(
        startedAt: startedAt, finishedAt: finishedAt,
        trigger: trigger.displayLabel,
        result: .capturedBaseline)
      logger.info(
        "Catch-up: captured baseline token (no prior token); trigger=\(trigger.displayLabel, privacy: .public)"
      )
      return
    }

    // Dispatch the slow PhotoKit work off the main actor. Capture pure value
    // / reference inputs locally before the detach so the worker doesn't
    // touch `self`. The lazy `library` resolves here on main if needed.
    let libraryRef = self.library
    let loggerRef = self.logger
    let signposter = Self.signposter
    inFlightCatchUp = true
    logger.info(
      "Catch-up: dispatching off-main fetch (trigger=\(trigger.displayLabel, privacy: .public))"
    )

    Task.detached(priority: .utility) {
      let outcome = Self.runCatchUp(
        baseline: baseline, library: libraryRef,
        logger: loggerRef, signposter: signposter)
      let finishedAt = Date()
      await MainActor.run { [weak self] in
        self?.applyCatchUpResult(
          outcome, trigger: trigger,
          startedAt: startedAt, finishedAt: finishedAt)
      }
    }
  }

  /// Coalesce policy for stacked triggers while a catch-up is in flight.
  /// `nil` pending → use `incoming`. Otherwise prefer a non-`.observer`
  /// trigger (startup / safetyNet) so the follow-up's
  /// `applyCatchUpResult` fires the UI bridge — observer-only stacking
  /// keeps the bridge suppressed, matching the `trigger != .observer`
  /// gate in `applyCatchUpResult`.
  ///
  /// `internal` for unit testing. Pure function — no `self` access — so
  /// `nonisolated` so tests on a non-main-actor type can call it directly.
  nonisolated static func coalescePending(
    _ pending: ReconcileTrigger?, incoming: ReconcileTrigger
  ) -> ReconcileTrigger {
    guard let pending else { return incoming }
    if pending != .observer { return pending }
    return incoming
  }

  /// Marshalled back to the main actor from the off-main worker. Mutates the
  /// adapter's published state, emits on `subject`, and conditionally fires
  /// the UI-side bridge.
  private func applyCatchUpResult(
    _ outcome: CatchUpWorkerResult,
    trigger: ReconcileTrigger,
    startedAt: Date,
    finishedAt: Date
  ) {
    switch outcome {
    case .success(let event, let newestToken):
      lastToken = newestToken
      tokenStore.save(newestToken)
      lastSuccessfulReconciliation = finishedAt
      let totalChanges =
        event.insertedLocalIdentifiers.count
        + event.updatedLocalIdentifiers.count
        + event.deletedLocalIdentifiers.count
      lastCatchUpSummary = CatchUpSummary(
        startedAt: startedAt, finishedAt: finishedAt,
        trigger: trigger.displayLabel,
        result: .emittedChanges(count: totalChanges))
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
    case .detailsUnavailable(let failureCount, let rebaseToken):
      lastToken = rebaseToken
      tokenStore.save(rebaseToken)
      lastCatchUpSummary = CatchUpSummary(
        startedAt: startedAt, finishedAt: finishedAt,
        trigger: trigger.displayLabel,
        result: .detailsUnavailable(failures: failureCount))
      subject.send(.failure(.detailsUnavailable))
    case .fetchError(let mapped, let rebaseToken):
      lastToken = rebaseToken
      tokenStore.save(rebaseToken)
      lastCatchUpSummary = CatchUpSummary(
        startedAt: startedAt, finishedAt: finishedAt,
        trigger: trigger.displayLabel,
        result: .fetchError(description: String(describing: mapped)))
      subject.send(.failure(mapped))
    }

    // Clear the in-flight flag and, if any callback arrived while we were
    // running, fire one (and only one — coalesced) follow-up. Subsequent
    // triggers arriving during this follow-up will re-coalesce against it.
    inFlightCatchUp = false
    if let follow = pendingFollowUpTrigger {
      pendingFollowUpTrigger = nil
      logger.debug(
        "Catch-up: draining coalesced follow-up (trigger=\(follow.displayLabel, privacy: .public))"
      )
      fetchAndEmit(trigger: follow)
    }
  }

  /// Outcome of `runCatchUp`. Marked `@unchecked Sendable` because PhotoKit
  /// types (`PHPersistentChangeToken`, `PHPersistentChangeFetchResult` carried
  /// inside `PhotoLibraryPersistentChangeEvent`) are not declared `Sendable`
  /// by Apple but are documented as thread-safe for the operations we perform
  /// (reading identifiers, archiving the token). The wrapper crosses a single
  /// `Task.detached` → `MainActor.run` boundary; no concurrent mutation.
  private enum CatchUpWorkerResult: @unchecked Sendable {
    case success(event: PhotoLibraryPersistentChangeEvent, newestToken: PHPersistentChangeToken)
    case detailsUnavailable(failureCount: Int, rebaseToken: PHPersistentChangeToken)
    case fetchError(
      mapped: PhotoLibraryPersistentChangeFetchError, rebaseToken: PHPersistentChangeToken)
  }

  /// Nonisolated catch-up worker. Runs `fetchPersistentChanges(since:)` and
  /// the per-change enumeration off the main actor so a slow PhotoKit / a
  /// large change backlog can't beachball the UI (issue #92).
  ///
  /// Logging is intentionally generous: emits a checkpoint at fetch start,
  /// fetch return (with elapsed ms), every 100 enumerated changes (with
  /// running elapsed), enumeration complete (with per-category counts), and
  /// any error. Wrapped in `OSSignposter` intervals (`CatchUp`,
  /// `FetchPersistentChanges`, `EnumerateChanges`) so Instruments traces show
  /// the per-phase timing.
  nonisolated private static func runCatchUp(
    baseline: PHPersistentChangeToken,
    library: PHPhotoLibrary,
    logger: Logger,
    signposter: OSSignposter
  ) -> CatchUpWorkerResult {
    let catchUpInterval = signposter.beginInterval("CatchUp")
    defer { signposter.endInterval("CatchUp", catchUpInterval) }

    logger.info("Catch-up: calling fetchPersistentChanges(since:) off-main")
    let fetchStart = Date()
    let fetchInterval = signposter.beginInterval("FetchPersistentChanges")
    let result: PHPersistentChangeFetchResult
    do {
      result = try library.fetchPersistentChanges(since: baseline)
    } catch {
      signposter.endInterval("FetchPersistentChanges", fetchInterval)
      let mapped = Self.mapFetchError(error)
      logger.error(
        "Catch-up: fetchPersistentChanges failed in \(Int(Date().timeIntervalSince(fetchStart) * 1000))ms: \(error.localizedDescription, privacy: .public) → \(String(describing: mapped), privacy: .public)"
      )
      return .fetchError(mapped: mapped, rebaseToken: library.currentChangeToken)
    }
    signposter.endInterval("FetchPersistentChanges", fetchInterval)
    logger.info(
      "Catch-up: fetchPersistentChanges returned in \(Int(Date().timeIntervalSince(fetchStart) * 1000))ms; enumerating…"
    )

    let enumerateInterval = signposter.beginInterval("EnumerateChanges")
    var inserted: Set<String> = []
    var updated: Set<String> = []
    var deleted: Set<String> = []
    var collectionChangesPresent = false
    var newestToken = baseline
    var detailsFailures = 0
    var processedCount = 0
    let enumerateStart = Date()

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
      processedCount += 1
      if processedCount.isMultiple(of: 100) {
        logger.info(
          "Catch-up: processed \(processedCount) changes in \(Int(Date().timeIntervalSince(enumerateStart) * 1000))ms (still iterating)…"
        )
      }
    }
    signposter.endInterval("EnumerateChanges", enumerateInterval)
    let enumerateElapsedMs = Int(Date().timeIntervalSince(enumerateStart) * 1000)
    logger.info(
      "Catch-up: enumeration complete: \(processedCount) changes in \(enumerateElapsedMs)ms (insertedAssets=\(inserted.count), updatedAssets=\(updated.count), deletedAssets=\(deleted.count), collectionChanges=\(collectionChangesPresent))"
    )

    if detailsFailures > 0 {
      logger.error(
        "Catch-up: per-change detail fetches failed (count=\(detailsFailures, privacy: .public)); rebasing token"
      )
      return .detailsUnavailable(
        failureCount: detailsFailures, rebaseToken: library.currentChangeToken)
    }

    let nextTokenData = try? NSKeyedArchiver.archivedData(
      withRootObject: newestToken, requiringSecureCoding: true)

    let event = PhotoLibraryPersistentChangeEvent(
      insertedLocalIdentifiers: inserted,
      updatedLocalIdentifiers: updated,
      deletedLocalIdentifiers: deleted,
      collectionChangesPresent: collectionChangesPresent,
      observedAt: Date(),
      nextToken: nextTokenData)

    return .success(event: event, newestToken: newestToken)
  }

  nonisolated private static func mapFetchError(_ error: Error)
    -> PhotoLibraryPersistentChangeFetchError
  {
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
