import Combine
import Foundation
import Testing

@testable import Photo_Export

/// Exercises the run boundary through the real export queue and AutoSync effect runner.
/// A Photos change observed after the first run's fetch must survive that run's
/// completion and cause another export without a second Photos notification.
@MainActor
struct AutoSyncMidRunChangeIntegrationTests {
  @MainActor
  private final class SummaryProbe {
    private(set) var summaries: [ExportRunSummary] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var cancellable: AnyCancellable?

    init(manager: AutoSyncManager) {
      cancellable = manager.$lastRunSummary.compactMap { $0 }.sink { [weak self] summary in
        MainActor.assumeIsolated { self?.receive(summary) }
      }
    }

    func waitForCount(_ count: Int) async {
      if summaries.count >= count { return }
      await withCheckedContinuation { continuation in
        waiters.append((count: count, continuation: continuation))
      }
    }

    private func receive(_ summary: ExportRunSummary) {
      summaries.append(summary)
      let ready = waiters.filter { $0.count <= summaries.count }
      waiters.removeAll { $0.count <= summaries.count }
      for waiter in ready {
        waiter.continuation.resume()
      }
    }
  }

  @Test func photosChangeAfterFetchIsExportedByFollowUpRun() async {
    let assetDate = Date(timeIntervalSince1970: 1_700_000_000)
    let year = Calendar.current.component(.year, from: assetDate)
    let month = Calendar.current.component(.month, from: assetDate)
    let monthKey = "\(year)-\(month)"
    let assetA = TestAssetFactory.makeAsset(id: "asset-A", creationDate: assetDate)
    let assetB = TestAssetFactory.makeAsset(id: "asset-B", creationDate: assetDate)

    let photoLibrary = FakePhotoLibraryService()
    photoLibrary.yearCounts = [(year: year, count: 1)]
    photoLibrary.assetsByYearMonth[monthKey] = [assetA]
    photoLibrary.resourcesByAssetId[assetA.id] = [
      TestAssetFactory.makeResource(originalFilename: "asset-A.jpg")
    ]
    photoLibrary.resourcesByAssetId[assetB.id] = [
      TestAssetFactory.makeResource(originalFilename: "asset-B.jpg")
    ]

    let destination = FakeExportDestination()
    let writer = FakeAssetResourceWriter()
    let writeGate = AsyncCheckpoint()
    writer.checkpoint = writeGate
    let storeRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("AutoSyncMidRun-\(UUID().uuidString)", isDirectory: true)
    let destinationSnapshot = DestinationSnapshot(
      fingerprint: .makeHigh(
        volumeUUIDString: "mid-run-test-volume",
        volumeRootPath: nil,
        relativePathFromVolumeRoot: "/backup",
        standardizedPath: destination.rootURL.path
      ),
      isAvailable: true,
      safety: .safe
    )
    let destinationId = destinationSnapshot.id!
    let timelineStore = ExportRecordStore(baseDirectoryURL: storeRoot)
    timelineStore.configure(for: destinationId)
    let collectionStore = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    collectionStore.configure(for: destinationId)

    let builder = FakeAutoSyncEnvironmentBuilder()
    let exportManager = ExportManager(
      photoLibraryService: photoLibrary,
      exportDestination: destination,
      exportRecordStore: timelineStore,
      collectionExportRecordStore: collectionStore,
      assetResourceWriter: writer,
      fileSystem: FakeFileSystem(),
      userDefaults: builder.userDefaults
    )
    let autoSync = AutoSyncManager()
    let environment = AutoSyncEnvironment(
      exportRunner: exportManager,
      destination: builder.destination,
      scopes: builder.scopes,
      photos: builder.photos,
      importing: exportManager,
      dirtyStateStore: builder.dirtyStore,
      retryStateStore: builder.retryStore,
      runSummaryStore: builder.runSummaryStore,
      perDestinationTokenStore: builder.perDestinationTokenStore,
      currentRunStore: builder.currentRunStore,
      clock: builder.clock,
      userDefaults: builder.userDefaults
    )
    defer {
      autoSync.setEnabled(false)
      exportManager.cancelAndClear()
      timelineStore.flushForTesting()
      collectionStore.flushForTesting()
      try? FileManager.default.removeItem(at: storeRoot)
      destination.cleanup()
    }

    builder.userDefaults.set(true, forKey: AutoSyncManager.enabledDefaultsKey)
    builder.destination.subject.send(destinationSnapshot)
    builder.scopes.subject.send(AutoExportScopeSelection(timeline: true))
    autoSync.attach(to: environment)
    let summaries = SummaryProbe(manager: autoSync)

    builder.clock.advance(by: 10)
    await writeGate.waitForEnter(count: 1)
    #expect(writer.writeCalls.map(\.assetId) == [assetA.id])

    // The first run has finished its Photos fetch and is paused in the writer.
    // Make B visible to the next fetch, then deliver exactly one change event.
    photoLibrary.assetsByYearMonth[monthKey] = [assetA, assetB]
    builder.photos.push(
      PhotoLibraryPersistentChangeEvent(
        insertedLocalIdentifiers: [assetB.id], observedAt: builder.clock.now()
      ))
    #expect(
      builder.dirtyStore.load(destinationId: destinationId)
        .scope(.timeline).pendingAssetIds.contains(assetB.id))

    await writeGate.releaseAll()
    await summaries.waitForCount(1)
    #expect(summaries.summaries[0].result == .completed)
    #expect(writer.writeCalls.map(\.assetId) == [assetA.id])
    #expect(
      builder.dirtyStore.load(destinationId: destinationId)
        .scope(.timeline).pendingAssetIds.contains(assetB.id),
      "Completion of the earlier scan must retain B's mid-run change."
    )
    guard case .scheduled(.photosChanged, _) = autoSync.state else {
      Issue.record("Expected a scheduled follow-up for B, got \(autoSync.state)")
      return
    }

    builder.clock.advance(by: 30)
    guard case .running = autoSync.state else {
      Issue.record("Expected the follow-up run to start, got \(autoSync.state)")
      return
    }
    await writeGate.waitForEnter(count: 2)
    await summaries.waitForCount(2)

    #expect(summaries.summaries[1].result == .completed)
    #expect(writer.writeCalls.map(\.assetId) == [assetA.id, assetB.id])
    #expect(timelineStore.isExported(assetId: assetB.id))
    #expect(builder.dirtyStore.load(destinationId: destinationId).scope(.timeline).isEmpty)
    #expect(autoSync.state == .idle)
    #expect(builder.clock.pendingCount == 0, "A clean follow-up must not schedule an endless run.")
  }
}
