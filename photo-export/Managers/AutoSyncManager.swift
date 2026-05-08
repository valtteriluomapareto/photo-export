import Combine
import Foundation
import os

/// Live, observable AutoSync controller. Wraps the pure `AutoSyncReducer` with an
/// effect runner, Combine subscriptions to the environment's publishers, and
/// `@Published` state surfaces for UI consumption.
///
/// Plan §"AutoSyncManager Shape" — at most one manager per app, lifecycle-owned by
/// `PhotoExportApp` as a `@StateObject`. `attach(to:)` is idempotent so repeated
/// calls (multi-window scene recreation, test resets) don't re-bootstrap.
@MainActor
final class AutoSyncManager: ObservableObject {
  /// Current AutoSync state — mapped from the reducer's `State.current`. Drives the
  /// main-window status pill and the Settings tab status copy.
  @Published private(set) var state: AutoSyncState = .disabled

  /// Most recently completed run's summary. `nil` until the first run finishes.
  /// Persisted per-destination in subsequent slices.
  @Published private(set) var lastRunSummary: ExportRunSummary?

  // MARK: - Private state

  private let log: Logger
  private var environment: AutoSyncEnvironment?
  private var reducerState: AutoSyncReducer.State = .initial
  private var subscriptions: Set<AnyCancellable> = []
  private var debounceTokens: [AutoSyncReason: AutoSyncCancellable] = [:]
  private var retryTimerToken: AutoSyncCancellable?
  private var isAttached = false
  /// Serializes event dispatch — events produced by an effect (e.g. an export run
  /// completing while we're in the middle of a `photosChanged` reduce) must be
  /// queued behind the in-flight event, not interleaved. Plan §"State Reducer":
  /// "Events produced by an effect ... are queued and processed after the current
  /// event's effects complete."
  private var dispatching = false
  private var queuedEvents: [AutoSyncEvent] = []

  init(
    log: Logger = Logger(subsystem: "com.valtteriluoma.photo-export", category: "AutoSync")
  ) {
    self.log = log
  }

  // MARK: - Public API

  /// Wires the manager to its environment. Idempotent; second-and-later calls are no-ops.
  func attach(to environment: AutoSyncEnvironment) {
    guard !isAttached else {
      log.debug("attach called more than once; ignoring")
      return
    }
    isAttached = true
    self.environment = environment

    // Subscribe to publishers FIRST so the initial `enabledChanged` dispatch sees the
    // persisted destination / scope / import / run-state values already loaded into
    // reducer state. CurrentValueSubject replays its current value on subscribe;
    // each replay turns into a reducer event before we flip the enabled flag.
    // Sinks dispatch into the @MainActor reducer. Each upstream is driven by
    // @MainActor-isolated writes (publishers on @MainActor managers, or
    // `CurrentValueSubject` written from @MainActor adapters), so the sink fires
    // on the main thread. `dispatchPrecondition(.onQueue(.main))` traps loudly if
    // a future contributor wires a publisher that hops threads;
    // `MainActor.assumeIsolated` makes the cross-actor dispatch call explicit
    // under Swift 6 strict mode without paying for a thread hop.

    environment.destination.destinationSnapshotPublisher
      .removeDuplicates()
      .sink { [weak self] snapshot in
        dispatchPrecondition(condition: .onQueue(.main))
        MainActor.assumeIsolated {
          self?.dispatch(.destinationChanged(snapshot))
        }
      }
      .store(in: &subscriptions)

    environment.scopes.scopeSelectionPublisher
      .removeDuplicates()
      .sink { [weak self] scopes in
        dispatchPrecondition(condition: .onQueue(.main))
        MainActor.assumeIsolated {
          self?.dispatch(.scopeSelectionChanged(scopes))
        }
      }
      .store(in: &subscriptions)

    environment.importing.isImportingPublisher
      .removeDuplicates()
      .sink { [weak self] isImporting in
        dispatchPrecondition(condition: .onQueue(.main))
        MainActor.assumeIsolated {
          self?.dispatch(.importStateChanged(isImporting: isImporting))
        }
      }
      .store(in: &subscriptions)

    environment.exportRunner.exportRunStatePublisher
      .removeDuplicates()
      .sink { [weak self] runState in
        dispatchPrecondition(condition: .onQueue(.main))
        MainActor.assumeIsolated {
          self?.dispatch(.exportRunStateChanged(runState))
        }
      }
      .store(in: &subscriptions)

    environment.exportRunner.versionSelectionPublisher
      .removeDuplicates()
      .sink { [weak self] selection in
        dispatchPrecondition(condition: .onQueue(.main))
        MainActor.assumeIsolated {
          self?.dispatch(.versionSelectionChanged(selection))
        }
      }
      .store(in: &subscriptions)

    environment.photos.changes
      .sink { [weak self] outcome in
        dispatchPrecondition(condition: .onQueue(.main))
        MainActor.assumeIsolated {
          switch outcome {
          case .success(let event):
            self?.dispatch(.photosChanged(event))
          case .failure(let fetchError):
            self?.dispatch(.photosChangeFetchFailed(fetchError))
          }
        }
      }
      .store(in: &subscriptions)

    // Load persisted enabled flag and dispatch — this is the trigger for the
    // .appLaunch debounce when destination + scopes are already valid.
    let enabled = environment.userDefaults.bool(forKey: Self.enabledDefaultsKey)
    dispatch(.enabledChanged(enabled))
  }

  /// User toggles Auto Export. Persists the flag and dispatches the event.
  func setEnabled(_ enabled: Bool) {
    environment?.userDefaults.set(enabled, forKey: Self.enabledDefaultsKey)
    dispatch(.enabledChanged(enabled))
  }

  // MARK: - Dispatch

  /// Pure-reducer dispatch with serialized in-flight handling. External callers and
  /// subscribers funnel here; the runner's effect dispatch can re-enter via
  /// reducer-produced events, which queue rather than interleave.
  func dispatch(_ event: AutoSyncEvent) {
    if dispatching {
      queuedEvents.append(event)
      return
    }
    dispatching = true
    defer { dispatching = false }

    process(event)
    while !queuedEvents.isEmpty {
      let next = queuedEvents.removeFirst()
      process(next)
    }
  }

  private func process(_ event: AutoSyncEvent) {
    guard let environment else {
      log.error(
        "dispatch called before attach — dropping event \(String(describing: event), privacy: .public)"
      )
      return
    }
    let now = environment.clock.now()
    let (next, effects) = AutoSyncReducer.reduce(event, in: reducerState, now: now)
    reducerState = next
    // Equatable guard: skip the `@Published` assignment when the value is
    // unchanged. Prevents the willChange storm during attach (5+ initial replays
    // before the enabledChanged dispatch) from flooding SwiftUI views with
    // redundant re-renders.
    if state != next.current {
      state = next.current
    }
    runEffects(effects)
  }

  // MARK: - Effect runner

  private func runEffects(_ effects: [AutoSyncEffect]) {
    guard let environment else { return }
    for effect in effects {
      switch effect {
      case .scheduleDebounce(let reason, let fireAt):
        scheduleDebounce(reason: reason, fireAt: fireAt, clock: environment.clock)

      case .cancelDebounce(let reason):
        debounceTokens.removeValue(forKey: reason)?.cancel()

      case .scheduleRetryTimer(let fireAt):
        retryTimerToken?.cancel()
        let delay = max(0, fireAt.timeIntervalSince(environment.clock.now()))
        retryTimerToken = environment.clock.schedule(after: delay) { [weak self] in
          self?.dispatch(.retryTimerFired)
        }

      case .cancelRetryTimer:
        retryTimerToken?.cancel()
        retryTimerToken = nil

      case .startRun(let spec):
        startRun(spec: spec)

      case .persistDirtyState(let dirtyState, let destinationId):
        do {
          try environment.dirtyStateStore.save(dirtyState, destinationId: destinationId)
        } catch {
          log.error(
            "Failed to persist dirty state for \(destinationId, privacy: .public): \(error.localizedDescription, privacy: .public)"
          )
        }

      case .persistRunSummary(let summary, let destinationId):
        // Persistence wiring lands in a subsequent slice (per-destination
        // lastRunSummary file). For now, surface to the @Published field for the
        // current destination only. Equatable guard prevents redundant
        // objectWillChange when the same summary is re-emitted (e.g. multi-event
        // dispatch in one tick).
        if lastRunSummary != summary {
          lastRunSummary = summary
        }
        _ = destinationId

      case .advancePersistentChangeToken(let token, let destinationId):
        // Token persistence lands in a subsequent slice (lastDurablyRecordedToken
        // sibling file). For now, the effect is logged but not persisted.
        log.debug(
          "advancePersistentChangeToken for \(destinationId, privacy: .public) (\(token.count) bytes) — persistence not yet wired"
        )
      }
    }
  }

  private func scheduleDebounce(
    reason: AutoSyncReason, fireAt: Date, clock: any AutoSyncClock
  ) {
    debounceTokens.removeValue(forKey: reason)?.cancel()
    let delay = max(0, fireAt.timeIntervalSince(clock.now()))
    let token = clock.schedule(after: delay) { [weak self] in
      self?.debounceTokens.removeValue(forKey: reason)
      self?.dispatch(.debounceFired(reason))
    }
    debounceTokens[reason] = token
  }

  private func startRun(spec: StartRunSpec) {
    guard let environment else { return }
    let context = ExportRunContext(
      runId: UUID(),
      source: spec.source,
      visibility: spec.visibility,
      reason: spec.reason,
      scope: spec.scope,
      selection: spec.selection,
      startedAt: environment.clock.now()
    )
    // The Task is intentionally not stored — `runExport` owns its own cancellation
    // (single-active-run gate inside ExportManager), so we don't need a Set<Task>
    // to invalidate it. `[weak self]` lets the closure drop cleanly if the manager
    // is torn down mid-run.
    Task { @MainActor [weak self] in
      let summary = await environment.exportRunner.runExport(context: context)
      // Dispatching `.autoSyncRunCompleted` is what tells the reducer the run
      // result (success vs failure) so dirty state is only cleared on `.completed`.
      // The `.exportRunStateChanged(.idle)` event also fires, but it's now purely
      // a state-tracking signal.
      self?.dispatch(.autoSyncRunCompleted(summary))
    }
  }

  // MARK: - Constants

  static let enabledDefaultsKey = "AutoSync.enabled"
}
