import Foundation

/// Pure reducer for the AutoSync state machine. Plan §"State Reducer" — single
/// event-in / state+effects-out signature, no I/O, no timers, no actor isolation.
/// Tests pass `now: Date` directly; the runner reads `clock.now()` before calling
/// `reduce`.
///
/// `State` carries the full reducer environment (current AutoSyncState plus the inputs
/// — enabled flag, destination snapshot, scope selection — that drive transitions).
/// History fields like `lastRunSummary` live on `AutoSyncManager`, not the reducer
/// state, since they're persisted via effects rather than computed.
enum AutoSyncReducer {
  struct State: Equatable, Sendable {
    var current: AutoSyncState
    var enabled: Bool
    var destination: DestinationSnapshot
    var scopeSelection: AutoExportScopeSelection
    var versionSelection: ExportVersionSelection
    var importActive: Bool
    var exportRunState: ExportRunState
    /// Per-destination accumulated dirty state. Updated by `photosChanged` events
    /// (asset id targeting + cost-cap rollover) and by full-reconciliation completion.
    /// Keyed by destination id; entries persist across destination switches so
    /// reconnecting the same drive resumes its accumulated work.
    var dirtyStateByDestination: [String: AutoSyncDirtyState]

    static let initial = State(
      current: .disabled,
      enabled: false,
      destination: .none,
      scopeSelection: AutoExportScopeSelection(),
      versionSelection: .edited,
      importActive: false,
      exportRunState: .idle,
      dirtyStateByDestination: [:]
    )
  }

  /// Per-scope cost cap for targeted asset-id accumulation. Plan §"Photo Library
  /// Changes" / §"Trigger and Debounce Rules": "Use a tunable implementation constant
  /// backed by measurement, and prefer a cost model once enough data exists." MVP value
  /// is conservative; tuned by measurement post-launch.
  static let targetedAssetCostCap = 500

  /// Single entry point. Plan §"State Reducer" dispatch contract:
  /// - Invoked synchronously, once per event, with no mutation in flight.
  /// - Effects are returned as a list and dispatched by the runner *after* `reduce`
  ///   returns. Events produced by an effect (e.g. `exportRunStateChanged` from a
  ///   `startRun`) are queued behind the current event's effects.
  /// - Timer cancellation is an effect (`cancelDebounce` / `cancelRetryTimer`); the
  ///   reducer never side-effects timers.
  static func reduce(
    _ event: AutoSyncEvent,
    in state: State,
    now: Date
  ) -> (State, [AutoSyncEffect]) {
    var newState = state
    var effects: [AutoSyncEffect] = []

    // Track whether this event introduced "new work" that warrants scheduling a
    // debounce on transition into eligibility. Run-completion events (and pure
    // observation events like `exportRunStateChanged`) do not — the reducer should
    // return to `.idle` cleanly without re-scheduling another run.
    var triggerReason: AutoSyncReason?

    switch event {
    case .enabledChanged(let enabled):
      newState.enabled = enabled
      // Only treat this as a trigger when the value *actually changes* from disabled
      // to enabled. A republished settings observation that re-emits the current
      // value should not cancel-and-replace any active debounce.
      if enabled && !state.enabled {
        triggerReason = .appLaunch
      }

    case .destinationChanged(let destination):
      // No-op when the snapshot is byte-identical — id+availability+safety+fingerprint
      // metadata all match. Without this guard, a publisher republish (same drive,
      // same state) would cancel the active debounce and re-arm a fresh one.
      if destination == state.destination {
        break
      }
      let wasUnavailableOrMissing =
        !state.destination.isAvailable || state.destination.id == nil
      newState.destination = destination
      if destination.id != nil && destination.isAvailable {
        // A destination becoming reachable, or a fresh destination being selected.
        // Either way it can host a run, so schedule a debounce.
        triggerReason =
          wasUnavailableOrMissing
          ? (state.destination.id == destination.id
            ? .destinationBecameAvailable : .destinationSelected)
          : .destinationSelected
      }

    case .scopeSelectionChanged(let scopes):
      let scopesAdded = scopes.enabledScopes.contains { !state.scopeSelection.includes($0) }
      newState.scopeSelection = scopes
      if scopesAdded {
        triggerReason = .scopeSelectionChanged
      }

    case .versionSelectionChanged(let selection):
      newState.versionSelection = selection
      if selection != state.versionSelection {
        triggerReason = .versionSelectionChanged
      }

    case .importStateChanged(let isImporting):
      newState.importActive = isImporting

    case .exportRunStateChanged(let runState):
      // Detect a transition out of our own auto-sync run. `state.current == .running`
      // means the previous tick was an auto-sync run we own (manual runs never
      // transition the reducer to .running — environmentAllowsRun blocks them).
      let ourRunJustFinished: Bool
      if case .running = state.current,
        state.exportRunState.activeContext != nil,
        runState.activeContext == nil
      {
        ourRunJustFinished = true
      } else {
        ourRunJustFinished = false
      }
      newState.exportRunState = runState
      if ourRunJustFinished, let destinationId = newState.destination.id {
        // The auto-sync run we just executed was a full reconciliation across the
        // selected scopes (.autoExport scope umbrella). Clear dirty for those
        // scopes; new photosChanged events that arrived mid-run would have
        // accumulated into the same scope-dirty entry and *also* be processed by
        // the full-reconciliation run, so clearing them is correct for now.
        // (Targeted-asset runs that land later will need a per-run snapshot to
        // avoid clearing post-start additions.)
        var dirty = newState.dirtyStateByDestination[destinationId] ?? .empty
        for scope in AutoExportLibraryScope.allCases
        where newState.scopeSelection.includes(scope) {
          var scopeState = dirty.scope(scope)
          scopeState.clearAfterSuccessfulFullReconciliation()
          dirty.setScope(scope, scopeState)
        }
        dirty.markUpdated(at: now)
        newState.dirtyStateByDestination[destinationId] = dirty
        effects.append(.persistDirtyState(dirty, destinationId: destinationId))
      }

    case .debounceFired(let reason):
      // Honor the timer only if the state still expects this reason. A debounce
      // that fires after the user has disabled / unmounted / re-enabled scopes is
      // stale and should be ignored — the timer's resources are owned by
      // `cancelDebounce` effects emitted on those transitions.
      if case .scheduled(let scheduledReason, _) = state.current,
        scheduledReason == reason
      {
        let environmentSupportsRun = environmentAllowsRun(state: newState)
        if environmentSupportsRun {
          effects.append(
            .startRun(
              StartRunSpec(
                source: .autoSync,
                visibility: .background,
                reason: reason,
                scope: .autoExport(newState.scopeSelection),
                selection: newState.versionSelection
              )))
          newState.current = .running(reason: reason)
          // Returning early — `current` is already final; skip the
          // recompute-and-maybe-schedule pass below.
          return (newState, effects)
        }
      }
    // Reducer-level no-op: stale debounce or environment changed; the recompute
    // pass below routes to whatever the current environment dictates.

    case .photosChanged(let event):
      // Accumulate dirty state per selected scope for the *current* destination.
      // Plan §"Photo Library Changes": "Photos changes while destination is
      // unavailable accumulate per-destination and export after reconnect" — so we
      // accumulate even if the destination is currently offline (just don't start a
      // run; the debounce-fired handler gates that on environmentAllowsRun).
      // Disabled / no-destination / no-scopes selected → ignore the event entirely.
      if state.enabled, let destinationId = state.destination.id,
        !state.scopeSelection.isEmpty
      {
        let changedIds = event.insertedLocalIdentifiers.union(event.updatedLocalIdentifiers)
        let albumsActive = state.scopeSelection.includes(.albums)
        let albumsRelevantCollectionChange = albumsActive && event.collectionChangesPresent
        // Plan §"Photo Library Changes": "Treat deleted asset IDs as non-export work
        // for MVP." A deleted-only event (no inserts/updates) — and one whose
        // collection-only signal isn't relevant to a selected scope — produces no
        // export work, so skip dirty mutation, persistence, and the debounce. Token
        // advancement still fires below so the persistent-change cursor moves
        // forward.
        let producesExportWork = !changedIds.isEmpty || albumsRelevantCollectionChange

        if producesExportWork {
          var dirty = state.dirtyStateByDestination[destinationId] ?? .empty
          for scope in state.scopeSelection.enabledScopes {
            var scopeState = dirty.scope(scope)
            for assetId in changedIds {
              scopeState.recordPendingAssetId(assetId, costCap: targetedAssetCostCap)
            }
            if scope == .albums && event.collectionChangesPresent {
              scopeState.pendingPlacementReconciliation = true
            }
            dirty.setScope(scope, scopeState)
          }
          dirty.markUpdated(at: now)
          newState.dirtyStateByDestination[destinationId] = dirty
          effects.append(.persistDirtyState(dirty, destinationId: destinationId))
          triggerReason = .photosChanged
        }

        // Token advances regardless of whether the event produced work for this
        // selection — the persistent-change cursor must move forward to avoid
        // re-receiving the same range on the next fetch.
        if let nextToken = event.nextToken {
          effects.append(
            .advancePersistentChangeToken(nextToken, destinationId: destinationId))
        }
      }

    case .retryTimerFired, .manualFullExportCompleted:
      // Handled by subsequent slices that wire dirty-state, retry, and run-summary
      // semantics. Plan §"State Reducer" lists these events; the slice that
      // implements each will append the corresponding `case` here.
      break
    }

    let nextCurrent = recomputeCurrent(
      from: newState, previous: state.current, triggerReason: triggerReason, now: now,
      effects: &effects)
    newState.current = nextCurrent

    // Work-preservation hook. If we just landed in `.idle` from a state that paused
    // pending work — `.running` (run finished), `.waiting(.importActive)` (import
    // done), `.waiting(.manualExportActive)` (manual run done) — and there's
    // accumulated dirty for the current destination, schedule a debounce so the
    // pending work is processed instead of sitting forever. Without this, photos
    // changes during long exports / imports / manual runs are silently abandoned
    // until an unrelated event happens to re-trigger.
    if case .idle = newState.current,
      previousIsBlockingResumePoint(state.current),
      let destinationId = newState.destination.id,
      let dirty = newState.dirtyStateByDestination[destinationId],
      !dirty.isEmpty
    {
      let fireAt = now.addingTimeInterval(debounceDelay(for: .photosChanged))
      effects.append(.scheduleDebounce(.photosChanged, fireAt: fireAt))
      newState.current = .scheduled(reason: .photosChanged, fireAt: fireAt)
    }

    return (newState, effects)
  }

  /// Whether the previous state was a blocking-then-resumable state (transitioning
  /// out of which should re-fire any accumulated dirty work). `.scheduled` and
  /// `.idle` are intentionally excluded — those don't pause work, so resuming
  /// from them shouldn't double-schedule.
  private static func previousIsBlockingResumePoint(_ previous: AutoSyncState) -> Bool {
    switch previous {
    case .running, .waiting:
      return true
    case .disabled, .idle, .scheduled, .blocked:
      return false
    }
  }

  // MARK: - Internals

  /// Whether the environment currently allows starting a run — gating equivalent of
  /// the `idle` state precondition. Includes the single-active-run gate: a manual
  /// export already in flight blocks AutoSync from starting a parallel run (plan
  /// §"Run Ownership Model": "If auto-sync wants to run while any manual export or
  /// import is active, AutoSyncManager marks itself dirty and re-evaluates after
  /// manual work drains.").
  private static func environmentAllowsRun(state: State) -> Bool {
    state.enabled && !state.importActive && !state.scopeSelection.isEmpty
      && state.destination.id != nil && state.destination.isAvailable
      && state.destination.safety == .safe
      && !state.exportRunState.isManualActive
  }

  /// Maps the reducer's input environment plus the previous state and the optional
  /// `triggerReason` to the next `AutoSyncState`. Emits `scheduleDebounce` /
  /// `cancelDebounce` effects as needed via the inout `effects` list.
  private static func recomputeCurrent(
    from state: State,
    previous: AutoSyncState,
    triggerReason: AutoSyncReason?,
    now: Date,
    effects: inout [AutoSyncEffect]
  ) -> AutoSyncState {
    if !state.enabled {
      cancelAnyScheduledDebounce(from: previous, into: &effects)
      return .disabled
    }
    if state.importActive {
      cancelAnyScheduledDebounce(from: previous, into: &effects)
      return .waiting(.importActive)
    }
    if state.exportRunState.isManualActive {
      cancelAnyScheduledDebounce(from: previous, into: &effects)
      return .waiting(.manualExportActive)
    }
    if state.scopeSelection.isEmpty {
      cancelAnyScheduledDebounce(from: previous, into: &effects)
      return .blocked(.noScopesSelected)
    }
    if state.destination.id == nil {
      cancelAnyScheduledDebounce(from: previous, into: &effects)
      return .blocked(.destinationMissing)
    }
    if !state.destination.isAvailable {
      cancelAnyScheduledDebounce(from: previous, into: &effects)
      return .waiting(.destinationUnavailable)
    }
    switch state.destination.safety {
    case .unsafeNeedsConfirmation, .unsafeMigrationConflict:
      cancelAnyScheduledDebounce(from: previous, into: &effects)
      return .blocked(.destinationUnsafe)
    case .safe:
      break
    }

    // Eligibility met. Decide between scheduled / running / idle based on the
    // previous state and the trigger reason.
    if case .running(let reason) = previous {
      // A run is in flight. Stay in .running until exportRunStateChanged signals
      // completion (then `previous` will be the post-completion state, not
      // .running).
      if state.exportRunState.activeContext != nil {
        return .running(reason: reason)
      }
      // Run completed. Drop to idle without re-scheduling — only events that
      // create new work warrant a fresh schedule.
      return .idle
    }

    if case .scheduled(let reason, let fireAt) = previous, triggerReason == nil {
      // No new trigger; preserve the existing schedule.
      return .scheduled(reason: reason, fireAt: fireAt)
    }

    if let reason = triggerReason {
      let fireAt = now.addingTimeInterval(debounceDelay(for: reason))
      // If we were already scheduled, replace the prior debounce.
      if case .scheduled(let priorReason, _) = previous {
        effects.append(.cancelDebounce(priorReason))
      }
      effects.append(.scheduleDebounce(reason, fireAt: fireAt))
      return .scheduled(reason: reason, fireAt: fireAt)
    }

    return .idle
  }

  private static func cancelAnyScheduledDebounce(
    from previous: AutoSyncState, into effects: inout [AutoSyncEffect]
  ) {
    if case .scheduled(let reason, _) = previous {
      effects.append(.cancelDebounce(reason))
    }
  }

  /// Plan §"Trigger and Debounce Rules". Single source of truth for per-reason
  /// debounce delays; tests pin specific values, the runner reads them via
  /// `scheduleDebounce` effects.
  static func debounceDelay(for reason: AutoSyncReason) -> TimeInterval {
    switch reason {
    case .appLaunch:
      return 10
    case .destinationSelected, .destinationBecameAvailable:
      return 3
    case .scopeSelectionChanged, .versionSelectionChanged:
      return 2
    case .photosChanged:
      return 30
    case .photosChangeFallback:
      return 120
    case .userExportNow:
      // Plan: "manual Export Now: no debounce after guard checks." Modeled as 0.
      return 0
    }
  }
}
