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
    /// Issue #47: when on, AutoSync widens `requiredVariants` for HEIC
    /// originals (HEIC counts as adjusted-equivalent), so the eligibility
    /// pass re-emits previously-skipped HEIC assets. Toggle changes
    /// re-trigger the reducer at the same 2s debounce as
    /// `versionSelection`.
    var convertHEICToJPEG: Bool
    var importActive: Bool
    var exportRunState: ExportRunState
    /// Per-destination accumulated dirty state. Updated by `photosChanged` events
    /// (asset id targeting + cost-cap rollover) and by full-reconciliation completion.
    /// Keyed by destination id; entries persist across destination switches so
    /// reconnecting the same drive resumes its accumulated work.
    var dirtyStateByDestination: [String: AutoSyncDirtyState]
    /// Trigger reason that was set while the reducer was blocked (waiting on import,
    /// destination unavailable, etc.) and couldn't immediately schedule. The
    /// resume hook re-fires it when the blocker resolves so non-dirty triggers
    /// (appLaunch, scope change, version change) aren't silently lost. Cleared on
    /// fire or on superseding trigger.
    var pendingTriggerReason: AutoSyncReason?

    static let initial = State(
      current: .disabled,
      enabled: false,
      destination: .none,
      scopeSelection: AutoExportScopeSelection(),
      versionSelection: .edited,
      convertHEICToJPEG: false,
      importActive: false,
      exportRunState: .idle,
      dirtyStateByDestination: [:],
      pendingTriggerReason: nil
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

    case .convertHEICToJPEGChanged(let value):
      newState.convertHEICToJPEG = value
      if value != state.convertHEICToJPEG {
        triggerReason = .convertHEICToJPEGChanged
      }

    case .importStateChanged(let isImporting):
      newState.importActive = isImporting

    case .exportRunStateChanged(let runState):
      // Just track the run state — dirty-clearing is gated on the auto-sync run's
      // *result* and arrives via a separate `.autoSyncRunCompleted(summary)` event
      // dispatched by the manager after the run task returns. Without that signal
      // we'd clear dirty on cancelled/interrupted/failed runs and lose pending
      // work the run never actually exported.
      newState.exportRunState = runState

    case .autoSyncRunCompleted(let summary):
      // The summary's `result` distinguishes a clean run (where the full
      // reconciliation processed everything in scope) from a transient failure
      // (where pending IDs must remain queued for retry). Persist the summary in
      // either case so the UI can surface "last ran X ago, with N failures."
      if let destinationId = newState.destination.id {
        effects.append(.persistRunSummary(summary, destinationId: destinationId))
      }
      if !summary.failures.isEmpty, let destinationId = newState.destination.id {
        // Route per-variant failures into AutoSyncRetryState so the Issues UI
        // and (Slice C) the enqueue-time eligibility check can see them.
        // Slice B records the failure with `nextEligibleAt = nil`; the
        // backoff schedule lands in Slice C alongside enqueue gating.
        effects.append(
          .recordRetryFailures(summary.failures, destinationId: destinationId))
      }
      if summary.result == .completed,
        let destinationId = newState.destination.id
      {
        // Clear dirty only for the scope the summary actually covered. The
        // manager's autoExport fan-out dispatches one `autoSyncRunCompleted`
        // per scope, so a Timeline-only summary must not clear Favorites
        // dirty (which Favorites' own run will handle). For the legacy
        // `.autoExport(scopes)` summary shape (still used by tests and any
        // future single-pass runner), clear all selected scopes that the
        // umbrella scope set covers.
        let coveredScopes = Self.coveredScopes(
          summary: summary, currentSelection: newState.scopeSelection)
        var dirty = newState.dirtyStateByDestination[destinationId] ?? .empty
        for scope in coveredScopes {
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
        let sharedAlbumsActive = state.scopeSelection.includes(.sharedAlbums)
        // `collectionChangesPresent` is shared by both album kinds — Photos doesn't
        // tell us which collection class changed, so any collection-level mutation
        // (album add/remove/rename, shared-album membership change) bumps the
        // placement-reconciliation flag on every enabled album-shaped scope.
        let albumsRelevantCollectionChange =
          (albumsActive || sharedAlbumsActive) && event.collectionChangesPresent
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
            if (scope == .albums || scope == .sharedAlbums)
              && event.collectionChangesPresent
            {
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

    case .photosChangeFetchFailed(let failure):
      // Plan §"Photo Library Changes": all three failure modes (tokenExpired,
      // tokenInvalid, detailsUnavailable) reset the affected destination's
      // lastDurablyRecordedToken and schedule one bounded full reconciliation. The
      // 2-minute photosChangeFallback debounce gives the system a quiet window
      // before the recovery run.
      //
      // Disabled / no-destination / no-scopes selected → ignore (no work to do).
      if state.enabled, let destinationId = state.destination.id,
        !state.scopeSelection.isEmpty
      {
        // Mark every selected scope as needing full reconciliation. The runner
        // resets the per-destination token snapshot to the current global token
        // when it sees the matching `lastDurablyRecordedToken` reset path; the
        // reducer's contribution is to flip the dirty flags and trigger the
        // fallback debounce.
        var dirty = state.dirtyStateByDestination[destinationId] ?? .empty
        for scope in state.scopeSelection.enabledScopes {
          var scopeState = dirty.scope(scope)
          scopeState.pendingFullReconciliation = true
          scopeState.pendingAssetIds.removeAll()
          dirty.setScope(scope, scopeState)
        }
        dirty.markUpdated(at: now)
        newState.dirtyStateByDestination[destinationId] = dirty
        effects.append(.persistDirtyState(dirty, destinationId: destinationId))
        triggerReason = .photosChangeFallback
        // failure is informational — subsequent slices that wire diagnostics may
        // log/route by category. Avoid `unused` warning with explicit suppression.
        _ = failure
      }

    case .retryTimerFired:
      // Plan §"Retry and Failure Policy" — retry eligibility lives at enqueue
      // time inside `ExportManager`, not here. The reducer's role is to fall
      // through to the recompute pass so any state that became eligible in the
      // wall-clock interval since the timer was scheduled is re-evaluated.
      // Dirty-state mutation and run-start decisions hang off the existing
      // recompute path; nothing reducer-side has to change for the timer
      // itself.
      break

    case .manualFullExportCompleted(let summary):
      // Plan §"Dirty State": "A manual full export for the same destination /
      // selection / scope clears compatible dirty flags." Compatibility is
      // strict — only `.completed` runs from `.manual` source over a full
      // scope (timelineFullLibrary / favoritesFull / allAlbumsFull) clear
      // anything, and the run's `selection` must match the current
      // versionSelection. Targeted asset runs and partial-failure runs leave
      // dirty state untouched: they didn't process the full scope, so pending
      // assets that *weren't* in their target list are still pending.
      guard summary.result == .completed,
        summary.context.source == .manual,
        summary.context.selection == newState.versionSelection,
        let destinationId = newState.destination.id
      else { break }

      let coveredScopes: Set<AutoExportLibraryScope> =
        summary.context.scope.clearableScope.map { [$0] } ?? []
      guard !coveredScopes.isEmpty else { break }

      var dirty = newState.dirtyStateByDestination[destinationId] ?? .empty
      var changed = false
      for scope in coveredScopes where newState.scopeSelection.includes(scope) {
        var scopeState = dirty.scope(scope)
        scopeState.clearAfterSuccessfulFullReconciliation()
        dirty.setScope(scope, scopeState)
        changed = true
      }
      if changed {
        dirty.markUpdated(at: now)
        newState.dirtyStateByDestination[destinationId] = dirty
        effects.append(.persistDirtyState(dirty, destinationId: destinationId))
      }

    case .runNowRequested:
      // The user clicked Export Now. Route through the existing
      // trigger-reason mechanism — `.userExportNow` has a 0s debounce delay,
      // so the recompute pass below will land in `.scheduled(.userExportNow,
      // fireAt: now)` and the runner fires the timer on the next tick.
      // Honors safety + scope + destination + import gates via recompute;
      // the bypass-disabled behavior the plan specifies for the menu-bar
      // Export Now is deferred — for Slice 1 the UI only surfaces this
      // button when `state != .disabled`.
      triggerReason = .userExportNow

    case .destinationDirtyStateLoaded(let destinationId, let dirty):
      // Manager dispatches this on destination-change before
      // `destinationChanged`, so the reducer's `dirtyStateByDestination` cache
      // is populated for the new destination *before* downstream events
      // (photosChanged, debounce) consult it. Idempotent: re-loading the same
      // state is a byte-identical merge, and the recompute pass below has no
      // input changes to react to.
      newState.dirtyStateByDestination[destinationId] = dirty
    }

    // Save the trigger reason for resume *before* recompute decides whether to
    // schedule. If recompute lands the state in idle/scheduled, the trigger fires
    // there and we clear pendingTriggerReason. If it lands blocked/waiting, the
    // trigger is preserved for resume.
    if let triggerReason {
      newState.pendingTriggerReason = triggerReason
    }

    let nextCurrent = recomputeCurrent(
      from: newState, previous: state.current,
      triggerReason: newState.pendingTriggerReason, now: now,
      effects: &effects)
    newState.current = nextCurrent

    // If the recompute scheduled a debounce, the trigger has been "consumed" — drop
    // pendingTriggerReason. Same for direct .running transitions.
    if case .scheduled = newState.current {
      newState.pendingTriggerReason = nil
    } else if case .running = newState.current {
      newState.pendingTriggerReason = nil
    }

    // Work-preservation hook. If we just landed in `.idle` from a state that paused
    // pending work — `.running` (run finished), `.waiting(.importActive)` (import
    // done), `.waiting(.manualExportActive)` (manual run done) — and there's
    // accumulated dirty for the current destination OR a pendingTriggerReason
    // from a non-dirty trigger (appLaunch, scope change, etc.), schedule a debounce
    // so the pending work is processed instead of sitting forever. Without this,
    // photos changes / scope changes / app-launch enables during long exports /
    // imports / manual runs would be silently abandoned until an unrelated event
    // happens to re-trigger.
    if case .idle = newState.current,
      previousIsBlockingResumePoint(state.current),
      let destinationId = newState.destination.id
    {
      let hasDirty = newState.dirtyStateByDestination[destinationId]?.isEmpty == false
      if let resumeReason = newState.pendingTriggerReason {
        let fireAt = now.addingTimeInterval(debounceDelay(for: resumeReason))
        effects.append(.scheduleDebounce(resumeReason, fireAt: fireAt))
        newState.current = .scheduled(reason: resumeReason, fireAt: fireAt)
        newState.pendingTriggerReason = nil
      } else if hasDirty {
        let fireAt = now.addingTimeInterval(debounceDelay(for: .photosChanged))
        effects.append(.scheduleDebounce(.photosChanged, fireAt: fireAt))
        newState.current = .scheduled(reason: .photosChanged, fireAt: fireAt)
      }
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
  /// Maps a completed run's scope to the `AutoExportLibraryScope` set it
  /// reconciled. Single-scope full runs map to one scope; the legacy
  /// `.autoExport(scopes)` umbrella covers all enabled scopes; targeted-asset
  /// scopes don't reconcile a full scope and return empty so dirty stays put
  /// (their pending-asset bookkeeping happens elsewhere).
  private static func coveredScopes(
    summary: ExportRunSummary, currentSelection: AutoExportScopeSelection
  ) -> Set<AutoExportLibraryScope> {
    // The `.autoExport` umbrella carries its own per-scope selection and is the
    // one case `ExportRunScope.clearableScope` doesn't handle — it has to
    // intersect with the *current* selection so a scope the user removed
    // between dispatch and completion doesn't get its lingering dirty
    // unexpectedly cleared. Single-scope full-run cases route through the
    // shared `clearableScope` mapping; targeted-asset cases return `nil` (no
    // blanket clear).
    if case .autoExport(let scopes) = summary.context.scope {
      return Set(scopes.enabledScopes).intersection(Set(currentSelection.enabledScopes))
    }
    return summary.context.scope.clearableScope.map { [$0] } ?? []
  }

  private static func environmentAllowsRun(state: State) -> Bool {
    // `!isAutoSyncActive` closes a race exposed by issue-#69-era manual testing:
    // a debounce that fires while a multi-scope AutoSync fan-out is mid-flight
    // (e.g. scope #1 finished, scope #2's `runExport` is suspended) would
    // otherwise emit a fresh `.startRun` and trip
    // `ExportManager.runExport`'s single-active-run precondition. The fan-out's
    // own `await runExport` is already keeping `activeRunContext != nil`; we
    // must not start a second concurrent run.
    state.enabled && !state.importActive && !state.scopeSelection.isEmpty
      && state.destination.id != nil && state.destination.isAvailable
      && state.destination.safety == .safe
      && !state.exportRunState.isManualActive
      && !state.exportRunState.isAutoSyncActive
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
      // A photos-related debounce that's still scheduled but has no remaining
      // work for any selected scope is stale — it would fire a run with
      // nothing to export. Common path: manualFullExportCompleted just
      // cleared the dirty work the debounce was waiting on. Cancel and drop
      // to idle. Other reasons (appLaunch, destinationSelected, scope/version
      // changes) preserve their schedule because they aren't gated on
      // dirty-state contents.
      if reason == .photosChanged || reason == .photosChangeFallback,
        let destinationId = state.destination.id,
        let dirty = state.dirtyStateByDestination[destinationId],
        state.scopeSelection.enabledScopes.allSatisfy({ dirty.scope($0).isEmpty })
      {
        effects.append(.cancelDebounce(reason))
        return .idle
      }
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
    case .scopeSelectionChanged, .versionSelectionChanged, .convertHEICToJPEGChanged:
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
