import Combine
import Foundation
import Testing

@testable import Photo_Export

/// Turning Auto Export off stops the automatic run in progress through the same teardown
/// as Cancel, leaves manual exports alone, and keeps unexported work for the next run.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct AutoSyncDisableStopsRunTests {
  @MainActor
  private final class Harness {
    let year: Int
    let assetA: AssetDescriptor
    let assetB: AssetDescriptor
    let photoLibrary = FakePhotoLibraryService()
    let destination = FakeExportDestination()
    let writer = FakeAssetResourceWriter()
    let writeGate = AsyncCheckpoint()
    let storeRoot = TestScratch.directory("AutoSyncDisable")
    let destinationSnapshot: DestinationSnapshot
    let timelineStore: ExportRecordStore
    let collectionStore: CollectionExportRecordStore
    let builder = FakeAutoSyncEnvironmentBuilder()
    let exportManager: ExportManager
    let autoSync = AutoSyncManager()
    /// Every run that resolved through `runExport`, including runs AutoSync discards.
    private(set) var runSummaries: [ExportRunSummary] = []
    private var subscription: AnyCancellable?

    init() async {
      let assetDate = Date(timeIntervalSince1970: 1_700_000_000)
      year = Calendar.current.component(.year, from: assetDate)
      let month = Calendar.current.component(.month, from: assetDate)
      assetA = TestAssetFactory.makeAsset(id: "asset-A", creationDate: assetDate)
      assetB = TestAssetFactory.makeAsset(id: "asset-B", creationDate: assetDate)
      photoLibrary.yearCounts = [(year: year, count: 2)]
      photoLibrary.assetsByYearMonth["\(year)-\(month)"] = [assetA, assetB]
      for asset in [assetA, assetB] {
        photoLibrary.resourcesByAssetId[asset.id] = [
          TestAssetFactory.makeResource(originalFilename: "\(asset.id).jpg")
        ]
      }
      writer.checkpoint = writeGate
      destinationSnapshot = DestinationSnapshot(
        fingerprint: .makeHigh(
          volumeUUIDString: "disable-test-volume", volumeRootPath: nil,
          relativePathFromVolumeRoot: "/backup", standardizedPath: destination.rootURL.path),
        isAvailable: true, safety: .safe)
      timelineStore = ExportRecordStore(baseDirectoryURL: storeRoot)
      await timelineStore.configureAndWait(for: destinationSnapshot.id!)
      collectionStore = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
      await collectionStore.configureAndWait(for: destinationSnapshot.id!)
      exportManager = ExportManager(
        photoLibraryService: photoLibrary, exportDestination: destination,
        exportRecordStore: timelineStore, collectionExportRecordStore: collectionStore,
        assetResourceWriter: writer,
        localHEICStorage: LocalHEICStorage(root: TestScratch.directory("ExportHEIC")),
        fileSystem: FakeFileSystem(),
        userDefaults: builder.userDefaults)
      subscription = exportManager.completedRunsPublisher.sink { [weak self] summary in
        MainActor.assumeIsolated { self?.runSummaries.append(summary) }
      }
    }

    /// Enables Auto Export for the timeline. The app-launch run starts after 10 s.
    func attach() {
      builder.userDefaults.set(true, forKey: AutoSyncManager.enabledDefaultsKey)
      builder.destination.subject.send(destinationSnapshot)
      builder.scopes.subject.send(AutoExportScopeSelection(timeline: true))
      autoSync.attach(
        to: AutoSyncEnvironment(
          exportRunner: exportManager, destination: builder.destination,
          scopes: builder.scopes, photos: builder.photos, importing: exportManager,
          dirtyStateStore: builder.dirtyStore, retryStateStore: builder.retryStore,
          runSummaryStore: builder.runSummaryStore,
          perDestinationTokenStore: builder.perDestinationTokenStore,
          currentRunStore: builder.currentRunStore, clock: builder.clock,
          photosAuthorization: builder.photosAuthorization,
          userDefaults: builder.userDefaults))
    }

    var writtenIds: [String] { writer.writeCalls.map(\.assetId) }

    func close() {
      autoSync.setEnabled(false)
      exportManager.cancelAndClear()
      subscription = nil
      Task { [writeGate] in await writeGate.releaseAll() }
      timelineStore.drainSynchronously()
      collectionStore.drainSynchronously()
      try? FileManager.default.removeItem(at: storeRoot)
      destination.cleanup()
    }
  }

  @Test func disablingStopsTheRunningExportAndReenablingExportsTheRest() async throws {
    let h = await Harness()
    defer { h.close() }
    h.attach()
    h.builder.clock.advance(by: 10)
    let writing = await h.writeGate.waitForEnter(count: 1)
    try #require(writing)
    try #require(h.writtenIds == [h.assetA.id])
    try #require(h.exportManager.pendingJobs.map(\.assetLocalIdentifier) == [h.assetB.id])
    let jobA = try #require(h.exportManager.currentTask)
    let fanOut = try #require(h.autoSync.activeRunFanOutTask)
    // A Photos change mid-run leaves dirty work that could schedule a follow-up.
    h.builder.photos.push(
      PhotoLibraryPersistentChangeEvent(
        insertedLocalIdentifiers: [h.assetB.id], observedAt: h.builder.clock.now()))

    h.autoSync.setEnabled(false)

    #expect(h.exportManager.activeRunContext == nil)
    #expect(h.exportManager.pendingJobs.isEmpty)
    #expect(h.runSummaries.map(\.result) == [.cancelled])
    #expect(h.runSummaries.first?.cancelReason == .userCancelled)
    #expect(h.autoSync.state == .disabled)
    #expect(h.builder.clock.pendingCount == 0, "Nothing may restart while disabled")
    // The toolbar's Cancel follows `setEnabled(false)` with `cancelAndClear()`.
    h.exportManager.cancelAndClear()
    #expect(h.runSummaries.count == 1)

    await h.writeGate.releaseAll()
    let aFinished = await finished(jobA)
    try #require(aFinished)
    let fanOutEnded = await finished(fanOut)
    try #require(fanOutEnded)
    #expect(h.autoSync.lastRunSummary == nil, "AutoSync discards the cancelled run's summary")
    #expect(h.writtenIds == [h.assetA.id])
    #expect(!h.exportManager.hasActiveExportWork)
    #expect(
      h.timelineStore.exportInfo(assetId: h.assetA.id)?.variants.values
        .contains { $0.status == .inProgress } != true)

    h.autoSync.setEnabled(true)
    h.builder.clock.advance(by: 10)
    let rerun = await eventually("re-enabled run completes") { h.runSummaries.count == 2 }
    try #require(rerun)
    #expect(h.runSummaries[1].result == .completed)
    #expect(h.writtenIds.contains(h.assetB.id))
    #expect(
      h.timelineStore.isExported(asset: h.assetB, selection: .edited, livePhotosPaired: false))
  }

  @Test func disablingWhilePausedEndsTheRun() async throws {
    let h = await Harness()
    defer { h.close() }
    h.attach()
    h.builder.clock.advance(by: 10)
    let writing = await h.writeGate.waitForEnter(count: 1)
    try #require(writing)
    let jobA = try #require(h.exportManager.currentTask)
    h.exportManager.pause()
    await h.writeGate.releaseAll()
    let aFinished = await finished(jobA)
    try #require(aFinished)
    // Paused and idle: the run stays active with B queued until something resolves it.
    try #require(h.exportManager.isPaused)
    try #require(h.exportManager.activeRunContext != nil)
    try #require(h.exportManager.pendingJobs.map(\.assetLocalIdentifier) == [h.assetB.id])

    h.autoSync.setEnabled(false)

    #expect(h.exportManager.activeRunContext == nil)
    #expect(h.runSummaries.map(\.result) == [.cancelled])
    #expect(!h.exportManager.isPaused)
    #expect(h.exportManager.pendingJobs.isEmpty)
  }

  @Test func disablingDuringTheLibraryScanEnqueuesNothing() async throws {
    let h = await Harness()
    defer { h.close() }
    let scanGate = AsyncCheckpoint()
    try await withCleanup {
      h.photoLibrary.fetchAssetsCheckpointByYear[h.year] = scanGate
      h.attach()
      h.builder.clock.advance(by: 10)
      let scanning = await scanGate.waitForEnter(count: 1)
      try #require(scanning)
      let preparation = h.exportManager.currentPreparationTasks
      try #require(!preparation.isEmpty)

      h.autoSync.setEnabled(false)

      #expect(h.exportManager.activeRunContext == nil)
      #expect(h.runSummaries.map(\.result) == [.cancelled])
      await scanGate.releaseAll()
      for task in preparation {
        let done = await finished(task)
        try #require(done)
      }
      #expect(h.exportManager.pendingJobs.isEmpty)
      #expect(h.writtenIds.isEmpty)
      #expect(!h.exportManager.hasActiveExportWork)
    } cleanup: {
      await scanGate.releaseAll()
      for task in h.exportManager.currentPreparationTasks { _ = await finished(task) }
    }
  }

  /// Guard: only automatic runs stop. A manual export (the toolbar's legacy `start*` path,
  /// which has no run context) keeps going after Auto Export is off.
  @Test func disablingLeavesAManualExportRunning() async throws {
    let h = await Harness()
    defer { h.close() }
    h.attach()
    h.exportManager.startExportAll()
    let writing = await h.writeGate.waitForEnter(count: 1)
    try #require(writing)

    h.autoSync.setEnabled(false)
    await h.writeGate.releaseAll()
    await h.exportManager.waitForQueueDrained()

    #expect(h.writtenIds == [h.assetA.id, h.assetB.id])
  }
}
