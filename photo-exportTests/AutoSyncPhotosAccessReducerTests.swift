import Foundation
import Testing

@testable import Photo_Export

/// Auto Export is blocked while Photos access is missing, so it never dispatches a run that
/// can only fail or scan an empty library. Access returning marks every selected scope for
/// full reconciliation and schedules a catch-up.
struct AutoSyncPhotosAccessReducerTests {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)
  private let destination = DestinationSnapshot(
    stableId: "access-A", fingerprint: nil, isAvailable: true, safety: .safe)
  private var destinationId: String { destination.id! }
  private let timeline = AutoExportScopeSelection(timeline: true)

  /// Enabled and idle with Timeline, optionally with one pending asset.
  private func ready(dirty: Bool = false) -> AutoSyncReducer.State {
    var state = AutoSyncReducer.State.initial
    state.enabled = true
    state.destination = destination
    state.scopeSelection = timeline
    if dirty {
      var scope = ScopeDirtyState()
      scope.recordPendingAssetId("pending", costCap: 500)
      var work = AutoSyncDirtyState()
      work.setScope(.timeline, scope)
      state.dirtyStateByDestination[destinationId] = work
    }
    state.current = .idle
    return state
  }

  private func context(reason: AutoSyncReason = .photosChanged) -> ExportRunContext {
    ExportRunContext(
      source: .autoSync, visibility: .background, reason: reason, scope: .timelineFullLibrary,
      selection: .edited, startedAt: now)
  }

  private func running(_ context: ExportRunContext, dirty: Bool = true) -> AutoSyncReducer.State {
    var state = ready(dirty: dirty)
    state.current = .running(reason: context.reason ?? .photosChanged)
    state = reduce(.exportRunStarted(context, destinationId: destinationId), state).0
    return reduce(
      .exportRunStateChanged(
        ExportRunState(activeContext: context, isManualActive: false, isAutoSyncActive: true)),
      state
    ).0
  }

  private func reduce(
    _ event: AutoSyncEvent, _ state: AutoSyncReducer.State
  ) -> (AutoSyncReducer.State, [AutoSyncEffect]) {
    AutoSyncReducer.reduce(event, in: state, now: now)
  }

  private func apply(_ events: [AutoSyncEvent], to state: AutoSyncReducer.State)
    -> AutoSyncReducer.State
  {
    events.reduce(state) { reduce($1, $0).0 }
  }

  private func schedules(_ effects: [AutoSyncEffect]) -> Bool {
    effects.contains { if case .scheduleDebounce = $0 { true } else { false } }
  }

  private func startsRun(_ effects: [AutoSyncEffect]) -> Bool {
    effects.contains { if case .startRun = $0 { true } else { false } }
  }

  private func stopSummary(_ context: ExportRunContext) -> ExportRunSummary {
    ExportRunSummary(
      context: context, endedAt: now, enqueuedCount: 2, completedCount: 1, failedCount: 1,
      skippedCount: 0, cancelReason: nil, result: .failed, stoppedBy: .destinationNoSpace)
  }

  private func fullReconciliationSaved(_ effects: [AutoSyncEffect]) -> Bool {
    effects.contains {
      guard case .persistDirtyState(let dirty, let id) = $0 else { return false }
      return id == destinationId && dirty.scope(.timeline).pendingFullReconciliation
    }
  }

  // MARK: - Losing access

  @Test func accessLostWhileIdleBlocksAndRepublishingDoesNothing() {
    let (blocked, effects) = reduce(.photosAuthorizationChanged(false), ready(dirty: true))
    #expect(blocked.current == .blocked(.photosAccessMissing))
    #expect(!blocked.photosAuthorized)
    #expect(effects.isEmpty)

    let (again, againEffects) = reduce(.photosAuthorizationChanged(false), blocked)
    #expect(again == blocked)
    #expect(againEffects.isEmpty)

    let authorized = ready(dirty: true)
    let (unchanged, unchangedEffects) = reduce(.photosAuthorizationChanged(true), authorized)
    #expect(unchanged == authorized)
    #expect(unchangedEffects.isEmpty)
  }

  @Test(arguments: [
    AutoSyncReason.appLaunch, .scopeSelectionChanged, .userExportNow, .photosChanged,
  ])
  func accessLostWhileScheduledCancelsTheRunAndKeepsItsReason(reason: AutoSyncReason) {
    var state = ready(dirty: true)
    state.current = .scheduled(reason: reason, fireAt: now.addingTimeInterval(5))
    let (blocked, effects) = reduce(.photosAuthorizationChanged(false), state)
    #expect(blocked.current == .blocked(.photosAccessMissing))
    #expect(effects == [.cancelDebounce(reason)])
    // A Photos-change reason is already in the dirty state, which stays.
    #expect(blocked.pendingTriggerReason == (reason == .photosChanged ? nil : reason))
    #expect(blocked.dirtyStateByDestination[destinationId]?.scope(.timeline).isEmpty == false)
  }

  @Test func accessLostWhileRunningLetsTheRunFinishAndSchedulesNothing() {
    let run = context()
    let (blocked, effects) = reduce(.photosAuthorizationChanged(false), running(run))
    #expect(blocked.current == .blocked(.photosAccessMissing))
    #expect(effects.isEmpty)

    let (idle, idleEffects) = reduce(.exportRunStateChanged(.idle), blocked)
    #expect(idle.current == .blocked(.photosAccessMissing))
    #expect(!schedules(idleEffects))

    let failed = ExportRunSummary(
      context: run, endedAt: now, enqueuedCount: 0, completedCount: 0, failedCount: 0,
      skippedCount: 0, cancelReason: nil, result: .failed)
    let (done, doneEffects) = reduce(
      .autoSyncRunCompleted(failed, destinationId: destinationId), idle)
    #expect(doneEffects.contains(.persistRunSummary(failed, destinationId: destinationId)))
    #expect(!schedules(doneEffects))
    #expect(done.current == .blocked(.photosAccessMissing))
    #expect(done.dirtyStateByDestination[destinationId]?.scope(.timeline).isEmpty == false)
  }

  @Test func noRunStartsWhileAccessIsMissing() {
    var state = ready(dirty: true)
    state.photosAuthorized = false
    state.current = .scheduled(reason: .userExportNow, fireAt: now)
    let (fired, effects) = reduce(.debounceFired(.userExportNow), state)
    #expect(!startsRun(effects))
    #expect(fired.current == .blocked(.photosAccessMissing))

    let (pressed, pressedEffects) = reduce(.runNowRequested, fired)
    #expect(!schedules(pressedEffects))
    #expect(pressed.current == .blocked(.photosAccessMissing))
    #expect(pressed.pendingTriggerReason == .userExportNow)
  }

  // MARK: - Precedence

  enum Blocker: String, CaseIterable, Sendable {
    case importing, manualExport, noScopes, noDestination, disconnected, unsafe
  }

  private func block(_ blocker: Blocker) -> AutoSyncEvent {
    switch blocker {
    case .importing: .importStateChanged(isImporting: true)
    case .manualExport:
      .exportRunStateChanged(
        ExportRunState(activeContext: nil, isManualActive: true, isAutoSyncActive: false))
    case .noScopes: .scopeSelectionChanged(AutoExportScopeSelection())
    case .noDestination: .destinationChanged(.none)
    case .disconnected:
      .destinationChanged(
        DestinationSnapshot(
          stableId: "access-A", fingerprint: nil, isAvailable: false, safety: .safe))
    case .unsafe:
      .destinationChanged(
        DestinationSnapshot(
          stableId: "access-A", fingerprint: nil, isAvailable: true,
          safety: .unsafeNeedsConfirmation))
    }
  }

  private func release(_ blocker: Blocker) -> AutoSyncEvent {
    switch blocker {
    case .importing: .importStateChanged(isImporting: false)
    case .manualExport: .exportRunStateChanged(.idle)
    case .noScopes: .scopeSelectionChanged(timeline)
    case .noDestination, .disconnected, .unsafe: .destinationChanged(destination)
    }
  }

  private func state(for blocker: Blocker) -> AutoSyncState {
    switch blocker {
    case .importing: .waiting(.importActive)
    case .manualExport: .waiting(.manualExportActive)
    case .noScopes: .blocked(.noScopesSelected)
    case .noDestination: .blocked(.destinationMissing)
    case .disconnected: .waiting(.destinationUnavailable)
    case .unsafe: .blocked(.destinationUnsafe)
    }
  }

  /// Import and manual-export waits keep their resume rules, so they rank above missing
  /// access. No other blocker can be fixed without access, so missing access ranks above
  /// them. The order the two arrive in, and the order they clear in, don't matter.
  @Test(arguments: Blocker.allCases)
  func missingAccessRanksBelowImportAndManualWaitsAndAboveEveryOtherBlocker(blocker: Blocker) {
    let combined: AutoSyncState =
      blocker == .importing || blocker == .manualExport
      ? state(for: blocker) : .blocked(.photosAccessMissing)
    let lost = AutoSyncEvent.photosAuthorizationChanged(false)
    let back = AutoSyncEvent.photosAuthorizationChanged(true)

    let blockerFirst = apply([block(blocker), lost], to: ready())
    #expect(blockerFirst.current == combined, "blocker, then access lost")
    let accessFirst = apply([lost, block(blocker)], to: ready())
    #expect(accessFirst.current == combined, "access lost, then blocker")

    #expect(
      apply([release(blocker)], to: blockerFirst).current == .blocked(.photosAccessMissing),
      "blocker clears first")
    #expect(apply([back], to: accessFirst).current == state(for: blocker), "access returns first")
  }

  // MARK: - Access returning

  private func retryDue() -> AutoSyncRetryState {
    var retry = AutoSyncRetryState.empty
    retry.recordFailure(
      scope: .timeline, assetId: "retry", variant: .original, category: .photoKitTransient,
      errorSignature: "same", at: now.addingTimeInterval(-30), nextEligibleAt: now)
    return retry
  }

  /// A pending reason with a delay no longer than a Photos change's runs as itself, so
  /// Export Now and retries keep their zero delay. Otherwise a Photos change runs.
  @Test(arguments: [
    AutoSyncReason?.none, .userExportNow, .retryBackoff, .scopeSelectionChanged,
    .photosChangeFallback,
  ])
  func accessReturningRunsAFullCatchUpUnderThePendingReason(pending: AutoSyncReason?) {
    var state = reduce(.photosAuthorizationChanged(false), ready()).0
    #expect(state.current == .blocked(.photosAccessMissing))
    switch pending {
    case .userExportNow?: state = reduce(.runNowRequested, state).0
    case .scopeSelectionChanged?:
      state =
        reduce(
          .scopeSelectionChanged(AutoExportScopeSelection(timeline: true, favorites: true)), state
        ).0
    case .retryBackoff?:
      state = apply(
        [
          .retryStateChanged(destinationId: destinationId, retryState: retryDue()),
          .retryTimerFired,
        ],
        to: state)
    case .photosChangeFallback?: state = reduce(.photosChangeFetchFailed(.tokenExpired), state).0
    default: break
    }
    #expect(state.pendingTriggerReason == pending)
    #expect(state.current == .blocked(.photosAccessMissing))

    let (restored, effects) = reduce(.photosAuthorizationChanged(true), state)
    // The fallback's 2-minute delay is longer than a Photos change's, so it doesn't win.
    let reason = pending == .photosChangeFallback ? .photosChanged : pending ?? .photosChanged
    #expect(
      restored.current
        == .scheduled(
          reason: reason, fireAt: now.addingTimeInterval(AutoSyncReducer.debounceDelay(for: reason))
        ))
    #expect(restored.pendingTriggerReason == nil)
    #expect(fullReconciliationSaved(effects))
    for scope in restored.scopeSelection.enabledScopes {
      #expect(
        restored.dirtyStateByDestination[destinationId]?.scope(scope).pendingFullReconciliation
          == true)
    }
  }

  @Test func accessReturningWhileTheDriveIsDisconnectedWaitsForTheDrive() {
    let disconnected = DestinationSnapshot(
      stableId: "access-A", fingerprint: nil, isAvailable: false, safety: .safe)
    let state = apply(
      [.photosAuthorizationChanged(false), .destinationChanged(disconnected)], to: ready())
    #expect(state.current == .blocked(.photosAccessMissing))

    let (restored, effects) = reduce(.photosAuthorizationChanged(true), state)
    #expect(restored.current == .waiting(.destinationUnavailable))
    #expect(fullReconciliationSaved(effects))
    #expect(!schedules(effects))

    let reconnected = reduce(.destinationChanged(destination), restored).0
    #expect(
      reconnected.current
        == .scheduled(
          reason: .destinationBecameAvailable,
          fireAt: now.addingTimeInterval(
            AutoSyncReducer.debounceDelay(for: .destinationBecameAvailable))))
  }

  // MARK: - Stopped runs

  enum ToggleOrder: String, CaseIterable, Sendable {
    /// Access goes and returns while the run is still active, so the stop holds it.
    case bothDuringRun
    /// Access goes during the run and returns after the run stopped.
    case acrossTheStop
    /// Access goes and returns after the run stopped.
    case bothAfterStop
    /// The stop summary arrives first, then access goes and returns, all while the run is
    /// still active, then the run goes idle. The stop is already known when access returns,
    /// so this schedules, like the orders where access returns after the stop. The summary
    /// always comes first here, whatever `summaryFirst` says.
    case summaryThenBothDuringRun
  }

  /// A destination stop holds dirty work until the next real trigger, because a retry would
  /// hit the same full or unreachable drive, and access returning says nothing about the
  /// drive. Returning during the stopped run is held like any other change made during it;
  /// the saved full reconciliation exports on the next trigger. Returning once the stop is
  /// known (the summary has arrived, or the reducer is blocked or idle) schedules the
  /// catch-up. Either way, whether the stop summary arrives before or after the idle state.
  @Test(arguments: ToggleOrder.allCases, [false, true])
  func accessReturningAroundAStoppedRun(order: ToggleOrder, summaryFirst: Bool) {
    let run = context()
    let lost = AutoSyncEvent.photosAuthorizationChanged(false)
    let back = AutoSyncEvent.photosAuthorizationChanged(true)
    let stop: [AutoSyncEvent] =
      summaryFirst
      ? [
        .autoSyncRunCompleted(stopSummary(run), destinationId: destinationId),
        .exportRunStateChanged(.idle),
      ]
      : [
        .exportRunStateChanged(.idle),
        .autoSyncRunCompleted(stopSummary(run), destinationId: destinationId),
      ]
    let events: [AutoSyncEvent]
    switch order {
    case .bothDuringRun: events = [lost, back] + stop
    case .acrossTheStop: events = [lost] + stop + [back]
    case .bothAfterStop: events = stop + [lost, back]
    case .summaryThenBothDuringRun:
      events = [
        .autoSyncRunCompleted(stopSummary(run), destinationId: destinationId), lost, back,
        .exportRunStateChanged(.idle),
      ]
    }
    let state = apply(events, to: running(run))
    if order == .bothDuringRun {
      #expect(state.current == .idle)
      #expect(state.pendingTriggerReason == nil)
    } else {
      #expect(
        state.current
          == .scheduled(
            reason: .photosChanged,
            fireAt: now.addingTimeInterval(AutoSyncReducer.debounceDelay(for: .photosChanged))))
    }
    #expect(
      state.dirtyStateByDestination[destinationId]?.scope(.timeline).pendingFullReconciliation
        == true)
  }
}
