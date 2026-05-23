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

  /// Whether the user has Auto Export enabled. Surfaced separately from `state`
  /// because the toggle copy stays "on" even when AutoSync is currently
  /// blocked (e.g. `.blocked(.noScopesSelected)` should still render the
  /// toggle as on so the user can see what to fix).
  @Published private(set) var isEnabled: Bool = false

  /// Per-destination retry state for the *currently selected* destination.
  /// Surfaced for the Export Issues UI (Phase 4) and refreshed after every
  /// `.recordRetryFailures` effect plus on destination change. Empty for a
  /// brand-new destination or when no destination is selected.
  @Published private(set) var currentRetryState: AutoSyncRetryState = .empty

  // MARK: - Private state

  private let log: Logger
  private var environment: AutoSyncEnvironment?
  private var reducerState: AutoSyncReducer.State = .initial
  private var subscriptions: Set<AnyCancellable> = []
  private var debounceTokens: [AutoSyncReason: AutoSyncCancellable] = [:]
  private var retryTimerToken: AutoSyncCancellable?
  /// Tracks the active per-spec fan-out Task launched by `startRun`. A
  /// single-active-run gate inside ExportManager already prevents
  /// concurrent runs, but the *manager-side* fan-out across scopes (for
  /// `.autoExport(scopes)`) is its own loop. Storing the task lets
  /// `cancelActiveFanOut` interrupt the chain on disable / destination
  /// clear / teardown so a long multi-scope run doesn't keep firing
  /// scopes after the user toggled off Auto Export. `nil` when no
  /// fan-out is in flight.
  private var activeRunFanOutTask: Task<Void, Never>?
  private var isAttached = false
  /// Serializes event dispatch — events produced by an effect (e.g. an export run
  /// completing while we're in the middle of a `photosChanged` reduce) must be
  /// queued behind the in-flight event, not interleaved. Plan §"State Reducer":
  /// "Events produced by an effect ... are queued and processed after the current
  /// event's effects complete." All `dispatch` callers must be on @MainActor;
  /// effect handlers must not perform synchronous re-entry that escapes
  /// MainActor.
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
          self?.handleDestinationSnapshot(snapshot)
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

    // Issue #47: the HEIC→JPEG toggle changes which assets count as
    // exported, so AutoSync re-evaluates at the same 2s debounce as
    // `versionSelection`. Without this subscription, AutoSync would sit
    // idle until the next photos-change or app-launch trigger after a
    // user flipped the toggle.
    environment.exportRunner.convertHEICToJPEGPublisher
      .removeDuplicates()
      .sink { [weak self] value in
        dispatchPrecondition(condition: .onQueue(.main))
        MainActor.assumeIsolated {
          self?.dispatch(.convertHEICToJPEGChanged(value))
        }
      }
      .store(in: &subscriptions)

    // Manual-run completion hook for plan §"Dirty State" clear rule. AutoSync-
    // sourced summaries are routed through the `runExport`-await return path
    // inside `startRun`; filtering here to `.manual` avoids dispatching
    // `manualFullExportCompleted` for our own runs.
    environment.exportRunner.completedRunsPublisher
      .sink { [weak self] summary in
        dispatchPrecondition(condition: .onQueue(.main))
        MainActor.assumeIsolated {
          guard summary.context.source == .manual else { return }
          self?.dispatch(.manualFullExportCompleted(summary))
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
    if isEnabled != enabled {
      isEnabled = enabled
    }
    dispatch(.enabledChanged(enabled))
  }

  /// Destination-snapshot sink. Loads the new destination's persisted state
  /// from disk on the *first* observation of a given id (or when the id
  /// changes), then dispatches the standard `destinationChanged` event. The
  /// load + dispatch ordering matters: `destinationDirtyStateLoaded` must hit
  /// the reducer first so subsequent `photosChanged` / debounce decisions for
  /// the new destination see the persisted dirty state, not `.empty`.
  ///
  /// `lastRunSummary` is loaded directly into the manager's `@Published` field
  /// rather than flowing through the reducer — the reducer doesn't read it,
  /// and the UI consumes it via observation. The per-destination
  /// `lastDurablyRecordedToken` is loaded but currently unused; Phase 3 retry
  /// / resume logic will read it.
  private func handleDestinationSnapshot(_ snapshot: DestinationSnapshot) {
    guard let environment else { return }
    let newId = snapshot.fingerprint?.id
    let oldId = reducerState.destination.id
    if let newId, newId != oldId {
      let dirty = environment.dirtyStateStore.load(destinationId: newId)
      dispatch(.destinationDirtyStateLoaded(destinationId: newId, dirtyState: dirty))

      let summary = environment.runSummaryStore.load(destinationId: newId)
      if lastRunSummary != summary {
        lastRunSummary = summary
      }
      // Per-destination token is loaded for resume detection in Phase 3; the
      // load itself surfaces decode failures in logs at the right moment
      // (destination switch) rather than first time we'd want to use it.
      _ = environment.perDestinationTokenStore.load(destinationId: newId)

      // Refresh retry state for the new destination so the Issues UI shows
      // this destination's failures immediately, not the previous one's.
      let retry = environment.retryStateStore.load(destinationId: newId)
      if currentRetryState != retry {
        currentRetryState = retry
      }
    } else if newId == nil {
      if lastRunSummary != nil {
        // Destination cleared (drive removed, user de-selected). Drop the
        // stale summary so the UI doesn't show "last run on Drive A" when
        // no drive is selected.
        lastRunSummary = nil
      }
      if !currentRetryState.isEmpty {
        currentRetryState = .empty
      }
      // Destination went away mid-run — stop the fan-out so subsequent
      // scopes don't fail-fast against the missing destination.
      cancelActiveFanOut()
    }
    dispatch(.destinationChanged(snapshot))
  }

  /// User clicked Export Now (Settings, menu, status item). Dispatches a
  /// `.runNowRequested` event; the reducer routes through the
  /// `.userExportNow` trigger path which uses a 0s debounce. Eligibility
  /// gates (safety, scope selection, destination available, import inactive)
  /// still apply; if the run can't start the state will reflect why.
  func runNow() {
    dispatch(.runNowRequested)
  }

  /// User clicked Retry on a failure in the Issues tab. Clears the retry
  /// entry (so it isn't filtered out at enqueue time) and then dispatches
  /// `runNow` to start an immediate run that picks it up. Plan §"Retry and
  /// Failure Policy": "Export Issues 'Retry Failed' or a normal manual
  /// export after disabling Auto Export can override backoff."
  ///
  /// The asset will appear in the next run's enqueue because the record
  /// store still has it as `.failed` for that variant — `isExported`
  /// returns false, and now the retry-eligibility check returns true.
  func retryFailedVariant(
    scope: AutoSyncRetryScopeKey, assetId: String, variant: ExportVariant
  ) {
    guard let environment = environment,
      let destinationId = reducerState.destination.id
    else { return }
    // Mutate the in-memory snapshot, then persist. Avoids a disk-reload
    // that could miss a concurrent mutation from the
    // `.recordRetryFailures` effect handler — both paths now operate on
    // `currentRetryState` so successive mutations compose correctly.
    var retry = currentRetryState
    retry.removeEntry(scope: scope, assetId: assetId, variant: variant)
    do {
      try environment.retryStateStore.save(retry, destinationId: destinationId)
    } catch {
      log.error(
        "Failed to persist retry-state cleanup for manual retry: \(error.localizedDescription, privacy: .public)"
      )
      return
    }
    if currentRetryState != retry {
      currentRetryState = retry
    }
    dispatch(.runNowRequested)
  }

  /// User toggles Auto Export. Persists the flag and dispatches the event.
  func setEnabled(_ enabled: Bool) {
    environment?.userDefaults.set(enabled, forKey: Self.enabledDefaultsKey)
    if isEnabled != enabled {
      isEnabled = enabled
    }
    if !enabled {
      // Disable while a multi-scope fan-out is mid-chain: stop the chain
      // at the next await boundary rather than letting it run remaining
      // scopes the user no longer wants.
      cancelActiveFanOut()
    }
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
        // Surface to the @Published field for the active destination so SwiftUI
        // observers update; persist to disk so the summary survives app restart
        // and is reloaded on `handleDestinationSnapshot`. Equatable guard
        // prevents the willChange storm when the same summary is re-emitted in
        // a single tick.
        if lastRunSummary != summary {
          lastRunSummary = summary
        }
        do {
          try environment.runSummaryStore.save(summary, destinationId: destinationId)
        } catch {
          log.error(
            "Failed to persist run summary for \(destinationId, privacy: .public): \(error.localizedDescription, privacy: .public)"
          )
        }

      case .advancePersistentChangeToken(let token, let destinationId):
        do {
          try environment.perDestinationTokenStore.save(token, destinationId: destinationId)
        } catch {
          log.error(
            "Failed to persist per-destination token for \(destinationId, privacy: .public): \(error.localizedDescription, privacy: .public)"
          )
        }

      case .recordRetryFailures(let failures, let destinationId):
        // Two paths:
        //
        // (a) Hot path — `destinationId` matches the currently-active
        //     destination. Use the in-memory `currentRetryState` as the
        //     source of truth and mutate-then-persist. This closes a
        //     subtle race where the user pressed Retry in the Issues UI
        //     between two scope iterations of a multi-scope fan-out: a
        //     disk-reload here would re-read the user's just-cleared
        //     entry and re-record the failure on top, silently losing
        //     the clear. Both paths (this one and `retryFailedVariant`)
        //     now use the in-memory snapshot, so successive mutations
        //     compose correctly.
        //
        // (b) Cold path — `destinationId` is some other destination
        //     (user switched between dispatch and effect-run). Disk-
        //     load is correct here because `currentRetryState` is for
        //     a different destination; clobbering it with a stale read
        //     would be wrong. The cold path doesn't touch
        //     `currentRetryState`.
        let isHotPath = (reducerState.destination.id == destinationId)
        var retry =
          isHotPath
          ? currentRetryState
          : environment.retryStateStore.load(destinationId: destinationId)
        for failure in failures {
          let scope = Self.retryScopeKey(for: failure.placement)
          let priorAttempts =
            retry.entry(scope: scope, assetId: failure.assetId, variant: failure.variant)?
            .attemptCount ?? 0
          // recordFailure increments to `priorAttempts + 1` (when signature
          // matches) or resets to 1 (signature differs). For backoff
          // purposes the next-attempt count is `priorAttempts + 1`.
          let nextAttempt = priorAttempts + 1
          let nextEligibleAt = failure.category.nextEligibleAt(
            attemptCount: nextAttempt, from: failure.failedAt)
          retry.recordFailure(
            scope: scope,
            assetId: failure.assetId,
            variant: failure.variant,
            category: failure.category,
            errorSignature: failure.errorSignature,
            at: failure.failedAt,
            nextEligibleAt: nextEligibleAt
          )
        }
        do {
          try environment.retryStateStore.save(retry, destinationId: destinationId)
        } catch {
          log.error(
            "Failed to persist retry state for \(destinationId, privacy: .public): \(error.localizedDescription, privacy: .public)"
          )
        }
        if isHotPath, currentRetryState != retry {
          currentRetryState = retry
        }
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
    // Cancel any prior fan-out before starting a new one. The reducer's
    // single-active-run invariants should already prevent overlap, but
    // belt-and-braces: a misroute would never silently chain two fan-outs.
    activeRunFanOutTask?.cancel()

    // For an `.autoExport(scopes)` spec, fan out to one `runExport` call per
    // enabled scope and dispatch `autoSyncRunCompleted` after each. The
    // reducer clears only the dirty for the scope each summary covers, so
    // sequential per-scope runs keep dirty-state correctness intact even if a
    // later scope fails. ExportManager's `runExport` doesn't implement
    // `.autoExport` directly — translating here keeps the runner narrow.
    let runScopes = Self.expand(scope: spec.scope)

    // Write the current-run journal *before* dispatching the fan-out Task.
    // The journal is the crash-survivable signal: if it exists on the next
    // launch's diagnostic, this fan-out was killed mid-flight. Doing the
    // write synchronously here (rather than as the first thing inside the
    // Task) means the journal lands on disk before any per-scope await
    // could be interrupted — even a SIGKILL between the write and the
    // first await still leaves the journal observable. Manual export runs
    // are out of scope and do not write a journal; they don't route
    // through `startRun`.
    //
    // `initialJournal` is `let` so the per-iteration update inside the
    // Task can build a new struct from it without capturing a mutable
    // `var` across the Task boundary. `AutoSyncRunJournal` is `Sendable`,
    // so the immutable capture is concurrency-clean.
    let destinationId = reducerState.destination.id
    let fanOutStartedAt = environment.clock.now()
    let plannedScopeRawValues = runScopes.compactMap { $0.clearableScope?.rawValue }
    let initialJournal: AutoSyncRunJournal? = destinationId.map { _ in
      AutoSyncRunJournal(
        startedAt: fanOutStartedAt,
        trigger: spec.reason.rawValue,
        scopes: plannedScopeRawValues,
        currentScope: nil,
        currentScopeStartedAt: nil
      )
    }
    if let destinationId, let initialJournal {
      do {
        try environment.currentRunStore.save(initialJournal, destinationId: destinationId)
      } catch {
        log.error(
          "Failed to write current-run journal for \(destinationId, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
      }
    }

    activeRunFanOutTask = Task { @MainActor [weak self] in
      defer { self?.activeRunFanOutTask = nil }
      defer {
        // Clean up the journal on every exit path — clean completion,
        // cancellation, and the `break` on a non-`.completed` summary all
        // reach this defer. `clear` is a no-op when the file is absent
        // (the early-return-before-loop cases), so repeated calls and
        // missing-destination paths are safe.
        if let destinationId {
          do {
            try environment.currentRunStore.clear(destinationId: destinationId)
          } catch {
            self?.log.error(
              "Failed to clear current-run journal for \(destinationId, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
          }
        }
      }
      for runScope in runScopes {
        if Task.isCancelled { return }
        // Update the journal with the sub-scope about to start. Done
        // *before* the `await` so a SIGKILL during the await leaves the
        // journal pointing at the in-flight scope, not the previous one.
        // Builds a new struct from `initialJournal` rather than mutating
        // a captured var — keeps the closure concurrency-clean.
        if let destinationId, let base = initialJournal,
          let scopeRaw = runScope.clearableScope?.rawValue
        {
          let updated = AutoSyncRunJournal(
            startedAt: base.startedAt,
            trigger: base.trigger,
            scopes: base.scopes,
            currentScope: scopeRaw,
            currentScopeStartedAt: environment.clock.now()
          )
          do {
            try environment.currentRunStore.save(updated, destinationId: destinationId)
          } catch {
            self?.log.error(
              "Failed to update current-run journal for \(destinationId, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
          }
        }
        let context = ExportRunContext(
          runId: UUID(),
          source: spec.source,
          visibility: spec.visibility,
          reason: spec.reason,
          scope: runScope,
          selection: spec.selection,
          startedAt: environment.clock.now()
        )
        let summary = await environment.exportRunner.runExport(context: context)
        // Check cancellation again after the await — the user may have
        // toggled off / switched destinations during the run.
        guard !Task.isCancelled else { return }
        self?.dispatch(.autoSyncRunCompleted(summary))
        if summary.result != .completed {
          // Stop the chain on the first non-completion so a destination that
          // went unavailable mid-run doesn't churn through the remaining
          // scopes' fail-fast paths. The reducer's recompute will route to
          // the appropriate waiting/blocked state from the first summary's
          // signal.
          break
        }
      }
    }
  }

  /// Cancel any in-flight fan-out task. Called from disable / destination-
  /// clear paths so a long multi-scope run stops at the next await boundary
  /// instead of continuing scopes the user no longer cares about.
  private func cancelActiveFanOut() {
    activeRunFanOutTask?.cancel()
    activeRunFanOutTask = nil
  }

  /// Expands an `.autoExport(scopes)` spec scope into per-scope full-scope
  /// runs. Other scope shapes pass through unchanged.
  private static func expand(scope: ExportRunScope) -> [ExportRunScope] {
    guard case .autoExport(let scopes) = scope else { return [scope] }
    return scopes.enabledScopes.map(\.fullRunScope)
  }

  /// Maps an `ExportPlacement` to the retry-state scope key. Plan §"Retry
  /// and Failure Policy": "Timeline can use a timeline scope key; collection
  /// exports need placement awareness so a failure in one album does not
  /// suppress a different album or Favorites." `internal` (default) so
  /// `PhotoExportApp` can construct the eligibility-check closure that
  /// reads `currentRetryState` for `ExportManager`.
  static func retryScopeKey(for placement: ExportPlacement) -> AutoSyncRetryScopeKey {
    switch placement.kind {
    case .timeline: return .timeline
    case .favorites: return .favorites
    case .album: return .album(placementId: placement.id)
    case .sharedAlbum: return .sharedAlbum(placementId: placement.id)
    }
  }

  // MARK: - Constants

  static let enabledDefaultsKey = "AutoSync.enabled"
}
