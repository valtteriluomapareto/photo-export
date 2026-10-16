import Foundation
import Testing

@testable import Photo_Export

/// Manager-level acknowledgement and recovery checks. Assertions observe the
/// saved stores, not the manager's transient persistence bookkeeping.
@MainActor
struct AutoSyncDirtyPersistenceAcknowledgementTests {
  private let firstToken = Data([0x01])
  private let secondToken = Data([0x02])
  private let thirdToken = Data([0x03])

  private func destination(_ id: String = "ack-A") -> DestinationSnapshot {
    DestinationSnapshot(stableId: id, fingerprint: nil, isAvailable: true, safety: .safe)
  }

  private func attach(_ builder: FakeAutoSyncEnvironmentBuilder) -> AutoSyncManager {
    builder.userDefaults.set(true, forKey: AutoSyncManager.enabledDefaultsKey)
    builder.destination.subject.send(destination())
    builder.scopes.subject.send(AutoExportScopeSelection(timeline: true))
    let manager = AutoSyncManager()
    manager.attach(to: builder.environment)
    return manager
  }

  private func change(
    _ builder: FakeAutoSyncEnvironmentBuilder, ids: Set<String> = [], token: Data
  ) {
    builder.photos.push(
      PhotoLibraryPersistentChangeEvent(
        insertedLocalIdentifiers: ids,
        deletedLocalIdentifiers: ids.isEmpty ? ["deleted"] : [],
        observedAt: builder.clock.now(), nextToken: token))
  }

  private func completeManualRun(
    _ builder: FakeAutoSyncEnvironmentBuilder, beforeCompletion: () -> Void = {}
  ) {
    let context = ExportRunContext(
      source: .manual, visibility: .userVisible, scope: .timelineFullLibrary, selection: .edited,
      startedAt: builder.clock.now())
    builder.exportRunner.subject.send(
      ExportRunState(activeContext: context, isManualActive: true, isAutoSyncActive: false))
    builder.exportRunner.subject.send(.idle)
    beforeCompletion()
    builder.exportRunner.completedRunsSubject.send(
      ExportRunSummary(
        context: context, endedAt: builder.clock.now(), enqueuedCount: 1, completedCount: 1,
        failedCount: 0, skippedCount: 0, cancelReason: nil, result: .completed))
  }

  @Test(arguments: [1, 2])
  func failedDirtySaveKeepsPriorTokenUntilAccumulatedWorkSaves(failedSaveCount: Int) throws {
    let builder = FakeAutoSyncEnvironmentBuilder()
    let manager = attach(builder)
    defer { manager.setEnabled(false) }
    try builder.perDestinationTokenStore.save(firstToken, destinationId: "ack-A")
    var pendingIds: Set<String> = []
    for attempt in 1...failedSaveCount {
      let assetId = "failed-\(attempt)"
      pendingIds.insert(assetId)
      builder.dirtyStore.nextSaveError = InMemoryAutoSyncStoreError("disk-full")
      change(builder, ids: [assetId], token: secondToken)
      #expect(builder.dirtyStore.load(destinationId: "ack-A").isEmpty)
      #expect(builder.perDestinationTokenStore.load(destinationId: "ack-A") == firstToken)
    }
    pendingIds.insert("recovered")
    change(builder, ids: ["recovered"], token: thirdToken)
    #expect(
      builder.dirtyStore.load(destinationId: "ack-A").scope(.timeline).pendingAssetIds == pendingIds
    )
    #expect(builder.perDestinationTokenStore.load(destinationId: "ack-A") == thirdToken)
  }

  @Test(arguments: [false, true])
  func tokenOnlyEventsCannotBypassAnEarlierFailedSave(fullReconciliation: Bool) throws {
    let builder = FakeAutoSyncEnvironmentBuilder()
    let manager = attach(builder)
    defer { manager.setEnabled(false) }
    try builder.perDestinationTokenStore.save(firstToken, destinationId: "ack-A")
    builder.dirtyStore.nextSaveError = InMemoryAutoSyncStoreError("disk-full")
    if fullReconciliation {
      builder.photos.pushError(.detailsUnavailable)
    } else {
      change(builder, ids: ["unsaved"], token: secondToken)
    }

    change(builder, token: thirdToken)

    #expect(builder.dirtyStore.load(destinationId: "ack-A").isEmpty)
    #expect(builder.perDestinationTokenStore.load(destinationId: "ack-A") == firstToken)
    #expect(builder.exportRunner.receivedContexts.isEmpty)

    change(builder, ids: ["later"], token: thirdToken)

    let saved = builder.dirtyStore.load(destinationId: "ack-A").scope(.timeline)
    if fullReconciliation {
      #expect(saved.pendingFullReconciliation)
    } else {
      #expect(saved.pendingAssetIds == ["unsaved", "later"])
    }
    #expect(builder.perDestinationTokenStore.load(destinationId: "ack-A") == thirdToken)
  }

  @Test func anotherDestinationCannotReleaseFailedDestinationsGateOrDiscardItsWork() throws {
    let builder = FakeAutoSyncEnvironmentBuilder()
    let manager = attach(builder)
    defer { manager.setEnabled(false) }
    try builder.perDestinationTokenStore.save(firstToken, destinationId: "ack-A")
    builder.dirtyStore.nextSaveError = InMemoryAutoSyncStoreError("disk-full")
    change(builder, ids: ["unsaved-A"], token: secondToken)

    builder.destination.subject.send(destination("ack-B"))
    change(builder, ids: ["saved-B"], token: secondToken)
    #expect(
      builder.dirtyStore.load(destinationId: "ack-B").scope(.timeline).pendingAssetIds == [
        "saved-B"
      ])
    #expect(builder.perDestinationTokenStore.load(destinationId: "ack-B") == secondToken)

    builder.destination.subject.send(destination())
    change(builder, token: thirdToken)
    #expect(builder.perDestinationTokenStore.load(destinationId: "ack-A") == firstToken)
    change(builder, ids: ["later-A"], token: thirdToken)

    #expect(
      builder.dirtyStore.load(destinationId: "ack-A").scope(.timeline).pendingAssetIds == [
        "unsaved-A", "later-A",
      ])
    #expect(builder.perDestinationTokenStore.load(destinationId: "ack-A") == thirdToken)
    #expect(
      builder.dirtyStore.load(destinationId: "ack-B").scope(.timeline).pendingAssetIds == [
        "saved-B"
      ])
  }

  @Test func failedEmptyCleanupDoesNotReloadAlreadyAcknowledgedWork() throws {
    let builder = FakeAutoSyncEnvironmentBuilder()
    let manager = attach(builder)
    defer { manager.setEnabled(false) }
    change(builder, ids: ["exported"], token: firstToken)
    completeManualRun(builder) {
      builder.dirtyStore.nextSaveError = InMemoryAutoSyncStoreError("disk-full")
    }
    #expect(
      builder.dirtyStore.load(destinationId: "ack-A").scope(.timeline).pendingAssetIds == [
        "exported"
      ])

    builder.destination.subject.send(destination("ack-B"))
    builder.destination.subject.send(destination())
    change(builder, token: secondToken)
    #expect(builder.perDestinationTokenStore.load(destinationId: "ack-A") == firstToken)
    change(builder, ids: ["new"], token: thirdToken)

    #expect(
      builder.dirtyStore.load(destinationId: "ack-A").scope(.timeline).pendingAssetIds == ["new"])
    #expect(builder.perDestinationTokenStore.load(destinationId: "ack-A") == thirdToken)
  }

  @Test func successfulCompletionCanRecoverBySavingEmptyDirtyState() {
    let builder = FakeAutoSyncEnvironmentBuilder()
    let manager = attach(builder)
    defer { manager.setEnabled(false) }
    builder.dirtyStore.nextSaveError = InMemoryAutoSyncStoreError("disk-full")
    change(builder, ids: ["exported"], token: firstToken)

    completeManualRun(builder)
    change(builder, token: secondToken)

    #expect(builder.dirtyStore.savedDestinationIds.contains("ack-A"))
    #expect(builder.dirtyStore.load(destinationId: "ack-A").isEmpty)
    #expect(builder.perDestinationTokenStore.load(destinationId: "ack-A") == secondToken)
  }

  @Test func healthyTokenOnlyEventDoesNotWriteDirtyStateOrScheduleNewWork() {
    let builder = FakeAutoSyncEnvironmentBuilder()
    let manager = attach(builder)
    defer { manager.setEnabled(false) }
    let stateBefore = manager.state

    change(builder, token: firstToken)

    #expect(builder.dirtyStore.savedDestinationIds.isEmpty)
    #expect(builder.perDestinationTokenStore.load(destinationId: "ack-A") == firstToken)
    #expect(manager.state == stateBefore)
    #expect(builder.exportRunner.receivedContexts.isEmpty)
  }

  @Test func failedTokenWriteDoesNotPreventLaterAcknowledgement() {
    let builder = FakeAutoSyncEnvironmentBuilder()
    let manager = attach(builder)
    defer { manager.setEnabled(false) }
    builder.perDestinationTokenStore.nextSaveError = InMemoryAutoSyncStoreError("disk-full")

    change(builder, ids: ["saved"], token: firstToken)
    #expect(builder.perDestinationTokenStore.load(destinationId: "ack-A") == nil)
    #expect(
      builder.dirtyStore.load(destinationId: "ack-A").scope(.timeline).pendingAssetIds == ["saved"])

    change(builder, token: secondToken)
    #expect(builder.perDestinationTokenStore.load(destinationId: "ack-A") == secondToken)
  }

  @Test(arguments: [false, true])
  func restartLoadsOnlySavedWorkAndStillRunsFullStartupReconciliation(recoverBeforeRestart: Bool)
    async throws
  {
    let builder = FakeAutoSyncEnvironmentBuilder()
    let original = attach(builder)
    try builder.perDestinationTokenStore.save(firstToken, destinationId: "ack-A")
    builder.dirtyStore.nextSaveError = InMemoryAutoSyncStoreError("disk-full")
    change(builder, ids: ["unsaved"], token: secondToken)
    if recoverBeforeRestart {
      change(builder, ids: ["recovered"], token: thirdToken)
    }
    original.setEnabled(false)

    let restarted = attach(builder)
    defer { restarted.setEnabled(false) }
    let saved = builder.dirtyStore.load(destinationId: "ack-A")
    #expect(saved.isEmpty == !recoverBeforeRestart)
    #expect(
      builder.perDestinationTokenStore.load(destinationId: "ack-A")
        == (recoverBeforeRestart ? thirdToken : firstToken))

    builder.clock.advance(by: 10)
    let startup = try #require(restarted.activeRunFanOutTask)
    await startup.value

    #expect(builder.exportRunner.receivedContexts.count == 1)
    #expect(builder.exportRunner.receivedContexts.first?.scope == .timelineFullLibrary)
    #expect(builder.exportRunner.receivedContexts.first?.reason == .appLaunch)
    // Neither the failure latch nor unsaved identifiers are crash-durable.
    // Startup reconciles the full scope rather than replaying the advisory token.
  }
}
