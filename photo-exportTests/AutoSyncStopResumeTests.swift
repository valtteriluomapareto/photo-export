import Foundation
import Testing

@testable import Photo_Export

/// A run that stopped on a destination-wide failure (unreachable, full, denied) while the
/// destination still looks available must not be rescheduled by the resume hook: the next
/// run would stop the same way, every 30 seconds. Its dirty work waits for the next real
/// trigger. Production publishes the idle run state before the completion summary.
struct AutoSyncStopResumeTests {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)
  private var later: Date { now.addingTimeInterval(5) }

  private static let stopCategories: [AutoSyncFailureCategory] = [
    .destinationUnavailable, .destinationNoSpace, .destinationPermission,
  ]

  private func destination(safety: DestinationSafetyState = .safe) -> DestinationSnapshot {
    DestinationSnapshot(stableId: "stop-A", fingerprint: nil, isAvailable: true, safety: safety)
  }

  private var destinationId: String { destination().id! }

  private func context(reason: AutoSyncReason = .photosChanged) -> ExportRunContext {
    ExportRunContext(
      source: .autoSync, visibility: .background, reason: reason, scope: .timelineFullLibrary,
      selection: .edited, startedAt: now)
  }

  /// Enabled with Timeline, one pending asset, and `context`'s run in progress.
  private func running(
    _ context: ExportRunContext, dirty: Bool = true
  ) -> AutoSyncReducer.State {
    var state = idle(dirty: dirty)
    state.current = .running(reason: context.reason ?? .photosChanged)
    state = reduce(.exportRunStarted(context, destinationId: destinationId), state).0
    return reduce(
      .exportRunStateChanged(
        ExportRunState(activeContext: context, isManualActive: false, isAutoSyncActive: true)),
      state
    ).0
  }

  /// Enabled and idle with Timeline, optionally with one pending asset.
  private func idle(dirty: Bool) -> AutoSyncReducer.State {
    var state = AutoSyncReducer.State.initial
    state.enabled = true
    state.destination = destination()
    state.scopeSelection = AutoExportScopeSelection(timeline: true)
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

  private func summary(
    _ context: ExportRunContext, stoppedBy: AutoSyncFailureCategory?
  ) -> ExportRunSummary {
    let category = stoppedBy ?? .unknown
    let unreachable = stoppedBy == .destinationUnavailable
    return ExportRunSummary(
      context: context, endedAt: now, enqueuedCount: 3, completedCount: 1, failedCount: 1,
      skippedCount: 0, cancelReason: unreachable ? .destinationUnavailable : nil,
      result: unreachable ? .interrupted : .failed,
      failures: [
        ExportRunFailureDetail(
          assetId: "pending", placement: .timeline(year: 2026, month: 9), variant: .original,
          category: category, errorSignature: "NSPOSIXErrorDomain:57",
          localizedDescription: "Socket is not connected", failedAt: now)
      ],
      stoppedBy: stoppedBy)
  }

  private func reduce(
    _ event: AutoSyncEvent, _ state: AutoSyncReducer.State, at date: Date? = nil
  ) -> (AutoSyncReducer.State, [AutoSyncEffect]) {
    AutoSyncReducer.reduce(event, in: state, now: date ?? now)
  }

  private func completed(
    _ summary: ExportRunSummary, _ state: AutoSyncReducer.State, at date: Date? = nil
  ) -> (AutoSyncReducer.State, [AutoSyncEffect]) {
    reduce(.autoSyncRunCompleted(summary, destinationId: destinationId), state, at: date)
  }

  private func schedules(_ effects: [AutoSyncEffect]) -> [AutoSyncReason] {
    effects.compactMap {
      if case .scheduleDebounce(let reason, _) = $0 { return reason }
      return nil
    }
  }

  private func pendingAssets(_ state: AutoSyncReducer.State) -> Set<String>? {
    state.dirtyStateByDestination[destinationId]?.scope(.timeline).pendingAssetIds
  }

  @Test(arguments: stopCategories)
  func stopSummaryCancelsTheResumeHooksSchedule(stoppedBy: AutoSyncFailureCategory) {
    let run = context()
    let (idle, _) = reduce(.exportRunStateChanged(.idle), running(run))
    #expect(idle.current == .scheduled(reason: .photosChanged, fireAt: now.addingTimeInterval(30)))

    let (stopped, effects) = completed(summary(run, stoppedBy: stoppedBy), idle)

    #expect(stopped.current == .idle)
    #expect(effects.contains(.cancelDebounce(.photosChanged)))
    #expect(schedules(effects).isEmpty)
    #expect(pendingAssets(stopped) == ["pending"], "Dirty work waits for the next trigger")
    #expect(stopped.pendingTriggerReason == nil)

    // A Photos change after the stop schedules as usual.
    let change = PhotoLibraryPersistentChangeEvent(
      insertedLocalIdentifiers: ["new"], observedAt: later)
    let (changed, changeEffects) = reduce(.photosChanged(change), stopped, at: later)
    #expect(
      changed.current == .scheduled(reason: .photosChanged, fireAt: later.addingTimeInterval(30)))
    #expect(schedules(changeEffects) == [.photosChanged])
  }

  /// Guard: a failed run that did not stop on a destination-wide failure keeps today's
  /// reschedule for its pending work.
  @Test func failedSummaryWithoutAStopKeepsTheReschedule() {
    let run = context()
    let (idle, _) = reduce(.exportRunStateChanged(.idle), running(run))
    let (next, effects) = completed(summary(run, stoppedBy: nil), idle)
    #expect(next.current == .scheduled(reason: .photosChanged, fireAt: now.addingTimeInterval(30)))
    #expect(!effects.contains(.cancelDebounce(.photosChanged)))
  }

  /// Guard: a Photos change between the idle publication and the stop summary is a new
  /// trigger. Its schedule stays, even when it lands on the same instant as the hook's.
  @Test func photosChangeBeforeTheStopSummaryKeepsItsSchedule() {
    let run = context()
    let (idle, _) = reduce(.exportRunStateChanged(.idle), running(run))
    let change = PhotoLibraryPersistentChangeEvent(
      insertedLocalIdentifiers: ["new"], observedAt: now)
    let (changed, _) = reduce(.photosChanged(change), idle)
    let (next, effects) = completed(summary(run, stoppedBy: .destinationUnavailable), changed)
    #expect(next.current == .scheduled(reason: .photosChanged, fireAt: now.addingTimeInterval(30)))
    #expect(!effects.contains(.cancelDebounce(.photosChanged)))
  }

  /// A reordered publisher that delivers the summary before idle must not bring the
  /// reschedule back.
  @Test(arguments: stopCategories)
  func stopSummaryBeforeIdleSuppressesTheResumeHook(stoppedBy: AutoSyncFailureCategory) {
    let run = context()
    let (afterSummary, summaryEffects) = completed(
      summary(run, stoppedBy: stoppedBy), running(run))
    #expect(afterSummary.current == .running(reason: .photosChanged))
    #expect(schedules(summaryEffects).isEmpty)

    let (idle, effects) = reduce(.exportRunStateChanged(.idle), afterSummary)
    #expect(idle.current == .idle)
    #expect(schedules(effects).isEmpty)
    #expect(pendingAssets(idle) == ["pending"])
  }

  /// The summary itself ends the run when the reducer never saw the run's state change:
  /// it is still `.running` from the debounce, with an idle run state. `ExportManager`
  /// always publishes the active and idle states first, so no production order gives this;
  /// `FakeAutoSyncExportRunner` does, since it never publishes a run state, and a runner
  /// that resolves without publishing would. That transition is suppressed too.
  @Test func stopSummaryThatEndsTheRunDoesNotReschedule() {
    let run = context()
    var state = running(run)
    state.exportRunState = .idle
    let (next, effects) = completed(summary(run, stoppedBy: .destinationUnavailable), state)
    #expect(next.current == .idle)
    #expect(schedules(effects).isEmpty)
  }

  /// Guard: Export Now pressed during the run still runs after the stop.
  @Test(arguments: [false, true])
  func exportNowDuringTheRunStillSchedules(summaryFirst: Bool) {
    let run = context()
    let (requested, _) = reduce(.runNowRequested, running(run))
    #expect(requested.pendingTriggerReason == .userExportNow)
    let stop = summary(run, stoppedBy: .destinationUnavailable)
    let next: AutoSyncReducer.State
    if summaryFirst {
      next = reduce(.exportRunStateChanged(.idle), completed(stop, requested).0).0
    } else {
      next = completed(stop, reduce(.exportRunStateChanged(.idle), requested).0).0
    }
    #expect(next.current == .scheduled(reason: .userExportNow, fireAt: now))
  }

  /// A trigger that arrived during the run and adds no dirty work is not resumed by itself,
  /// but its reason is kept for the next run instead of being lost.
  @Test(arguments: [false, true])
  func midRunScopeChangeIsHeldForTheNextTrigger(summaryFirst: Bool) {
    let run = context()
    let (changed, _) = reduce(
      .scopeSelectionChanged(AutoExportScopeSelection(timeline: true, favorites: true)),
      running(run, dirty: false))
    #expect(changed.pendingTriggerReason == .scopeSelectionChanged)
    let stop = summary(run, stoppedBy: .destinationUnavailable)
    var effects: [AutoSyncEffect] = []
    var next: AutoSyncReducer.State
    if summaryFirst {
      let first = completed(stop, changed)
      let second = reduce(.exportRunStateChanged(.idle), first.0)
      next = second.0
      effects = first.1 + second.1
    } else {
      let first = reduce(.exportRunStateChanged(.idle), changed)
      #expect(
        first.0.current
          == .scheduled(reason: .scopeSelectionChanged, fireAt: now.addingTimeInterval(2)))
      let second = completed(stop, first.0)
      next = second.0
      effects = second.1
      #expect(effects.contains(.cancelDebounce(.scopeSelectionChanged)))
    }
    #expect(next.current == .idle)
    #expect(next.pendingTriggerReason == .scopeSelectionChanged)

    // Bookkeeping events after the stop do not fire the held reason.
    let (afterRetry, retryEffects) = reduce(
      .retryStateChanged(destinationId: destinationId, retryState: .empty), next, at: later)
    #expect(afterRetry.current == .idle)
    #expect(schedules(retryEffects).isEmpty)

    // An import that comes and goes resumes it, as for any held trigger.
    let (importing, _) = reduce(.importStateChanged(isImporting: true), afterRetry, at: later)
    let (resumed, _) = reduce(.importStateChanged(isImporting: false), importing, at: later)
    #expect(
      resumed.current
        == .scheduled(reason: .scopeSelectionChanged, fireAt: later.addingTimeInterval(2)))
    #expect(resumed.pendingTriggerReason == nil)
  }

  /// A Photos change during the run is dirty work: after the stop it waits in the dirty
  /// state, not as a held trigger.
  @Test func midRunPhotosChangeWaitsAsDirtyWork() {
    let run = context()
    let change = PhotoLibraryPersistentChangeEvent(
      insertedLocalIdentifiers: ["mid-run"], observedAt: now)
    let (changed, _) = reduce(.photosChanged(change), running(run, dirty: false))
    let (idle, _) = reduce(.exportRunStateChanged(.idle), changed)
    #expect(idle.current == .scheduled(reason: .photosChanged, fireAt: now.addingTimeInterval(30)))
    let (next, effects) = completed(summary(run, stoppedBy: .destinationNoSpace), idle)
    #expect(next.current == .idle)
    #expect(effects.contains(.cancelDebounce(.photosChanged)))
    #expect(next.pendingTriggerReason == nil)
    #expect(pendingAssets(next) == ["mid-run"])
  }

  // MARK: - A reason held while idle

  /// The state `midRunScopeChangeIsHeldForTheNextTrigger` reaches: idle after a stop, no
  /// dirty work, `.scopeSelectionChanged` held.
  private func heldAfterStop() -> AutoSyncReducer.State {
    let run = context()
    let (changed, _) = reduce(
      .scopeSelectionChanged(AutoExportScopeSelection(timeline: true, favorites: true)),
      running(run, dirty: false))
    let idle = reduce(.exportRunStateChanged(.idle), changed).0
    return completed(summary(run, stoppedBy: .destinationUnavailable), idle).0
  }

  enum QuietEvent: String, CaseIterable, Sendable {
    case dirtyStateLoaded, repeatedIdle, staleCompletion, retryTimerWithNothingDue
    case deleteOnlyPhotosChange
  }

  /// Events that are not triggers leave the held reason held and schedule nothing.
  @Test(arguments: QuietEvent.allCases)
  func quietEventsDoNotServeAHeldReason(event: QuietEvent) {
    let held = heldAfterStop()
    #expect(held.current == .idle && held.pendingTriggerReason == .scopeSelectionChanged)
    let input: AutoSyncEvent
    switch event {
    case .dirtyStateLoaded:
      input = .destinationDirtyStateLoaded(destinationId: destinationId, dirtyState: .empty)
    case .repeatedIdle:
      input = .exportRunStateChanged(.idle)
    case .staleCompletion:
      input = .autoSyncRunCompleted(
        summary(context(), stoppedBy: nil), destinationId: destinationId)
    case .retryTimerWithNothingDue:
      input = .retryTimerFired
    case .deleteOnlyPhotosChange:
      input = .photosChanged(
        PhotoLibraryPersistentChangeEvent(deletedLocalIdentifiers: ["gone"], observedAt: later))
    }
    let (next, effects) = reduce(input, held, at: later)
    #expect(next.current == .idle)
    #expect(schedules(effects).isEmpty)
    #expect(next.pendingTriggerReason == .scopeSelectionChanged)
  }

  enum Blocker: String, CaseIterable, Sendable { case manualExport, unsafeDestination }

  /// A blocker that comes and goes serves the held reason, or replaces it with its own.
  @Test(arguments: Blocker.allCases)
  func resolvingABlockerSchedulesTheHeldWork(blocker: Blocker) {
    let held = heldAfterStop()
    let blocked: AutoSyncReducer.State
    let resolved: (AutoSyncReducer.State, [AutoSyncEffect])
    let expected: AutoSyncReason
    switch blocker {
    case .manualExport:
      blocked =
        reduce(
          .exportRunStateChanged(
            ExportRunState(activeContext: nil, isManualActive: true, isAutoSyncActive: false)),
          held, at: later
        ).0
      #expect(blocked.current == .waiting(.manualExportActive))
      resolved = reduce(.exportRunStateChanged(.idle), blocked, at: later)
      expected = .scopeSelectionChanged
    case .unsafeDestination:
      blocked =
        reduce(
          .destinationChanged(destination(safety: .unsafeNeedsConfirmation)), held, at: later
        ).0
      #expect(blocked.current == .blocked(.destinationUnsafe))
      resolved = reduce(.destinationChanged(destination()), blocked, at: later)
      // A safety change is itself a destination trigger, which replaces the held reason.
      expected = .destinationSelected
    }
    let fireAt = later.addingTimeInterval(AutoSyncReducer.debounceDelay(for: expected))
    #expect(resolved.0.current == .scheduled(reason: expected, fireAt: fireAt))
    #expect(schedules(resolved.1) == [expected])
    #expect(resolved.0.pendingTriggerReason == nil)
  }

  /// A new trigger replaces the held reason and schedules for itself.
  @Test func newTriggerReplacesTheHeldReason() {
    let change = PhotoLibraryPersistentChangeEvent(
      insertedLocalIdentifiers: ["new"], observedAt: later)
    let (next, effects) = reduce(.photosChanged(change), heldAfterStop(), at: later)
    #expect(
      next.current == .scheduled(reason: .photosChanged, fireAt: later.addingTimeInterval(30)))
    #expect(schedules(effects) == [.photosChanged])
    #expect(next.pendingTriggerReason == nil)
  }

  /// Turning Auto Export off and on runs once for launch and leaves nothing held.
  @Test func disableThenEnableLeavesNoHeldReason() {
    let disabled = reduce(.enabledChanged(false), heldAfterStop(), at: later).0
    #expect(disabled.current == .disabled)
    let (enabled, effects) = reduce(.enabledChanged(true), disabled, at: later)
    #expect(enabled.current == .scheduled(reason: .appLaunch, fireAt: later.addingTimeInterval(10)))
    #expect(schedules(effects) == [.appLaunch])
    #expect(enabled.pendingTriggerReason == nil)
    let idle = reduce(.debounceFired(.appLaunch), enabled, at: later).0
    #expect(idle.pendingTriggerReason == nil)
  }

  // MARK: - Manual runs

  private func manualRun(_ dirty: Bool = true) -> (ExportRunContext, AutoSyncReducer.State) {
    let run = ExportRunContext(
      source: .manual, visibility: .userVisible, scope: .timelineFullLibrary,
      selection: .edited, startedAt: now)
    let state = reduce(
      .exportRunStateChanged(
        ExportRunState(activeContext: run, isManualActive: true, isAutoSyncActive: false)),
      idle(dirty: dirty)
    ).0
    return (run, state)
  }

  /// A manual export that stopped on a destination-wide failure does not leave an Auto
  /// Export run scheduled 30 seconds later to stop the same way.
  @Test(arguments: [false, true])
  func manualStopDoesNotScheduleAnAutoExportRun(summaryFirst: Bool) {
    let (run, active) = manualRun()
    #expect(active.current == .waiting(.manualExportActive))
    let stop = summary(run, stoppedBy: .destinationUnavailable)
    let next: AutoSyncReducer.State
    if summaryFirst {
      let first = reduce(.manualFullExportCompleted(stop), active)
      let second = reduce(.exportRunStateChanged(.idle), first.0)
      #expect(schedules(first.1 + second.1).isEmpty)
      next = second.0
    } else {
      let first = reduce(.exportRunStateChanged(.idle), active)
      #expect(
        first.0.current == .scheduled(reason: .photosChanged, fireAt: now.addingTimeInterval(30)))
      let second = reduce(.manualFullExportCompleted(stop), first.0)
      #expect(second.1.contains(.cancelDebounce(.photosChanged)))
      next = second.0
    }
    #expect(next.current == .idle)
    #expect(pendingAssets(next) == ["pending"])
  }

  /// Guard: a manual run that ends without a stop keeps the follow-up for pending work.
  @Test func manualRunWithoutAStopKeepsTheFollowUp() {
    let (run, active) = manualRun()
    let idle = reduce(.exportRunStateChanged(.idle), active).0
    let (next, effects) = reduce(.manualFullExportCompleted(summary(run, stoppedBy: nil)), idle)
    #expect(next.current == .scheduled(reason: .photosChanged, fireAt: now.addingTimeInterval(30)))
    #expect(!effects.contains(.cancelDebounce(.photosChanged)))
  }

  // MARK: - Export Now precedence

  enum RunKind: String, CaseIterable, Sendable { case autoExport, manualExport }

  /// The run in progress, its stop summary, and the event that delivers that summary.
  private func inProgress(
    _ kind: RunKind
  ) -> (state: AutoSyncReducer.State, completion: AutoSyncEvent) {
    switch kind {
    case .autoExport:
      let run = context()
      return (
        running(run),
        .autoSyncRunCompleted(
          summary(run, stoppedBy: .destinationUnavailable), destinationId: destinationId)
      )
    case .manualExport:
      let (run, state) = manualRun()
      return (state, .manualFullExportCompleted(summary(run, stoppedBy: .destinationUnavailable)))
    }
  }

  private func finish(
    _ state: AutoSyncReducer.State, with completion: AutoSyncEvent, summaryFirst: Bool
  ) -> AutoSyncReducer.State {
    if summaryFirst {
      return reduce(.exportRunStateChanged(.idle), reduce(completion, state).0).0
    }
    return reduce(completion, reduce(.exportRunStateChanged(.idle), state).0).0
  }

  /// A trigger after Export Now during a run that stops does not swallow Export Now.
  @Test(arguments: RunKind.allCases, [false, true])
  func exportNowFollowedByAnotherTriggerStillRunsAfterTheStop(kind: RunKind, summaryFirst: Bool) {
    let (active, completion) = inProgress(kind)
    let requested = reduce(.runNowRequested, active).0
    let changed = reduce(
      .scopeSelectionChanged(AutoExportScopeSelection(timeline: true, favorites: true)), requested
    ).0
    #expect(changed.pendingTriggerReason == .userExportNow)
    let next = finish(changed, with: completion, summaryFirst: summaryFirst)
    #expect(next.current == .scheduled(reason: .userExportNow, fireAt: now))
  }

  /// Without a pending Export Now, the latest trigger during the run is the one kept.
  @Test func latestTriggerDuringAStoppedRunIsKept() {
    let run = context()
    let scope = reduce(
      .scopeSelectionChanged(AutoExportScopeSelection(timeline: true, favorites: true)),
      running(run, dirty: false)
    ).0
    let version = reduce(.versionSelectionChanged(.editedWithOriginals), scope).0
    #expect(version.pendingTriggerReason == .versionSelectionChanged)
    let next = finish(
      version,
      with: .autoSyncRunCompleted(
        summary(run, stoppedBy: .destinationUnavailable), destinationId: destinationId),
      summaryFirst: false)
    #expect(next.current == .idle)
    #expect(next.pendingTriggerReason == .versionSelectionChanged)
  }

  /// Pin: outside a run a destination stop can end, a later trigger still replaces a
  /// pending Export Now. Here an import is running; it serves the replacement when it ends.
  @Test func laterTriggerReplacesExportNowWhileImporting() {
    var importing = idle(dirty: false)
    importing = reduce(.importStateChanged(isImporting: true), importing).0
    importing = reduce(.runNowRequested, importing).0
    #expect(importing.current == .waiting(.importActive))
    #expect(importing.pendingTriggerReason == .userExportNow)
    let changed = reduce(
      .scopeSelectionChanged(AutoExportScopeSelection(timeline: true, favorites: true)), importing
    ).0
    #expect(changed.pendingTriggerReason == .scopeSelectionChanged)
    let resumed = reduce(.importStateChanged(isImporting: false), changed).0
    #expect(
      resumed.current
        == .scheduled(reason: .scopeSelectionChanged, fireAt: now.addingTimeInterval(2)))
  }

  /// Export Now pressed for one destination does not carry over to the next: switching
  /// destinations during the run schedules the new destination's own debounce.
  @Test func destinationSwitchDropsAPendingExportNow() {
    let requested = reduce(.runNowRequested, running(context())).0
    #expect(requested.pendingTriggerReason == .userExportNow)
    let other = DestinationSnapshot(
      stableId: "stop-B", fingerprint: nil, isAvailable: true, safety: .safe)
    let switched = reduce(.destinationChanged(other), requested).0
    #expect(switched.pendingTriggerReason == .destinationSelected)
    let next = reduce(.exportRunStateChanged(.idle), switched).0
    #expect(
      next.current
        == .scheduled(
          reason: .destinationSelected,
          fireAt: now.addingTimeInterval(AutoSyncReducer.debounceDelay(for: .destinationSelected))))
  }
}
