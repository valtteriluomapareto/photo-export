import Combine
import Foundation
import Testing

@testable import Photo_Export

/// A network share that stops answering mid-run, through the real export queue and the
/// AutoSync effect runner: the run stops at the first failed commit, nothing reschedules
/// it while the destination still looks mounted, and the failed item is retried by the
/// next Auto Export run.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct AutoSyncDestinationStopIntegrationTests {
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
      for waiter in ready { waiter.continuation.resume() }
    }
  }

  @Test func unreachableShareStopsTheRunWithoutAReschedule() async throws {
    let assetDate = Date(timeIntervalSince1970: 1_700_000_000)
    let year = Calendar.current.component(.year, from: assetDate)
    let month = Calendar.current.component(.month, from: assetDate)
    let ids = ["asset-A", "asset-B", "asset-C"]
    let photoLibrary = FakePhotoLibraryService()
    photoLibrary.yearCounts = [(year: year, count: ids.count)]
    photoLibrary.assetsByYearMonth["\(year)-\(month)"] = ids.map {
      TestAssetFactory.makeAsset(id: $0, creationDate: assetDate)
    }
    for id in ids {
      photoLibrary.resourcesByAssetId[id] = [
        TestAssetFactory.makeResource(originalFilename: "\(id).JPG")
      ]
    }

    // Every exclusive rename fails with ENOTCONN until the share comes back.
    let unreachable = LockedBox(true)
    let files = FakeFileSystem(
      real: FileIOService(
        renamer: { source, destination, flags in
          unreachable.value ? ENOTCONN : FileIOService.systemRename(source, destination, flags)
        },
        capability: { _ in true }))
    let destination = FakeExportDestination()
    let writer = FakeAssetResourceWriter()
    let storeRoot = TestScratch.directory("AutoSyncDestinationStop")
    let destinationSnapshot = DestinationSnapshot(
      stableId: "share", fingerprint: nil, isAvailable: true, safety: .safe)
    let destinationId = try #require(destinationSnapshot.id)
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
      fileSystem: files,
      userDefaults: builder.userDefaults
    )
    let autoSync = AutoSyncManager()
    exportManager.autoSyncEligibilityCheck = { [weak autoSync] assetId, placement, variant, now in
      autoSync?.isAutoSyncEligible(
        assetId: assetId, placement: placement, variant: variant, now: now) ?? true
    }
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
    // Pending Photos work that the resume hook would otherwise reschedule.
    builder.photos.push(
      PhotoLibraryPersistentChangeEvent(
        insertedLocalIdentifiers: Set(ids), observedAt: builder.clock.now()))

    builder.clock.advance(by: 30)
    let firstRun = try #require(autoSync.activeRunFanOutTask)
    await firstRun.value
    await summaries.waitForCount(1)

    let stopped = summaries.summaries[0]
    #expect(stopped.result == .interrupted)
    #expect(stopped.cancelReason == .destinationUnavailable)
    #expect(stopped.stoppedBy == .destinationUnavailable)
    #expect(stopped.failures.map(\.assetId) == ["asset-A"])
    #expect(writer.writeCalls.map(\.assetId) == ["asset-A"])
    #expect(autoSync.state == .idle)
    #expect(builder.clock.pendingCount == 0, "No debounce or retry timer after the stop")
    #expect(
      builder.dirtyStore.load(destinationId: destinationId).scope(.timeline).pendingAssetIds
        == Set(ids))
    let entry = try #require(
      autoSync.currentRetryState.entry(scope: .timeline, assetId: "asset-A", variant: .original))
    #expect(entry.category == .destinationUnavailable && entry.nextEligibleAt == nil)

    // The share answers again and a Photos change arrives: the next run retries the
    // failed item with the others.
    unreachable.mutate { $0 = false }
    builder.photos.push(
      PhotoLibraryPersistentChangeEvent(
        insertedLocalIdentifiers: ["asset-A"], observedAt: builder.clock.now()))
    guard case .scheduled(.photosChanged, _) = autoSync.state else {
      Issue.record("A Photos change after the stop must schedule, got \(autoSync.state)")
      return
    }
    builder.clock.advance(by: 30)
    let secondRun = try #require(autoSync.activeRunFanOutTask)
    await secondRun.value
    await summaries.waitForCount(2)

    #expect(summaries.summaries[1].result == .completed)
    for id in ids { #expect(timelineStore.isExported(assetId: id)) }
    #expect(autoSync.currentRetryState.isEmpty)
    #expect(autoSync.state == .idle)
    #expect(builder.clock.pendingCount == 0)
  }
}
