import Foundation
import Testing

@testable import Photo_Export

/// Manager-level acknowledgement and recovery checks. Assertions observe the
/// saved stores, not the manager's transient persistence bookkeeping.
@MainActor
struct AutoSyncDirtyPersistenceAcknowledgementTests {

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
    _ builder: FakeAutoSyncEnvironmentBuilder, ids: Set<String> = []
  ) {
    builder.photos.push(
      PhotoLibraryPersistentChangeEvent(
        insertedLocalIdentifiers: ids,
        deletedLocalIdentifiers: ids.isEmpty ? ["deleted"] : [],
        observedAt: builder.clock.now()))
  }

  private func completeAutoSyncRun(
    _ manager: AutoSyncManager, _ builder: FakeAutoSyncEnvironmentBuilder,
    beforeCompletion: () -> Void = {}
  ) {
    let context = ExportRunContext(
      source: .autoSync, visibility: .background, scope: .timelineFullLibrary, selection: .edited,
      startedAt: builder.clock.now())
    manager.dispatch(.exportRunStarted(context, destinationId: "ack-A"))
    builder.exportRunner.subject.send(
      ExportRunState(activeContext: context, isManualActive: false, isAutoSyncActive: true))
    builder.exportRunner.subject.send(.idle)
    beforeCompletion()
    manager.dispatch(
      .autoSyncRunCompleted(
        ExportRunSummary(
          context: context, endedAt: builder.clock.now(), enqueuedCount: 1, completedCount: 1,
          failedCount: 0, skippedCount: 0, cancelReason: nil, result: .completed),
        destinationId: "ack-A"))
  }

  @Test(arguments: [1, 2])
  func failedDirtySaveRetainsAccumulatedWorkUntilRecovery(failedSaveCount: Int) throws {
    let builder = FakeAutoSyncEnvironmentBuilder()
    let manager = attach(builder)
    defer { manager.setEnabled(false) }
    var pendingIds: Set<String> = []
    for attempt in 1...failedSaveCount {
      let assetId = "failed-\(attempt)"
      pendingIds.insert(assetId)
      builder.dirtyStore.nextSaveError = InMemoryAutoSyncStoreError("disk-full")
      change(builder, ids: [assetId])
      #expect(builder.dirtyStore.load(destinationId: "ack-A").isEmpty)
    }
    pendingIds.insert("recovered")
    change(builder, ids: ["recovered"])
    #expect(
      builder.dirtyStore.load(destinationId: "ack-A").scope(.timeline).pendingAssetIds == pendingIds
    )
  }

  @Test(arguments: [false, true])
  func noWorkEventsCannotDiscardAnEarlierFailedSave(fullReconciliation: Bool) throws {
    let builder = FakeAutoSyncEnvironmentBuilder()
    let manager = attach(builder)
    defer { manager.setEnabled(false) }
    builder.dirtyStore.nextSaveError = InMemoryAutoSyncStoreError("disk-full")
    if fullReconciliation {
      builder.photos.pushError(.detailsUnavailable)
    } else {
      change(builder, ids: ["unsaved"])
    }

    change(builder)

    #expect(builder.dirtyStore.load(destinationId: "ack-A").isEmpty)
    #expect(builder.exportRunner.receivedContexts.isEmpty)

    change(builder, ids: ["later"])

    let saved = builder.dirtyStore.load(destinationId: "ack-A").scope(.timeline)
    if fullReconciliation {
      #expect(saved.pendingFullReconciliation)
    } else {
      #expect(saved.pendingAssetIds == ["unsaved", "later"])
    }
  }

  @Test func anotherDestinationCannotReleaseFailedDestinationsGateOrDiscardItsWork() throws {
    let builder = FakeAutoSyncEnvironmentBuilder()
    let manager = attach(builder)
    defer { manager.setEnabled(false) }
    builder.dirtyStore.nextSaveError = InMemoryAutoSyncStoreError("disk-full")
    change(builder, ids: ["unsaved-A"])

    builder.destination.subject.send(destination("ack-B"))
    change(builder, ids: ["saved-B"])
    #expect(
      builder.dirtyStore.load(destinationId: "ack-B").scope(.timeline).pendingAssetIds == [
        "saved-B"
      ])

    builder.destination.subject.send(destination())
    change(builder)
    #expect(builder.dirtyStore.load(destinationId: "ack-A").isEmpty)
    change(builder, ids: ["later-A"])

    #expect(
      builder.dirtyStore.load(destinationId: "ack-A").scope(.timeline).pendingAssetIds == [
        "unsaved-A", "later-A",
      ])
    #expect(
      builder.dirtyStore.load(destinationId: "ack-B").scope(.timeline).pendingAssetIds == [
        "saved-B"
      ])
  }

  @Test func failedEmptyCleanupDoesNotReloadAlreadyAcknowledgedWork() throws {
    let builder = FakeAutoSyncEnvironmentBuilder()
    let manager = attach(builder)
    defer { manager.setEnabled(false) }
    change(builder, ids: ["exported"])
    completeAutoSyncRun(manager, builder) {
      builder.dirtyStore.nextSaveError = InMemoryAutoSyncStoreError("disk-full")
    }
    #expect(
      builder.dirtyStore.load(destinationId: "ack-A").scope(.timeline).pendingAssetIds == [
        "exported"
      ])

    builder.destination.subject.send(destination("ack-B"))
    builder.destination.subject.send(destination())
    change(builder)
    change(builder, ids: ["new"])

    #expect(
      builder.dirtyStore.load(destinationId: "ack-A").scope(.timeline).pendingAssetIds == ["new"])
  }

  @Test func successfulCompletionCanRecoverBySavingEmptyDirtyState() {
    let builder = FakeAutoSyncEnvironmentBuilder()
    let manager = attach(builder)
    defer { manager.setEnabled(false) }
    builder.dirtyStore.nextSaveError = InMemoryAutoSyncStoreError("disk-full")
    change(builder, ids: ["exported"])

    completeAutoSyncRun(manager, builder)
    change(builder)

    #expect(builder.dirtyStore.savedDestinationIds.contains("ack-A"))
    #expect(builder.dirtyStore.load(destinationId: "ack-A").isEmpty)
  }

  @Test func healthyNoWorkEventDoesNotWriteDirtyStateOrScheduleNewWork() {
    let builder = FakeAutoSyncEnvironmentBuilder()
    let manager = attach(builder)
    defer { manager.setEnabled(false) }
    let stateBefore = manager.state

    change(builder)

    #expect(builder.dirtyStore.savedDestinationIds.isEmpty)
    #expect(manager.state == stateBefore)
    #expect(builder.exportRunner.receivedContexts.isEmpty)
  }

  @Test(arguments: [false, true])
  func restartLoadsOnlySavedWorkAndStillRunsFullStartupReconciliation(recoverBeforeRestart: Bool)
    async throws
  {
    let builder = FakeAutoSyncEnvironmentBuilder()
    let original = attach(builder)
    builder.dirtyStore.nextSaveError = InMemoryAutoSyncStoreError("disk-full")
    change(builder, ids: ["unsaved"])
    if recoverBeforeRestart {
      change(builder, ids: ["recovered"])
    }
    original.setEnabled(false)

    let restarted = attach(builder)
    defer { restarted.setEnabled(false) }
    let saved = builder.dirtyStore.load(destinationId: "ack-A")
    #expect(saved.isEmpty == !recoverBeforeRestart)

    builder.clock.advance(by: 10)
    let startup = try #require(restarted.activeRunFanOutTask)
    await startup.value

    #expect(builder.exportRunner.receivedContexts.count == 1)
    #expect(builder.exportRunner.receivedContexts.first?.scope == .timelineFullLibrary)
    #expect(builder.exportRunner.receivedContexts.first?.reason == .appLaunch)
    // Neither the failure latch nor unsaved identifiers are crash-durable.
    // Startup reconciles the full scope rather than replaying unsaved identifiers.
  }
}
