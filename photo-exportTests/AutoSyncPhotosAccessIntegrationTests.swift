import Combine
import Foundation
import Testing

@testable import Photo_Export

/// Runs a Favorites-only Auto Export through the real export queue and AutoSync effect
/// runner. Without Photos access Auto Export is blocked: nothing runs or is written, and the
/// pending change exports once access returns instead of being acknowledged by an empty scan.
///
/// As in production, one `PhotoLibraryManager` is both the export's photo service and the
/// access provider, so the export guards read its cached flag. The fake service behind it
/// stands in for the system: its status is what a refresh reads.
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

  @MainActor
  private final class Fixture {
    let asset = TestAssetFactory.makeAsset(
      id: "favorite-A", creationDate: Date(timeIntervalSince1970: 1_700_000_000))
    let photoLibrary = FakePhotoLibraryService()
    let library: PhotoLibraryManager
    let destination = FakeExportDestination()
    let writer = FakeAssetResourceWriter()
    let storeRoot = TestScratch.directory("AutoSyncPhotosAccess")
    let builder = FakeAutoSyncEnvironmentBuilder()
    let destinationSnapshot: DestinationSnapshot
    let timelineStore: ExportRecordStore
    let collectionStore: CollectionExportRecordStore
    let exportManager: ExportManager
    let autoSync = AutoSyncManager()
    private(set) var summaries: SummaryProbe?

    init() {
      photoLibrary.favoritesAssets = [asset]
      photoLibrary.resourcesByAssetId[asset.id] = [
        TestAssetFactory.makeResource(originalFilename: "favorite-A.jpg")
      ]
      library = PhotoLibraryManager(overrideService: photoLibrary)
      destinationSnapshot = DestinationSnapshot(
        fingerprint: .makeHigh(
          volumeUUIDString: "photos-access-test-volume",
          volumeRootPath: nil,
          relativePathFromVolumeRoot: "/backup",
          standardizedPath: destination.rootURL.path
        ),
        isAvailable: true,
        safety: .safe
      )
      timelineStore = ExportRecordStore(baseDirectoryURL: storeRoot)
      timelineStore.configure(for: destinationSnapshot.id!)
      collectionStore = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
      collectionStore.configure(for: destinationSnapshot.id!)
      exportManager = ExportManager(
        photoLibraryService: library,
        exportDestination: destination,
        exportRecordStore: timelineStore,
        collectionExportRecordStore: collectionStore,
        assetResourceWriter: writer,
        fileSystem: FakeFileSystem(),
        userDefaults: builder.userDefaults
      )
    }

    var destinationId: String { destinationSnapshot.id! }
    var favorites: ScopeDirtyState {
      builder.dirtyStore.load(destinationId: destinationId).scope(.favorites)
    }

    /// What the system reports now. `library.isAuthorized`, the cached flag the export
    /// guards and Auto Export read, changes only when something refreshes it.
    func setAccess(_ authorized: Bool) {
      photoLibrary.isAuthorized = authorized
      photoLibrary.authorizationStatus = authorized ? .authorized : .denied
    }

    /// The app becoming active refreshes access.
    func activate() { library.refreshAuthorization() }

    func attach() {
      builder.userDefaults.set(true, forKey: AutoSyncManager.enabledDefaultsKey)
      builder.destination.subject.send(destinationSnapshot)
      builder.scopes.subject.send(AutoExportScopeSelection(favorites: true))
      autoSync.attach(
        to: AutoSyncEnvironment(
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
          photosAuthorization: library,
          userDefaults: builder.userDefaults
        ))
      summaries = SummaryProbe(manager: autoSync)
    }

    func pushChange() {
      builder.photos.push(
        PhotoLibraryPersistentChangeEvent(
          insertedLocalIdentifiers: [asset.id], observedAt: builder.clock.now()
        ))
    }

    func tearDown() {
      autoSync.setEnabled(false)
      exportManager.cancelAndClear()
      timelineStore.flushForTesting()
      collectionStore.flushForTesting()
      try? FileManager.default.removeItem(at: storeRoot)
      destination.cleanup()
    }
  }

  private func expectExported(_ f: Fixture, summaries count: Int) async {
    guard case .running = f.autoSync.state else {
      Issue.record("Expected the scheduled run to start, got \(f.autoSync.state)")
      return
    }
    await f.summaries?.waitForCount(count)
    let summary = f.summaries?.summaries.last
    #expect(f.summaries?.summaries.count == count)
    #expect(summary?.result == .completed)
    #expect(summary?.completedCount == 1)
    #expect(f.writer.writeCalls.map(\.assetId) == [f.asset.id])
    #expect(f.collectionStore.placements(matching: .favorites).count == 1)
    #expect(f.favorites.isEmpty)
    #expect(f.autoSync.state == .idle)
    #expect(f.builder.clock.pendingCount == 0)
  }

  @Test func changeExportsWithAccess() async {
    let f = Fixture()
    defer { f.tearDown() }
    f.attach()
    switch f.autoSync.state {
    case .idle, .scheduled: break
    default:
      Issue.record("Expected no run before the change, got \(f.autoSync.state)")
      return
    }
    f.pushChange()
    guard case .scheduled(.photosChanged, _) = f.autoSync.state else {
      Issue.record("Expected a run scheduled for the change, got \(f.autoSync.state)")
      return
    }
    #expect(f.favorites.pendingAssetIds.contains(f.asset.id))
    f.builder.clock.advance(by: 30)
    await expectExported(f, summaries: 1)
  }

  /// Without access nothing runs: no journal, no summary, the change stays pending. Once
  /// access returns, the catch-up exports it.
  @Test func missingAccessHoldsTheChangeUntilAccessReturns() async {
    let f = Fixture()
    defer { f.tearDown() }
    f.setAccess(false)
    f.activate()
    f.attach()
    #expect(f.autoSync.state == .blocked(.photosAccessMissing))
    f.pushChange()
    #expect(f.autoSync.state == .blocked(.photosAccessMissing))
    f.builder.clock.advance(by: 30)
    f.builder.clock.advance(by: 30)
    #expect(f.autoSync.activeRunFanOutTask == nil)
    #expect(f.builder.currentRunStore.saveCount == 0)
    #expect(f.builder.runSummaryStore.saveCount == 0)
    #expect(f.photoLibrary.scopeFetchCalls.isEmpty)
    #expect(f.builder.clock.pendingCount == 0)
    #expect(
      f.favorites.pendingAssetIds.contains(f.asset.id),
      "Blocked Auto Export must keep the pending change.")

    f.setAccess(true)
    f.activate()
    guard case .scheduled(.photosChanged, _) = f.autoSync.state else {
      Issue.record("Expected access returning to schedule a catch-up, got \(f.autoSync.state)")
      return
    }
    f.builder.clock.advance(by: 30)
    await expectExported(f, summaries: 1)
  }

  /// Revoked while the app was in the background: the cached flag still says authorized,
  /// but the refresh before the run reads the live value and nothing runs.
  @Test func backgroundRevokeRunsNothing() async {
    let f = Fixture()
    defer { f.tearDown() }
    f.attach()
    f.pushChange()
    f.setAccess(false)
    #expect(f.library.isAuthorized)
    f.builder.clock.advance(by: 30)
    #expect(f.autoSync.state == .blocked(.photosAccessMissing))
    #expect(f.autoSync.activeRunFanOutTask == nil)
    #expect(f.builder.currentRunStore.saveCount == 0)
    #expect(f.builder.runSummaryStore.saveCount == 0)
    #expect(f.photoLibrary.scopeFetchCalls.isEmpty)
    #expect(f.favorites.pendingAssetIds.contains(f.asset.id))
  }

  /// Access revoked inside a scope, after the refresh before it: a fetch that reports
  /// missing access fails the scope `.failed` with its change kept, not `.completed`. The
  /// next refresh then blocks. The fake reports it here; `PhotoLibraryManager`'s live check
  /// isn't reached under the override service (`PhotoLibraryManagerLiveAuthorizationTests`
  /// covers it).
  @Test func revokeDuringAScopesFetchFailsTheScopeAndTheNextRefreshBlocks() async {
    let f = Fixture()
    defer { f.tearDown() }
    f.attach()
    f.pushChange()
    f.photoLibrary.progressiveStreamOverride = { [weak f] _ in
      f?.setAccess(false)
      return AsyncThrowingStream {
        $0.finish(throwing: PhotoLibraryManager.PhotoLibraryError.authorizationDenied)
      }
    }
    f.builder.clock.advance(by: 30)
    guard case .running = f.autoSync.state else {
      Issue.record("Expected the scheduled run to start, got \(f.autoSync.state)")
      return
    }
    await f.summaries?.waitForCount(1)
    #expect(f.summaries?.summaries.first?.result == .failed)
    #expect(f.library.isAuthorized, "Nothing refreshed the cached flag during the scope.")
    #expect(f.writer.writeCalls.isEmpty)
    #expect(f.collectionStore.placements(matching: .favorites).isEmpty)
    #expect(f.favorites.pendingAssetIds.contains(f.asset.id))
    guard case .scheduled(.photosChanged, _) = f.autoSync.state else {
      Issue.record("Expected the kept change to stay scheduled, got \(f.autoSync.state)")
      return
    }

    f.builder.clock.advance(by: 30)
    #expect(f.autoSync.state == .blocked(.photosAccessMissing))
    #expect(!f.library.isAuthorized)
    #expect(f.autoSync.activeRunFanOutTask == nil)
    #expect(f.builder.runSummaryStore.saveCount == 1)
    #expect(f.builder.clock.pendingCount == 0)
    #expect(f.favorites.pendingAssetIds.contains(f.asset.id))
  }
}
