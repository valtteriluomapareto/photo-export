import AppKit
import Combine
import Foundation
import Testing

@testable import Photo_Export

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct AutoSyncReadOnlyDestinationTests {
  private final class Probe: DestinationValidationProbing {
    let status = LockedBox<ExportDestinationStatus>(.readOnly)
    let heldFolder = LockedBox<URL?>(nil)
    let onWorker = LockedBox<[Bool]>([])
    let entered = AsyncCheckpoint()
    private let gate = DispatchSemaphore(value: 0)

    func inspect(_ url: URL) -> DestinationValidationResult {
      let status = status.value
      onWorker.mutate { $0.append(pthread_main_np() == 0) }
      if heldFolder.value?.path == url.path {
        Task { await entered.enter() }
        gate.wait()
      }
      let available = status == .ready || status == .readOnly
      return DestinationValidationResult(
        isAvailable: available, isWritable: status == .ready, status: status,
        fingerprint: available
          ? .makeLow(
            volumeRootPath: nil, relativePathFromVolumeRoot: url.path,
            standardizedPath: url.path)
          : nil)
    }

    func release() {
      gate.signal()
      Task { await entered.releaseAll() }
    }
  }

  @MainActor
  private final class Harness {
    let root = TestScratch.directory("AutoSyncReadOnly")
    var folder: URL { root.appendingPathComponent("Backup") }
    let probe = Probe()
    let activationCenter = NotificationCenter()
    let released = LockedBox<[URL]>([])
    let builder = FakeAutoSyncEnvironmentBuilder()
    let autoSync = AutoSyncManager()
    let manager: ExportDestinationManager
    let timeline: ExportRecordStore
    let collections: CollectionExportRecordStore
    let lifecycle: AppLifecycleCoordinator
    let adapter: DestinationSnapshotAdapter
    let monitor: DestinationSafetyMonitor
    private let activation: AnyCancellable

    init(
      initialStatus: ExportDestinationStatus = .readOnly,
      scopes: AutoExportScopeSelection = AutoExportScopeSelection(timeline: true),
      retryDue: Bool = false
    ) async throws {
      let folder = root.appendingPathComponent("Backup")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      probe.status.mutate { $0 = initialStatus }
      let released = released
      manager = ExportDestinationManager(
        skipRestore: true, userDefaults: TestScratch.defaults("ReadOnlyDestination"),
        bookmarkSaver: { _ in true }, volumeNotificationCenter: NotificationCenter(),
        validationScopeAcquirer: { _ in true },
        validationScopeReleaser: { url in released.mutate { $0.append(url) } },
        validationProbe: probe)
      await manager.persistSelectionAndWait(folder)
      let id = try #require(manager.destinationId)
      let stores = root.appendingPathComponent("Records")
      timeline = ExportRecordStore(baseDirectoryURL: stores)
      collections = CollectionExportRecordStore(baseDirectoryURL: stores)
      let timeline = timeline
      let collections = collections
      let manager = manager
      lifecycle = AppLifecycleCoordinator(
        cancelActiveWork: {}, interruptForDestinationUnavailable: {},
        configureRecordStores: {
          AppCore.configureRecordStores(
            for: $0, destinationManager: manager, timelineStore: timeline,
            collectionStore: collections)
        })
      lifecycle.attach(
        initial: DestinationIdentitySnapshot(identity: manager.identity),
        identityPublisher: manager.identityPublisher)

      let confirmations = InMemoryDestinationSafetyConfirmationStore()
      try confirmations.confirm(destinationId: id)
      monitor = DestinationSafetyMonitor(
        identityPublisher: manager.identityPublisher, exportRecordStore: timeline,
        collectionExportRecordStore: collections, confirmationStore: confirmations,
        scanDirectory: { false })
      adapter = DestinationSnapshotAdapter(
        destinationManager: manager, lifecycleCoordinator: lifecycle, safetyMonitor: monitor)
      activation = AppCore.observeDestinationActivation(manager, center: activationCenter)

      if retryDue {
        let now = builder.clock.now()
        var retry = AutoSyncRetryState.empty
        retry.recordFailure(
          scope: .timeline, assetId: "retry", variant: .original, category: .iCloudTransient,
          errorSignature: "transient", at: now, nextEligibleAt: now.addingTimeInterval(1))
        try builder.retryStore.save(retry, destinationId: id)
      }
      builder.userDefaults.set(true, forKey: AutoSyncManager.enabledDefaultsKey)
      builder.scopes.subject.send(scopes)
      autoSync.attach(
        to: AutoSyncEnvironment(
          exportRunner: builder.exportRunner, destination: adapter, scopes: builder.scopes,
          photos: builder.photos, importing: builder.importing, dirtyStateStore: builder.dirtyStore,
          retryStateStore: builder.retryStore, runSummaryStore: builder.runSummaryStore,
          clock: builder.clock, photosAuthorization: builder.photosAuthorization,
          userDefaults: builder.userDefaults))
      monitor.attach()
    }

    func waitForSafety() async throws {
      try #require(
        await eventually("destination safety verdict") {
          self.monitor.verdict.stableId == self.manager.destinationId
        })
    }

    func drainClock(by seconds: TimeInterval = 120) async {
      builder.clock.advance(by: seconds)
      await autoSync.activeRunFanOutTask?.value
    }

    func activate() {
      activationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    func photosChanged() {
      builder.photos.push(
        PhotoLibraryPersistentChangeEvent(
          insertedLocalIdentifiers: ["synthetic"], observedAt: builder.clock.now()))
    }

    func cleanup() {
      activation.cancel()
      autoSync.setEnabled(false)
      timeline.drainSynchronously()
      collections.drainSynchronously()
      try? FileManager.default.removeItem(at: root)
    }
  }

  @Test func reachableReadOnlyDestinationDoesNotStartAnAutoExport() async throws {
    let h = try await Harness()
    defer { h.cleanup() }
    try await h.waitForSafety()
    try #require(h.manager.status == .readOnly && h.manager.isAvailable)
    #expect(h.manager.canImportNow)
    #expect(!h.manager.canExportNow)
    h.photosChanged()

    await h.drainClock()

    #expect(h.builder.exportRunner.receivedContexts.isEmpty)
  }

  @Test func foregroundRecoveryCoalescesAndResumesTheQueuedExportNow() async throws {
    let h = try await Harness(retryDue: true)
    defer {
      h.probe.release()
      h.cleanup()
    }
    try await h.waitForSafety()
    let stableId = try #require(h.manager.destinationId)
    #expect(h.autoSync.state == .waiting(.destinationReadOnly))
    h.autoSync.runNow()
    h.photosChanged()
    await h.drainClock(by: 1)
    #expect(h.builder.exportRunner.receivedContexts.isEmpty)

    h.probe.heldFolder.mutate { $0 = h.folder }
    h.probe.status.mutate { $0 = .ready }
    h.activate()
    try #require(await h.probe.entered.waitForEnter(count: 1))
    h.activate()
    h.activate()
    #expect(h.autoSync.state == .waiting(.destinationReadOnly))
    #expect(h.probe.onWorker.value == [true, true])
    #expect(!h.manager.canExportNow)
    h.probe.release()
    await h.manager.waitForValidation()
    #expect(h.manager.destinationId == stableId)
    #expect(h.manager.canExportNow)

    await h.drainClock(by: 0)
    h.activate()
    await h.drainClock()
    #expect(h.probe.onWorker.value == [true, true])
    #expect(h.builder.exportRunner.receivedContexts.map(\.reason) == [.userExportNow])
  }

  @Test func activationProbeFailureKeepsAutoExportHeld() async throws {
    let h = try await Harness()
    defer { h.cleanup() }
    try await h.waitForSafety()
    h.autoSync.runNow()
    h.probe.status.mutate { $0 = .unreachable }
    h.activate()
    await h.manager.waitForValidation()
    #expect(h.manager.status == .unreachable)
    #expect(!h.manager.isAvailable && !h.manager.canExportNow)

    h.activate()
    await h.drainClock()
    #expect(h.probe.onWorker.value == [true, true])
    #expect(h.builder.exportRunner.receivedContexts.isEmpty)
  }

  @Test func scheduledExportNowSurvivesAReadOnlyHold() async throws {
    let h = try await Harness(initialStatus: .ready)
    defer { h.cleanup() }
    try await h.waitForSafety()
    h.autoSync.runNow()
    h.probe.status.mutate { $0 = .readOnly }
    h.manager.revalidate()
    await h.manager.waitForValidation()
    h.photosChanged()
    await h.drainClock()
    #expect(h.autoSync.state == .waiting(.destinationReadOnly))
    #expect(h.builder.exportRunner.receivedContexts.isEmpty)

    h.probe.status.mutate { $0 = .ready }
    h.activate()
    await h.manager.waitForValidation()
    await h.drainClock(by: 0)
    #expect(h.builder.exportRunner.receivedContexts.map(\.reason) == [.userExportNow])
  }

  @Test func scheduledExportNowSurvivesValidationStartingBeforeTheTask() async throws {
    let h = try await Harness(initialStatus: .ready)
    defer {
      h.probe.release()
      h.cleanup()
    }
    try await h.waitForSafety()
    h.autoSync.runNow()
    h.builder.clock.advance(by: 0)
    let queued = try #require(h.autoSync.activeRunFanOutTask)

    h.probe.heldFolder.mutate { $0 = h.folder }
    h.manager.revalidate()
    try #require(await h.probe.entered.waitForEnter(count: 1))
    await queued.value
    #expect(!h.manager.canExportNow)
    #expect(h.builder.exportRunner.receivedContexts.isEmpty)
    h.photosChanged()

    h.probe.release()
    await h.manager.waitForValidation()
    await h.drainClock(by: 0)
    #expect(h.builder.exportRunner.receivedContexts.map(\.reason) == [.userExportNow])
  }

  @Test func queuedOldRunDoesNotStartAgainstASelectedFolderStillValidating() async throws {
    let h = try await Harness(initialStatus: .ready)
    defer {
      h.probe.release()
      h.cleanup()
    }
    try await h.waitForSafety()
    let oldId = try #require(h.manager.destinationId)
    let nextFolder = h.root.appendingPathComponent("Replacement")
    try FileManager.default.createDirectory(at: nextFolder, withIntermediateDirectories: true)
    var snapshots: [DestinationSnapshot] = []
    let subscription = h.adapter.destinationSnapshotPublisher.sink { snapshots.append($0) }
    defer { subscription.cancel() }
    h.autoSync.runNow()
    h.builder.clock.advance(by: 0)
    let queued = try #require(h.autoSync.activeRunFanOutTask)

    h.probe.status.mutate { $0 = .readOnly }
    h.probe.heldFolder.mutate { $0 = nextFolder }
    try #require(h.manager.applyFolderSelection(nextFolder, decision: .newDestination))
    try #require(await h.probe.entered.waitForEnter(count: 1))
    await queued.value
    #expect(h.manager.selectedFolderURL == nextFolder)
    #expect(snapshots.last?.id == oldId && snapshots.last?.isValidating == true)
    #expect(h.builder.exportRunner.receivedContexts.isEmpty)

    h.probe.release()
    await h.manager.waitForValidation()
    let newId = try #require(h.manager.destinationId)
    #expect(newId != oldId)
    let replacementSnapshots = snapshots.filter { $0.id == newId }
    #expect(!replacementSnapshots.isEmpty)
    #expect(replacementSnapshots.allSatisfy { $0.isAvailable && !$0.isWritable })
    await h.drainClock()
    #expect(h.builder.exportRunner.receivedContexts.isEmpty)
  }

  @Test func supersededActivationProbeCannotOverwriteTheReplacementDestination() async throws {
    let h = try await Harness()
    defer {
      h.probe.release()
      h.cleanup()
    }
    try await h.waitForSafety()
    let nextFolder = h.root.appendingPathComponent("Replacement")
    try FileManager.default.createDirectory(at: nextFolder, withIntermediateDirectories: true)
    h.probe.status.mutate { $0 = .unreachable }
    h.probe.heldFolder.mutate { $0 = h.folder }
    h.activate()
    try #require(await h.probe.entered.waitForEnter(count: 1))

    h.probe.status.mutate { $0 = .ready }
    try #require(h.manager.applyFolderSelection(nextFolder, decision: .newDestination))
    await h.manager.waitForValidation()
    let selectedId = try #require(h.manager.destinationId)
    h.probe.release()
    try #require(
      await eventually("obsolete probe releases its scope") {
        h.released.value.filter { $0.path == h.folder.path }.count == 2
      })
    #expect(h.manager.destinationId == selectedId)
    #expect(h.manager.selectedFolderURL == nextFolder)
    #expect(h.manager.status == .ready && h.manager.canExportNow)
  }

  @Test func activeScopeStaysRunningThroughValidationButReadOnlyHoldsTheNextScope() async throws {
    let h = try await Harness(
      initialStatus: .ready, scopes: AutoExportScopeSelection(timeline: true, favorites: true))
    let gate = AsyncCheckpoint()
    let runner = h.builder.exportRunner
    try await withCleanup {
      try await h.waitForSafety()
      runner.gateForInvocation = { $0 == 1 ? gate : nil }
      h.autoSync.runNow()
      h.builder.clock.advance(by: 0)
      let fanOut = try #require(h.autoSync.activeRunFanOutTask)
      try #require(await gate.waitForEnter(count: 1))
      let running = try #require(runner.receivedContexts.first)
      runner.subject.send(
        ExportRunState(activeContext: running, isManualActive: false, isAutoSyncActive: true))

      h.probe.heldFolder.mutate { $0 = h.folder }
      h.manager.revalidate()
      try #require(await h.probe.entered.waitForEnter(count: 1))
      #expect(h.autoSync.state == .running(reason: .userExportNow))

      h.probe.heldFolder.mutate { $0 = nil }
      h.probe.release()
      await h.manager.waitForValidation()
      h.probe.status.mutate { $0 = .readOnly }
      h.manager.revalidate()
      await h.manager.waitForValidation()
      #expect(h.autoSync.state == .running(reason: .userExportNow))
      #expect(runner.cancelAutoSyncRunCalls == 0)

      runner.subject.send(.idle)
      await gate.releaseAll()
      await fanOut.value
      #expect(runner.receivedContexts.count == 1)
      #expect(h.autoSync.state == .waiting(.destinationReadOnly))
    } cleanup: {
      h.probe.release()
      await gate.releaseAll()
      h.cleanup()
    }
  }

  @Test(arguments: [true, false])
  func exportNowSurvivesWritabilityRecoveryBetweenScopes(advanceBetweenScopes: Bool) async throws {
    let h = try await Harness(
      initialStatus: .ready, scopes: AutoExportScopeSelection(timeline: true, favorites: true))
    let firstScope = AsyncCheckpoint()
    let secondScope = AsyncCheckpoint()
    let runner = h.builder.exportRunner
    try await withCleanup {
      try await h.waitForSafety()
      runner.gateForInvocation = { [1: firstScope, 2: secondScope][$0] }
      h.photosChanged()
      h.builder.clock.advance(by: 120)
      let fanOut = try #require(h.autoSync.activeRunFanOutTask)
      try #require(await firstScope.waitForEnter(count: 1))
      let first = try #require(runner.receivedContexts.first)
      try #require(first.scope == .timelineFullLibrary && first.reason == .photosChanged)
      runner.subject.send(
        ExportRunState(activeContext: first, isManualActive: false, isAutoSyncActive: true))

      h.probe.status.mutate { $0 = .readOnly }
      h.manager.revalidate()
      await h.manager.waitForValidation()
      h.autoSync.runNow()
      h.probe.status.mutate { $0 = .ready }
      h.activate()
      await h.manager.waitForValidation()
      try #require(h.manager.canExportNow)

      // ExportManager publishes idle before returning the summary to the fan-out task.
      runner.subject.send(.idle)
      #expect(h.autoSync.state == .running(reason: .photosChanged))
      if advanceBetweenScopes {
        h.builder.clock.advance(by: 0)
      }
      await firstScope.releaseAll()
      try #require(await secondScope.waitForEnter(count: 1))
      let second = try #require(runner.receivedContexts.last)
      #expect(second.scope == .favoritesFull && second.reason == .photosChanged)
      runner.subject.send(
        ExportRunState(activeContext: second, isManualActive: false, isAutoSyncActive: true))
      if !advanceBetweenScopes {
        h.builder.clock.advance(by: 0)
      }
      #expect(runner.receivedContexts.count == 2)
      let currentFanOut = h.autoSync.activeRunFanOutTask
      runner.subject.send(.idle)
      await secondScope.releaseAll()
      await fanOut.value
      await currentFanOut?.value

      await h.drainClock(by: 0)
      #expect(
        runner.receivedContexts.map(\.scope) == [
          .timelineFullLibrary, .favoritesFull, .timelineFullLibrary, .favoritesFull,
        ])
      #expect(
        runner.receivedContexts.map(\.reason) == [
          .photosChanged, .photosChanged, .userExportNow, .userExportNow,
        ])
      #expect(runner.cancelAutoSyncRunCalls == 0)
    } cleanup: {
      await firstScope.releaseAll()
      await secondScope.releaseAll()
      h.cleanup()
    }
  }
}
