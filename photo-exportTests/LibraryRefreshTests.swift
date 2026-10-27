import Foundation
import Testing

@testable import Photo_Export

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct LibraryRefreshTests {
  private let first = PhotoLibraryQuery(scope: .timeline(year: 2026, month: 9))
  private let second = PhotoLibraryQuery(scope: .favorites)

  @Test func burstsDebounceConsumersWithoutChangingSourceOrContentRevisions() {
    let clock = TestClock()
    let service = FakePhotoLibraryService()
    let library = PhotoLibraryManager(overrideService: service, refreshClock: clock)
    library.beginObservingQuery(first)
    library.beginObservingQuery(second)
    let source = ObservationProbe { _ = library.libraryRevision }
    for _ in 0..<5 {
      library.invalidateCache(
        changedThumbnailAssetIDs: [], queryChanges: [first: true, second: false])
    }
    #expect(library.libraryRevision == 5)
    #expect(source.changeCount == 5)
    #expect(library.thumbnailContentRevision(for: "A") == 0)
    #expect(library.libraryRefresh.revision == 0)
    clock.advance(by: 0.499)
    #expect(library.libraryRefresh.revision == 0)
    clock.advance(by: 0.001)
    #expect(library.libraryRefresh.revision == 1)
    #expect(library.libraryRefresh.queryRevision(for: first) == 1)
    #expect(library.libraryRefresh.queryRevision(for: second) == 0)
    library.endObservingQuery(first)
    library.endObservingQuery(second)
  }

  @Test func queryChangesMergeConservativelyAndMediaFiltersRemainDistinct() {
    let clock = TestClock()
    let service = FakePhotoLibraryService()
    let library = PhotoLibraryManager(overrideService: service, refreshClock: clock)
    let imageQuery = PhotoLibraryQuery(scope: .favorites, mediaType: .image)
    let videoQuery = PhotoLibraryQuery(scope: .favorites, mediaType: .video)
    for query in [first, imageQuery, videoQuery] { library.beginObservingQuery(query) }
    library.invalidateCache(
      changedThumbnailAssetIDs: [],
      queryChanges: [first: false, imageQuery: true, videoQuery: false])
    library.invalidateCache(
      changedThumbnailAssetIDs: [],
      queryChanges: [first: false, imageQuery: false, videoQuery: false])
    library.libraryRefresh.flush()
    #expect(library.libraryRefresh.queryRevision(for: first) == 0)
    #expect(library.libraryRefresh.queryRevision(for: imageQuery) == 1)
    #expect(library.libraryRefresh.queryRevision(for: videoQuery) == 0)
    library.invalidateCache(changedThumbnailAssetIDs: [], queryChanges: [first: false])
    library.invalidateCache(changedThumbnailAssetIDs: [])
    library.libraryRefresh.flush()
    for query in [first, imageQuery, videoQuery] {
      #expect(library.libraryRefresh.queryRevision(for: query) > 0)
      library.endObservingQuery(query)
    }
    #expect(clock.pendingCount == 0)
  }

  @Test(arguments: [false, true])
  func obsoleteInventoryCannotInstallAfterANewerSourceRevision(tree: Bool) async {
    let clock = TestClock()
    let service = FakePhotoLibraryService()
    let library = PhotoLibraryManager(overrideService: service, refreshClock: clock)
    let gate = AsyncCheckpoint()
    service.yearCounts = [(2025, 1)]
    service.collectionTree = [
      PhotoCollectionDescriptor(
        id: "old", localIdentifier: "old", title: "Old", kind: .album, pathComponents: [],
        children: [])
    ]
    service.inventoryCheckpoint = gate
    let old = Task {
      if tree {
        await library.libraryRefresh.loadTree()
      } else {
        await library.libraryRefresh.loadYears()
      }
    }
    await gate.waitForEnter(count: 1)
    service.inventoryCheckpoint = nil
    service.yearCounts = [(2026, 2)]
    service.collectionTree = [
      PhotoCollectionDescriptor(
        id: "new", localIdentifier: "new", title: "New", kind: .album, pathComponents: [],
        children: [])
    ]
    library.invalidateCache(changedThumbnailAssetIDs: [])
    library.libraryRefresh.flush()
    if tree {
      await library.libraryRefresh.loadTree()
    } else {
      await library.libraryRefresh.loadYears()
    }
    await gate.releaseAll()
    await old.value
    if tree {
      #expect(library.libraryRefresh.tree?.map(\.title) == ["New"])
    } else {
      #expect(library.libraryRefresh.years == [PhotoLibraryYearCount(year: 2026, count: 2)])
    }
  }

  @Test(arguments: [false, true])
  func authoritativeTreeRejectsObsoleteSourceAndHonorsCancellation(cancel: Bool) async throws {
    let service = FakePhotoLibraryService()
    let library = PhotoLibraryManager(overrideService: service, refreshClock: TestClock())
    func album(_ id: String) -> PhotoCollectionDescriptor {
      PhotoCollectionDescriptor(
        id: id, localIdentifier: id, title: id, kind: .album, pathComponents: [], children: [])
    }
    service.collectionTree = [album("old")]
    let gate = AsyncCheckpoint()
    service.inventoryCheckpoint = gate
    let load = Task { try await library.loadCollectionTree() }
    await gate.waitForEnter(count: 1)
    service.inventoryCheckpoint = nil
    service.collectionTree = [album("current")]
    library.invalidateCache(changedThumbnailAssetIDs: [])
    if cancel { load.cancel() }
    await gate.releaseAll()
    do {
      let tree = try await load.value
      #expect(!cancel)
      #expect(tree.map(\.title) == ["current"])
    } catch {
      #expect(cancel && error is CancellationError)
    }
  }

  @Test func activeFolderExportRetriesChangedMembershipBeforeEnqueuing() async throws {
    let h = await ExportManagerHarness(label: "LibraryRefreshCoreScope")
    let library = PhotoLibraryManager(overrideService: h.photoLib, refreshClock: TestClock())
    let manager = ExportManager(
      photoLibraryService: library, exportDestination: h.dest, exportRecordStore: h.store,
      collectionExportRecordStore: h.collectionStore, assetResourceWriter: h.writer,
      fileSystem: h.fileSystem, userDefaults: h.defaults)
    func tree(_ member: String) -> [PhotoCollectionDescriptor] {
      [
        PhotoCollectionDescriptor(
          id: "folder:F", localIdentifier: "F", title: "Folder", kind: .folder,
          pathComponents: [],
          children: [
            PhotoCollectionDescriptor(
              id: "album:\(member)", localIdentifier: member, title: member, kind: .album,
              pathComponents: ["Folder"], children: [])
          ])
      ]
    }
    h.photoLib.collectionTree = tree("old")
    h.photoLib.assetsByAlbumLocalId["current"] = [TestAssetFactory.makeAsset(id: "current")]
    h.photoLib.resourcesByAssetId["current"] = [
      ResourceDescriptor(type: .photo, originalFilename: "current.jpg")
    ]
    let gate = AsyncCheckpoint()
    h.photoLib.inventoryCheckpoint = gate
    manager.queueCoordinator.pause()
    manager.startExportFolder(folderId: "F")
    let preparations = manager.currentPreparationTasks
    await gate.waitForEnter(count: 1)
    h.photoLib.collectionTree = tree("current")
    h.photoLib.inventoryCheckpoint = nil
    library.invalidateCache(changedThumbnailAssetIDs: [])
    await gate.releaseAll()
    for task in preparations { await task.value }
    #expect(manager.pendingJobs.map(\.assetLocalIdentifier) == ["current"])
    manager.cancelAndClear()
    h.store.drainSynchronously()
    h.collectionStore.drainSynchronously()
    h.dest.cleanup()
    try? FileManager.default.removeItem(at: h.storeRoot)
  }

  @Test func queryRegistrationRejectsLateResultsAndBalancesMultipleConsumers() {
    let store = PhotoLibraryQueryObservations<String>()
    store.begin(first)
    store.begin(first)
    let old = store.ticket(for: first, revision: 1)!
    let current = store.ticket(for: first, revision: 1)!
    #expect(!store.install("old", for: old, revision: 1))
    #expect(store.install("new", for: current, revision: 1))
    store.end(first)
    #expect(store.snapshots[first] == "new")
    store.end(first)
    #expect(store.snapshots.isEmpty)
    #expect(!store.install("late", for: current, revision: 1))
    store.begin(first)
    let stale = store.ticket(for: first, revision: 1)!
    #expect(!store.install("stale-revision", for: stale, revision: 2))
    store.end(first)
  }
  @Test(arguments: [false, true])
  func heldQueryOnlyRejectsChangesThatAffectItsPredicate(affected: Bool) async {
    let clock = TestClock()
    let service = FakePhotoLibraryService()
    let library = PhotoLibraryManager(overrideService: service, refreshClock: clock)
    library.beginObservingQuery(first)
    let source = library.libraryRefresh.sourceRevision(for: first)
    let stream = AsyncThrowingStream<[AssetDescriptor], any Error>.makeStream()
    let started = AsyncStream<Void>.makeStream()
    service.progressiveStreamOverride = { _ in
      started.continuation.yield(())
      return stream.stream
    }
    let model = MonthViewModel(photoLibraryService: service)
    let load = Task {
      await model.loadAssets(
        for: first.scope,
        isCurrent: {
          library.libraryRefresh.sourceRevision(for: first) == source
        })
    }
    var startedIterator = started.stream.makeAsyncIterator()
    _ = await startedIterator.next()
    started.continuation.finish()
    library.invalidateCache(changedThumbnailAssetIDs: [], queryChanges: [first: affected])
    let asset = TestAssetFactory.makeAsset(id: "late")
    stream.continuation.yield([asset])
    stream.continuation.finish()
    await load.value
    #expect(model.assets == (affected ? [] : [asset]))
    #expect(model.hasCompleteSnapshot == !affected)
    library.libraryRefresh.flush()
    model.deactivate()
    library.endObservingQuery(first)
  }

  @Test func screenshotInventoryAsyncSeamsReturnSyntheticValues() async throws {
    let service = ScreenshotPhotoLibraryService()
    #expect(try await !service.loadYearsWithCounts().isEmpty)
    #expect(try await service.loadCollectionTree().contains { $0.kind == .favorites })
  }

}
