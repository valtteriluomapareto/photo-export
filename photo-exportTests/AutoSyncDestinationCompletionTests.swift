import Foundation
import Testing

@testable import Photo_Export

@MainActor
struct AutoSyncDestinationCompletionTests {
  private func destination(_ id: String) -> DestinationSnapshot {
    DestinationSnapshot(
      stableId: id,
      fingerprint: .makeHigh(
        volumeUUIDString: "volume-\(id)", volumeRootPath: nil,
        relativePathFromVolumeRoot: "/backup", standardizedPath: "/Volumes/\(id)/backup"),
      isAvailable: true, safety: .safe)
  }

  private func failedSummary(
    at date: Date, assetId: String = "old-asset"
  ) -> ExportRunSummary {
    let failure = ExportRunFailureDetail(
      assetId: assetId,
      placement: .timeline(year: 2026, month: 9),
      variant: .original,
      category: .iCloudTransient,
      errorSignature: "old-destination-failure",
      localizedDescription: "Old destination failed",
      failedAt: date)
    return ExportRunSummary(
      context: ExportRunContext(
        source: .autoSync, visibility: .background,
        scope: .timelineFullLibrary, selection: .edited),
      endedAt: date,
      enqueuedCount: 1, completedCount: 0, failedCount: 1, skippedCount: 0,
      cancelReason: nil, result: .failed, failures: [failure])
  }

  @Test(.timeLimit(.minutes(1)))
  func switchingToBDiscardsALateFailureWithoutTouchingB() async throws {
    let manager = AutoSyncManager()
    let builder = FakeAutoSyncEnvironmentBuilder()
    let oldGate = AsyncCheckpoint()
    defer { Task { await oldGate.releaseAll() } }
    builder.exportRunner.gateForInvocation = { index in index == 1 ? oldGate : nil }
    builder.userDefaults.set(true, forKey: AutoSyncManager.enabledDefaultsKey)
    builder.destination.subject.send(destination("A"))
    builder.scopes.subject.send(AutoExportScopeSelection(timeline: true, favorites: true))
    manager.attach(to: builder.environment)

    builder.clock.advance(by: 10)
    await oldGate.waitForEnter(count: 1)
    let oldTask = try #require(manager.activeRunFanOutTask)
    #expect(builder.currentRunStore.load(destinationId: "A") != nil)

    builder.destination.subject.send(destination("B"))
    #expect(builder.currentRunStore.load(destinationId: "A") == nil)
    builder.exportRunner.nextRunSummary = failedSummary(at: builder.clock.now())
    await oldGate.release()
    await oldTask.value

    #expect(builder.exportRunner.receivedContexts.count == 1)
    #expect(builder.runSummaryStore.load(destinationId: "A") == nil)
    #expect(builder.runSummaryStore.load(destinationId: "B") == nil)
    #expect(builder.retryStore.load(destinationId: "B").isEmpty)
    #expect(builder.dirtyStore.load(destinationId: "B").isEmpty)
    #expect(manager.lastRunSummary == nil)
    #expect(manager.currentRetryState.isEmpty)
  }

  @Test(.timeLimit(.minutes(1)))
  func clearingDestinationCancelsOldFanOutAndDropsLateCompletion() async throws {
    let manager = AutoSyncManager()
    let builder = FakeAutoSyncEnvironmentBuilder()
    let oldGate = AsyncCheckpoint()
    defer { Task { await oldGate.releaseAll() } }
    builder.exportRunner.gateForInvocation = { _ in oldGate }
    builder.userDefaults.set(true, forKey: AutoSyncManager.enabledDefaultsKey)
    builder.destination.subject.send(destination("A"))
    builder.scopes.subject.send(AutoExportScopeSelection(timeline: true, favorites: true))
    manager.attach(to: builder.environment)

    builder.clock.advance(by: 10)
    await oldGate.waitForEnter(count: 1)
    let oldTask = try #require(manager.activeRunFanOutTask)
    builder.destination.subject.send(.none)
    builder.exportRunner.nextRunSummary = failedSummary(at: builder.clock.now())
    await oldGate.release()
    await oldTask.value

    #expect(builder.currentRunStore.load(destinationId: "A") == nil)
    #expect(builder.runSummaryStore.load(destinationId: "A") == nil)
    #expect(builder.exportRunner.receivedContexts.count == 1)
    #expect(manager.lastRunSummary == nil)
    #expect(manager.currentRetryState.isEmpty)
  }

  @Test(.timeLimit(.minutes(1)))
  func lateATaskCannotClearNewAJournalOrTaskAfterAtoBtoA() async throws {
    let manager = AutoSyncManager()
    let builder = FakeAutoSyncEnvironmentBuilder()
    let oldGate = AsyncCheckpoint()
    let newGate = AsyncCheckpoint()
    defer {
      Task {
        await oldGate.releaseAll()
        await newGate.releaseAll()
      }
    }
    builder.exportRunner.gateForInvocation = { index in
      index == 1 ? oldGate : newGate
    }
    builder.userDefaults.set(true, forKey: AutoSyncManager.enabledDefaultsKey)
    builder.destination.subject.send(destination("A"))
    builder.scopes.subject.send(AutoExportScopeSelection(timeline: true))
    manager.attach(to: builder.environment)

    builder.clock.advance(by: 10)
    await oldGate.waitForEnter(count: 1)
    let oldTask = try #require(manager.activeRunFanOutTask)
    builder.destination.subject.send(destination("B"))
    builder.destination.subject.send(destination("A"))
    builder.clock.advance(by: 3)
    await newGate.waitForEnter(count: 1)
    let newTask = try #require(manager.activeRunFanOutTask)
    let newJournal = try #require(builder.currentRunStore.load(destinationId: "A"))

    // The cancelled A runner ignores cancellation and returns after the newer A
    // fan-out has started. Its defer must not erase the new journal or task slot.
    await oldGate.release()
    await oldTask.value
    #expect(builder.currentRunStore.load(destinationId: "A") == newJournal)
    #expect(manager.activeRunFanOutTask != nil)

    await newGate.release()
    await newTask.value
    #expect(builder.currentRunStore.load(destinationId: "A") == nil)
    #expect(manager.activeRunFanOutTask == nil)
  }

  @Test func reducerRejectsOldCompletionAndPublisherAfterAtoBtoA() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var state = AutoSyncReducer.State.initial
    state.enabled = true
    state.destination = destination("A")
    state.scopeSelection = AutoExportScopeSelection(timeline: true)
    state.current = .running(reason: .appLaunch)
    let oldContext = ExportRunContext(
      source: .autoSync, visibility: .background,
      reason: .appLaunch, scope: .timelineFullLibrary, selection: .edited)
    state =
      AutoSyncReducer.reduce(
        .exportRunStarted(oldContext, destinationId: "A"), in: state, now: now
      ).0
    state =
      AutoSyncReducer.reduce(
        .destinationChanged(destination("B")), in: state, now: now
      ).0
    #expect(state.runDirtyBoundary == nil)
    state =
      AutoSyncReducer.reduce(
        .exportRunStateChanged(
          ExportRunState(
            activeContext: oldContext, isManualActive: false, isAutoSyncActive: true)),
        in: state, now: now
      ).0
    #expect(state.runDirtyBoundary == nil)
    #expect(state.exportRunState == .idle)
    state =
      AutoSyncReducer.reduce(
        .destinationChanged(destination("A")), in: state, now: now
      ).0
    state =
      AutoSyncReducer.reduce(
        .exportRunStarted(oldContext, destinationId: "A"), in: state, now: now
      ).0
    #expect(state.runDirtyBoundary == nil)

    let oldSummary = ExportRunSummary(
      context: oldContext, endedAt: now,
      enqueuedCount: 1, completedCount: 1, failedCount: 0, skippedCount: 0,
      cancelReason: nil, result: .completed)
    let (next, effects) = AutoSyncReducer.reduce(
      .autoSyncRunCompleted(oldSummary, destinationId: "A"), in: state, now: now)
    #expect(next == state)
    #expect(effects.isEmpty)

    let (_, debounceEffects) = AutoSyncReducer.reduce(
      .debounceFired(.destinationSelected), in: next, now: now.addingTimeInterval(10))
    #expect(
      debounceEffects.contains { effect in
        if case .startRun = effect { return true }
        return false
      })
  }

  @Test func manualRunFromPriorDestinationCannotRebindAfterSwitch() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var state = AutoSyncReducer.State.initial
    state.enabled = true
    state.destination = destination("A")
    state.scopeSelection = AutoExportScopeSelection(timeline: true)
    let oldContext = ExportRunContext(
      source: .manual, visibility: .userVisible,
      scope: .timelineFullLibrary, selection: .edited)
    let active = ExportRunState(
      activeContext: oldContext, isManualActive: true, isAutoSyncActive: false)
    state = AutoSyncReducer.reduce(.exportRunStateChanged(active), in: state, now: now).0
    #expect(state.runDirtyBoundary?.destinationId == "A")
    state =
      AutoSyncReducer.reduce(
        .destinationChanged(destination("B")), in: state, now: now
      ).0
    state =
      AutoSyncReducer.reduce(
        .destinationChanged(destination("A")), in: state, now: now
      ).0
    state = AutoSyncReducer.reduce(.exportRunStateChanged(active), in: state, now: now).0
    #expect(state.runDirtyBoundary == nil)
  }
}
