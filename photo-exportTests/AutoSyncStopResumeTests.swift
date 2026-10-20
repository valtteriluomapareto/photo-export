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

  private func destination() -> DestinationSnapshot {
    DestinationSnapshot(stableId: "stop-A", fingerprint: nil, isAvailable: true, safety: .safe)
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
    state.current = .running(reason: context.reason ?? .photosChanged)
    state = reduce(.exportRunStarted(context, destinationId: destinationId), state).0
    return reduce(
      .exportRunStateChanged(
        ExportRunState(activeContext: context, isManualActive: false, isAutoSyncActive: true)),
      state
    ).0
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

  /// The runner can resolve its awaiter after the run state is already idle in the
  /// reducer's view, so the summary itself ends the run. That transition is suppressed too.
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
}
