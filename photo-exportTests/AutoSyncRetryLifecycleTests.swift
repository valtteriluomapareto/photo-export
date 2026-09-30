import Foundation
import Testing

@testable import Photo_Export

@MainActor
struct AutoSyncRetryLifecycleTests {
  private func destination(_ id: String = "retry-A") -> DestinationSnapshot {
    DestinationSnapshot(stableId: id, fingerprint: nil, isAvailable: true, safety: .safe)
  }

  private func retryState(
    at date: Date, category: AutoSyncFailureCategory = .iCloudTransient,
    scope: AutoSyncRetryScopeKey = .timeline, assetId: String = "asset",
    variant: ExportVariant = .original
  ) -> AutoSyncRetryState {
    var retry = AutoSyncRetryState.empty
    retry.recordFailure(
      scope: scope, assetId: assetId, variant: variant,
      category: category, errorSignature: "network", at: date,
      nextEligibleAt: category.nextEligibleAt(attemptCount: 1, from: date))
    return retry
  }

  private func attach(
    _ manager: AutoSyncManager, _ builder: FakeAutoSyncEnvironmentBuilder,
    destinationId: String = "retry-A",
    scopes: AutoExportScopeSelection = AutoExportScopeSelection(timeline: true)
  ) {
    builder.userDefaults.set(true, forKey: AutoSyncManager.enabledDefaultsKey)
    builder.destination.subject.send(destination(destinationId))
    builder.scopes.subject.send(scopes)
    manager.attach(to: builder.environment)
  }

  private func failureSummary(at date: Date, signature: String = "network") -> ExportRunSummary {
    let failure = ExportRunFailureDetail(
      assetId: "asset", placement: .timeline(year: 2026, month: 9),
      variant: .original, category: .iCloudTransient,
      errorSignature: signature, localizedDescription: "Temporary network error", failedAt: date)
    return ExportRunSummary(
      context: ExportRunContext(
        source: .autoSync, visibility: .background,
        scope: .timelineFullLibrary, selection: .edited),
      endedAt: date, enqueuedCount: 1, completedCount: 0,
      failedCount: 1, skippedCount: 0, cancelReason: nil,
      result: .failed, failures: [failure])
  }

  @Test(.timeLimit(.minutes(1)))
  func failedRunRetriesAtBackoffWithoutAnotherExternalEvent() async throws {
    let manager = AutoSyncManager()
    let builder = FakeAutoSyncEnvironmentBuilder()
    attach(manager, builder)
    builder.exportRunner.nextRunSummary = failureSummary(
      at: builder.clock.now().addingTimeInterval(10))

    builder.clock.advance(by: 10)
    let firstTask = try #require(manager.activeRunFanOutTask)
    await firstTask.value
    let first = try #require(
      builder.retryStore.load(destinationId: "retry-A").entry(
        scope: .timeline, assetId: "asset", variant: .original))
    #expect(first.attemptCount == 1)
    #expect(first.nextEligibleAt == builder.clock.now().addingTimeInterval(30))

    builder.clock.advance(by: 29)
    #expect(builder.exportRunner.receivedContexts.count == 1)
    builder.exportRunner.nextRunSummary = failureSummary(
      at: builder.clock.now().addingTimeInterval(1))
    builder.clock.advance(by: 1)
    #expect(builder.exportRunner.receivedContexts.count == 1)
    builder.clock.advance(by: 0)  // Run the zero-delay retry debounce.
    let secondTask = try #require(manager.activeRunFanOutTask)
    await secondTask.value
    #expect(builder.exportRunner.receivedContexts.count == 2)
    #expect(builder.exportRunner.receivedContexts[1].reason == .retryBackoff)
    let second = try #require(
      builder.retryStore.load(destinationId: "retry-A").entry(
        scope: .timeline, assetId: "asset", variant: .original))
    #expect(second.attemptCount == 2)
    #expect(second.nextEligibleAt == builder.clock.now().addingTimeInterval(120))
  }

  @Test(.timeLimit(.minutes(1)))
  func dueRetryWaitsForOwnedFanOutIncludingBetweenScopes() async throws {
    let manager = AutoSyncManager()
    let builder = FakeAutoSyncEnvironmentBuilder()
    let gate = AsyncCheckpoint()
    defer { Task { await gate.releaseAll() } }
    builder.exportRunner.gateForInvocation = { index in index == 2 ? gate : nil }
    let failureAt = builder.clock.now().addingTimeInterval(-18)
    try builder.retryStore.save(retryState(at: failureAt), destinationId: "retry-A")
    attach(manager, builder, scopes: AutoExportScopeSelection(timeline: true, favorites: true))

    builder.clock.advance(by: 10)
    await gate.waitForEnter(count: 1)
    let firstTask = try #require(manager.activeRunFanOutTask)
    #expect(
      builder.exportRunner.receivedContexts.map(\.scope) == [
        .timelineFullLibrary, .favoritesFull,
      ])
    // Simulate the idle publication between per-scope exports. Manager ownership,
    // not the runner's current-state mirror, must prevent an overlapping retry.
    builder.exportRunner.subject.send(.idle)
    builder.clock.advance(by: 2)  // Eligibility at t=12 while scope 2 is parked.
    #expect(builder.exportRunner.receivedContexts.count == 2)
    await gate.release()
    await firstTask.value
    builder.clock.advance(by: 0)
    let secondTask = try #require(manager.activeRunFanOutTask)
    await secondTask.value
    #expect(builder.exportRunner.receivedContexts.count == 4)
    #expect(builder.exportRunner.receivedContexts[2].reason == .retryBackoff)
    builder.clock.advance(by: 0)
    #expect(builder.exportRunner.receivedContexts.count == 4)
  }

  @Test(.timeLimit(.minutes(1)))
  func matchedCompletionPrunesOnlyVariantsThatAreDone() async throws {
    let manager = AutoSyncManager()
    let builder = FakeAutoSyncEnvironmentBuilder()
    let firstGate = AsyncCheckpoint()
    defer { Task { await firstGate.releaseAll() } }
    builder.exportRunner.gateForInvocation = { index in index == 1 ? firstGate : nil }
    let failedAt = builder.clock.now()
    var retry = retryState(at: failedAt)
    retry.recordFailure(
      scope: .timeline, assetId: "asset", variant: .edited,
      category: .iCloudTransient, errorSignature: "network", at: failedAt,
      nextEligibleAt: failedAt.addingTimeInterval(30))
    try builder.retryStore.save(retry, destinationId: "retry-A")
    attach(manager, builder)
    builder.clock.advance(by: 10)
    await firstGate.waitForEnter(count: 1)
    let task = try #require(manager.activeRunFanOutTask)
    builder.exportRunner.retryVariantDone = { _, _, variant in variant == .original }
    await firstGate.release()
    await task.value

    let remaining = builder.retryStore.load(destinationId: "retry-A")
    #expect(remaining.entry(scope: .timeline, assetId: "asset", variant: .original) == nil)
    #expect(remaining.entry(scope: .timeline, assetId: "asset", variant: .edited) != nil)
  }

  @Test(.timeLimit(.minutes(1)))
  func retryDueDuringManualRunWaitsUntilManualFinishes() async throws {
    let manager = AutoSyncManager()
    let builder = FakeAutoSyncEnvironmentBuilder()
    try builder.retryStore.save(retryState(at: builder.clock.now()), destinationId: "retry-A")
    attach(manager, builder)
    builder.clock.advance(by: 10)
    let launchTask = try #require(manager.activeRunFanOutTask)
    await launchTask.value

    let manual = ExportRunContext(
      source: .manual, visibility: .userVisible,
      scope: .timelineFullLibrary, selection: .edited)
    builder.exportRunner.subject.send(
      ExportRunState(
        activeContext: manual, isManualActive: true, isAutoSyncActive: false))
    builder.clock.advance(by: 20)
    #expect(builder.exportRunner.receivedContexts.count == 1)
    builder.exportRunner.subject.send(.idle)
    builder.clock.advance(by: 0)
    let retryTask = try #require(manager.activeRunFanOutTask)
    await retryTask.value
    #expect(builder.exportRunner.receivedContexts.last?.reason == .retryBackoff)
  }

  @Test(.timeLimit(.minutes(1)))
  func retryDueDuringImportWaitsUntilImportFinishes() async throws {
    let manager = AutoSyncManager()
    let builder = FakeAutoSyncEnvironmentBuilder()
    try builder.retryStore.save(retryState(at: builder.clock.now()), destinationId: "retry-A")
    attach(manager, builder)
    builder.clock.advance(by: 10)
    let launchTask = try #require(manager.activeRunFanOutTask)
    await launchTask.value

    builder.importing.subject.send(true)
    builder.clock.advance(by: 20)
    #expect(builder.exportRunner.receivedContexts.count == 1)
    builder.importing.subject.send(false)
    builder.clock.advance(by: 0)
    let retryTask = try #require(manager.activeRunFanOutTask)
    await retryTask.value
    #expect(builder.exportRunner.receivedContexts.last?.reason == .retryBackoff)
  }

  @Test func disabledAndUnknownScopeEntriesDoNotArmRetryTimer() throws {
    let manager = AutoSyncManager()
    let builder = FakeAutoSyncEnvironmentBuilder()
    var retry = retryState(at: builder.clock.now())
    let unknown = try #require(retry.entriesByPlacement["timeline"]?["asset"])
    retry.entriesByPlacement["future-scope"] = ["asset": unknown]
    retry.entriesByPlacement.removeValue(forKey: "timeline")
    try builder.retryStore.save(retry, destinationId: "retry-A")
    attach(manager, builder)
    #expect(builder.clock.pendingCount == 1)  // Only app-launch debounce.
    manager.setEnabled(false)
    #expect(builder.clock.pendingCount == 0)
    builder.clock.advance(by: 60)
    #expect(builder.exportRunner.receivedContexts.isEmpty)
  }

  @Test(.timeLimit(.minutes(1)))
  func hardFailureHasNoAutomaticRetryLoop() async throws {
    let manager = AutoSyncManager()
    let builder = FakeAutoSyncEnvironmentBuilder()
    try builder.retryStore.save(
      retryState(at: builder.clock.now(), category: .destinationPermission),
      destinationId: "retry-A")
    attach(manager, builder)
    #expect(builder.clock.pendingCount == 1)  // App-launch, no retry timer.
    builder.clock.advance(by: 10)
    let task = try #require(manager.activeRunFanOutTask)
    await task.value
    builder.clock.advance(by: 3600)
    #expect(builder.exportRunner.receivedContexts.count == 1)
    #expect(builder.clock.pendingCount == 0)
  }

  @Test(.timeLimit(.minutes(1)))
  func destinationSwitchBackToARearmsOnlyAsRetryTimer() async throws {
    let manager = AutoSyncManager()
    let builder = FakeAutoSyncEnvironmentBuilder()
    try builder.retryStore.save(retryState(at: builder.clock.now()), destinationId: "retry-A")
    attach(manager, builder)
    builder.destination.subject.send(destination("retry-B"))
    builder.destination.subject.send(destination("retry-A"))

    builder.clock.advance(by: 3)
    let selectedTask = try #require(manager.activeRunFanOutTask)
    await selectedTask.value
    #expect(builder.exportRunner.receivedContexts.count == 1)
    builder.clock.advance(by: 26)
    #expect(builder.exportRunner.receivedContexts.count == 1)
    builder.clock.advance(by: 1)
    builder.clock.advance(by: 0)
    let retryTask = try #require(manager.activeRunFanOutTask)
    await retryTask.value
    #expect(builder.exportRunner.receivedContexts.count == 2)
    #expect(builder.exportRunner.receivedContexts[1].reason == .retryBackoff)
  }

  @Test(.timeLimit(.minutes(1)))
  func changedFailureCategoryOrSignatureRestartsBackoffAtFirstAttempt() async throws {
    for changedPart in ["category", "signature"] {
      let manager = AutoSyncManager()
      let builder = FakeAutoSyncEnvironmentBuilder()
      var retry = AutoSyncRetryState.empty
      let priorCategory: AutoSyncFailureCategory =
        changedPart == "category" ? .photoKitTransient : .iCloudTransient
      let priorSignature = changedPart == "signature" ? "old-network" : "network"
      for _ in 0..<3 {
        retry.recordFailure(
          scope: .timeline, assetId: "asset", variant: .original,
          category: priorCategory, errorSignature: priorSignature,
          at: builder.clock.now(), nextEligibleAt: nil)
      }
      try builder.retryStore.save(retry, destinationId: "retry-A")
      attach(manager, builder)
      builder.exportRunner.nextRunSummary = failureSummary(
        at: builder.clock.now().addingTimeInterval(10))
      builder.clock.advance(by: 10)
      let task = try #require(manager.activeRunFanOutTask)
      await task.value

      let entry = try #require(
        builder.retryStore.load(destinationId: "retry-A").entry(
          scope: .timeline, assetId: "asset", variant: .original))
      #expect(entry.attemptCount == 1)
      #expect(entry.nextEligibleAt == builder.clock.now().addingTimeInterval(30))
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func pruningPreservesUnknownStoredScopeAndVariantEntries() async throws {
    let manager = AutoSyncManager()
    let builder = FakeAutoSyncEnvironmentBuilder()
    var retry = retryState(at: builder.clock.now())
    let known = try #require(
      retry.entry(
        scope: .timeline, assetId: "asset", variant: .original))
    retry.entriesByPlacement["future-scope"] = ["asset": ["original": known]]
    retry.entriesByPlacement["timeline"]?["asset"]?["future-variant"] = known
    try builder.retryStore.save(retry, destinationId: "retry-A")
    builder.exportRunner.retryVariantDone = { _, _, _ in true }
    attach(manager, builder)
    builder.clock.advance(by: 10)
    let task = try #require(manager.activeRunFanOutTask)
    await task.value

    let stored = builder.retryStore.load(destinationId: "retry-A")
    #expect(stored.entry(scope: .timeline, assetId: "asset", variant: .original) == nil)
    #expect(stored.entriesByPlacement["timeline"]?["asset"]?["future-variant"] == known)
    #expect(stored.entriesByPlacement["future-scope"]?["asset"]?["original"] == known)
    #expect(builder.clock.pendingCount == 0)
  }

  @Test func legacyRetryEntryWithoutDeadlineDecodesAndDoesNotSchedule() throws {
    let manager = AutoSyncManager()
    let builder = FakeAutoSyncEnvironmentBuilder()
    var retry = AutoSyncRetryState.empty
    retry.recordFailure(
      scope: .timeline, assetId: "legacy", variant: .original,
      category: .iCloudTransient, errorSignature: "legacy-network",
      at: builder.clock.now(), nextEligibleAt: nil)
    let legacyBytes = try JSONEncoder().encode(retry)
    #expect(!String(decoding: legacyBytes, as: UTF8.self).contains("nextEligibleAt"))
    let decoded = try JSONDecoder().decode(AutoSyncRetryState.self, from: legacyBytes)
    #expect(
      decoded.entry(scope: .timeline, assetId: "legacy", variant: .original)?
        .nextEligibleAt == nil)
    try builder.retryStore.save(decoded, destinationId: "retry-A")
    attach(manager, builder)
    #expect(builder.clock.pendingCount == 1)  // App-launch only.
  }

  @Test func earliestSelectedRetryDeadlineWinsAndConsumedEntryCannotLoop() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var state = AutoSyncReducer.State.initial
    state.enabled = true
    state.destination = destination()
    state.scopeSelection = AutoExportScopeSelection(timeline: true, favorites: true)
    state.current = .idle
    var retry = AutoSyncRetryState.empty
    retry.recordFailure(
      scope: .timeline, assetId: "early", variant: .original,
      category: .iCloudTransient, errorSignature: "early", at: now,
      nextEligibleAt: now.addingTimeInterval(30))
    retry.recordFailure(
      scope: .favorites, assetId: "late", variant: .original,
      category: .iCloudTransient, errorSignature: "late", at: now,
      nextEligibleAt: now.addingTimeInterval(120))
    let (armed, armEffects) = AutoSyncReducer.reduce(
      .retryStateChanged(destinationId: "retry-A", retryState: retry), in: state, now: now)
    #expect(armEffects == [.scheduleRetryTimer(fireAt: now.addingTimeInterval(30))])

    let fireAt = now.addingTimeInterval(30)
    let (fired, effects) = AutoSyncReducer.reduce(
      .retryTimerFired, in: armed, now: fireAt)
    #expect(effects.contains(.scheduleDebounce(.retryBackoff, fireAt: fireAt)))
    #expect(effects.contains(.scheduleRetryTimer(fireAt: now.addingTimeInterval(120))))
    let (_, unchangedEffects) = AutoSyncReducer.reduce(
      .retryStateChanged(destinationId: "retry-A", retryState: retry), in: fired, now: fireAt)
    #expect(unchangedEffects.isEmpty)
  }

  @Test func legacyManualIdleTransitionRequestsCurrentDestinationPruning() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var state = AutoSyncReducer.State.initial
    state.enabled = true
    state.destination = destination("retry-B")
    state.scopeSelection = AutoExportScopeSelection(timeline: true)
    state.current = .waiting(.manualExportActive)
    state.exportRunState = ExportRunState(
      activeContext: nil, isManualActive: true, isAutoSyncActive: false)

    let (_, effects) = AutoSyncReducer.reduce(
      .exportRunStateChanged(.idle), in: state, now: now)
    #expect(effects.contains(.pruneDoneRetryEntries(destinationId: "retry-B")))
  }

  @Test(.timeLimit(.minutes(1)))
  func staleACompletionAfterSwitchNeverQueriesBRecordsForPruning() async throws {
    let manager = AutoSyncManager()
    let builder = FakeAutoSyncEnvironmentBuilder()
    let oldGate = AsyncCheckpoint()
    defer { Task { await oldGate.releaseAll() } }
    builder.exportRunner.gateForInvocation = { index in index == 1 ? oldGate : nil }
    let bRetry = retryState(at: builder.clock.now())
    try builder.retryStore.save(bRetry, destinationId: "retry-B")
    var queryCount = 0
    builder.exportRunner.retryVariantDone = { _, _, _ in
      queryCount += 1
      return true
    }
    attach(manager, builder)
    builder.clock.advance(by: 10)
    await oldGate.waitForEnter(count: 1)
    let oldTask = try #require(manager.activeRunFanOutTask)

    builder.destination.subject.send(destination("retry-B"))
    await oldGate.release()
    await oldTask.value
    #expect(queryCount == 0)
    #expect(builder.retryStore.load(destinationId: "retry-B") == bRetry)
    #expect(manager.currentRetryState == bRetry)
  }
  @Test(.timeLimit(.minutes(1)))
  func rapidReenableWaitsForOldRunnerThenStartsDueRetry() async throws {
    let manager = AutoSyncManager()
    let builder = FakeAutoSyncEnvironmentBuilder()
    let gate = AsyncCheckpoint()
    defer { Task { await gate.releaseAll() } }
    builder.exportRunner.gateForInvocation = { index in index == 1 ? gate : nil }
    try builder.retryStore.save(retryState(at: builder.clock.now()), destinationId: "retry-A")
    attach(manager, builder)
    builder.clock.advance(by: 10)
    await gate.waitForEnter(count: 1)
    let oldTask = try #require(manager.activeRunFanOutTask)
    let context = try #require(builder.exportRunner.receivedContexts.first)
    builder.exportRunner.subject.send(
      ExportRunState(
        activeContext: context, isManualActive: false, isAutoSyncActive: true))
    manager.setEnabled(false)
    manager.setEnabled(true)
    builder.clock.advance(by: 20)
    builder.clock.advance(by: 0)
    #expect(manager.activeRunFanOutTask == nil)
    #expect(builder.exportRunner.receivedContexts.count == 1)
    await gate.releaseAll()
    await oldTask.value
    builder.exportRunner.subject.send(.idle)
    builder.clock.advance(by: 0)
    let retryTask = try #require(manager.activeRunFanOutTask)
    await retryTask.value
    #expect(builder.exportRunner.receivedContexts.count == 2)
    #expect(builder.exportRunner.receivedContexts.last?.reason == .retryBackoff)
  }

}
