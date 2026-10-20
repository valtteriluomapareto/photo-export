import Combine
import Foundation
import Testing

@testable import Photo_Export

/// Runs a Favorites-only Auto Export through the real export queue and AutoSync effect
/// runner. Without Photos access the run must fail and keep the pending change, so the
/// change exports once access returns instead of being acknowledged by an empty scan.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct AutoSyncPhotosAccessIntegrationTests {
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

  @Test(arguments: [false, true])
  func missingPhotosAccessKeepsDirtyState(authorized: Bool) async {
    let asset = TestAssetFactory.makeAsset(
      id: "favorite-A", creationDate: Date(timeIntervalSince1970: 1_700_000_000))
    let photoLibrary = FakePhotoLibraryService()
    photoLibrary.isAuthorized = authorized
    photoLibrary.favoritesAssets = [asset]
    photoLibrary.resourcesByAssetId[asset.id] = [
      TestAssetFactory.makeResource(originalFilename: "favorite-A.jpg")
    ]

    let destination = FakeExportDestination()
    let writer = FakeAssetResourceWriter()
    let storeRoot = TestScratch.directory("AutoSyncPhotosAccess")
    let destinationSnapshot = DestinationSnapshot(
      fingerprint: .makeHigh(
        volumeUUIDString: "photos-access-test-volume",
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
    builder.scopes.subject.send(AutoExportScopeSelection(favorites: true))
    autoSync.attach(to: environment)
    let summaries = SummaryProbe(manager: autoSync)

    // The change must arrive before any run starts, so only the run it schedules can
    // acknowledge it.
    switch autoSync.state {
    case .idle, .scheduled: break
    default:
      Issue.record("Expected no run before the change, got \(autoSync.state)")
      return
    }
    builder.photos.push(
      PhotoLibraryPersistentChangeEvent(
        insertedLocalIdentifiers: [asset.id], observedAt: builder.clock.now()
      ))
    guard case .scheduled(.photosChanged, _) = autoSync.state else {
      Issue.record("Expected a run scheduled for the change, got \(autoSync.state)")
      return
    }
    #expect(
      builder.dirtyStore.load(destinationId: destinationId)
        .scope(.favorites).pendingAssetIds.contains(asset.id))

    builder.clock.advance(by: 30)
    guard case .running = autoSync.state else {
      Issue.record("Expected the scheduled run to start, got \(autoSync.state)")
      return
    }
    await summaries.waitForCount(1)
    #expect(summaries.summaries.count == 1)
    let summary = summaries.summaries.first
    let favorites = builder.dirtyStore.load(destinationId: destinationId).scope(.favorites)

    if authorized {
      #expect(summary?.result == .completed)
      #expect(summary?.completedCount == 1)
      #expect(writer.writeCalls.map(\.assetId) == [asset.id])
      #expect(collectionStore.placements(matching: .favorites).count == 1)
      #expect(favorites.isEmpty)
      #expect(autoSync.state == .idle)
      #expect(builder.clock.pendingCount == 0)
    } else {
      #expect(summary?.result == .failed)
      #expect(summary?.enqueuedCount == 0)
      #expect(summary?.failures.isEmpty == true)
      #expect(photoLibrary.scopeFetchCalls.isEmpty)
      #expect(writer.writeCalls.isEmpty)
      #expect(builder.retryStore.load(destinationId: destinationId).isEmpty)
      #expect(
        favorites.pendingAssetIds.contains(asset.id),
        "A run that could not scan Favorites must keep the pending change.")
      // Pending work reschedules every 30 s until access returns.
      guard case .scheduled(.photosChanged, _) = autoSync.state else {
        Issue.record("Expected the pending change to stay scheduled, got \(autoSync.state)")
        return
      }
    }
  }
}
