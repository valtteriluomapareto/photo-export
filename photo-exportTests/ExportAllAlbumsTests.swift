import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Coverage for `ExportManager.startExportAllAlbums()` and the supporting
/// `PhotoCollectionDescriptor.albumLocalIds(in:)` tree-walk helper.
@MainActor
struct ExportAllAlbumsTests {

  // MARK: - Tree walk

  @Test func albumLocalIdsCollectsTopLevelAndNestedAlbumsExcludingFavorites() {
    let tree: [PhotoCollectionDescriptor] = [
      PhotoCollectionDescriptor(
        id: "favorites", localIdentifier: nil, title: "Favorites",
        kind: .favorites, pathComponents: [], children: []),
      PhotoCollectionDescriptor(
        id: "album:top-A", localIdentifier: "top-A", title: "Top A",
        kind: .album, pathComponents: [], children: []),
      PhotoCollectionDescriptor(
        id: "folder:F1", localIdentifier: "F1", title: "Folder 1",
        kind: .folder, pathComponents: [],
        children: [
          PhotoCollectionDescriptor(
            id: "album:nested-B", localIdentifier: "nested-B", title: "Nested B",
            kind: .album, pathComponents: ["Folder 1"], children: []),
          PhotoCollectionDescriptor(
            id: "folder:F2", localIdentifier: "F2", title: "Folder 2",
            kind: .folder, pathComponents: ["Folder 1"],
            children: [
              PhotoCollectionDescriptor(
                id: "album:deep-C", localIdentifier: "deep-C", title: "Deep C",
                kind: .album, pathComponents: ["Folder 1", "Folder 2"],
                children: [])
            ]),
        ]),
    ]

    let ids = PhotoCollectionDescriptor.albumLocalIds(in: tree)

    #expect(ids == ["top-A", "nested-B", "deep-C"])
  }

  @Test func albumLocalIdsReturnsEmptyForFavoritesOnlyTree() {
    let tree: [PhotoCollectionDescriptor] = [
      PhotoCollectionDescriptor(
        id: "favorites", localIdentifier: nil, title: "Favorites",
        kind: .favorites, pathComponents: [], children: [])
    ]
    #expect(PhotoCollectionDescriptor.albumLocalIds(in: tree).isEmpty)
  }

  // MARK: - Test harness

  private struct Harness {
    let manager: ExportManager
    let photoLib: FakePhotoLibraryService
    let dest: FakeExportDestination
    let collectionStore: CollectionExportRecordStore
    let storeRoot: URL
  }

  private func makeHarness() -> Harness {
    let photoLib = FakePhotoLibraryService()
    let dest = FakeExportDestination()
    let writer = FakeAssetResourceWriter()
    let fileSystem = FakeFileSystem()
    let storeRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("ExportAllAlbums-\(UUID().uuidString)", isDirectory: true)
    let timelineStore = ExportRecordStore(baseDirectoryURL: storeRoot)
    timelineStore.configure(for: "test")
    let collectionStore = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    collectionStore.configure(for: "test")
    UserDefaults.standard.removeObject(forKey: ExportManager.versionSelectionDefaultsKey)
    let manager = ExportManager(
      photoLibraryService: photoLib,
      exportDestination: dest,
      exportRecordStore: timelineStore,
      collectionExportRecordStore: collectionStore,
      assetResourceWriter: writer,
      fileSystem: fileSystem
    )
    return Harness(
      manager: manager, photoLib: photoLib, dest: dest,
      collectionStore: collectionStore, storeRoot: storeRoot)
  }

  private func makeAsset(id: String) -> AssetDescriptor {
    AssetDescriptor(
      id: id, creationDate: Date(timeIntervalSince1970: 1_700_000_000),
      mediaType: .image, pixelWidth: 100, pixelHeight: 100, duration: 0,
      hasAdjustments: false)
  }

  /// Adds a top-level album with `ids` assets. Mirrors the seeding helper in
  /// QueueStateAcrossModesTests.
  private func seedAlbum(
    _ photoLib: FakePhotoLibraryService, localId: String, ids: [String],
    pathComponents: [String] = []
  ) -> PhotoCollectionDescriptor {
    let assets = ids.map { makeAsset(id: $0) }
    photoLib.assetsByAlbumLocalId[localId] = assets
    for asset in assets {
      photoLib.resourcesByAssetId[asset.id] = [
        ResourceDescriptor(type: .photo, originalFilename: "\(asset.id).HEIC")
      ]
    }
    return PhotoCollectionDescriptor(
      id: "album:\(localId)", localIdentifier: localId, title: "Album-\(localId)",
      kind: .album, pathComponents: pathComponents, children: [])
  }

  private func waitUntil(
    timeout: TimeInterval = 3, _ condition: @autoclosure () -> Bool
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
  }

  // MARK: - Enqueue behaviour

  /// Top-level albums and albums nested under folders both reach the queue.
  /// Favorites assets are present in the canned data but are NOT enqueued
  /// because the batch is albums-only.
  @Test func enqueuesEveryAlbumIncludingNestedAndExcludesFavorites() async throws {
    let h = makeHarness()
    defer {
      try? FileManager.default.removeItem(at: h.storeRoot)
      h.dest.cleanup()
    }

    let topAlbum = seedAlbum(h.photoLib, localId: "top-A", ids: ["a1", "a2"])
    let nestedAlbum = seedAlbum(
      h.photoLib, localId: "nested-B", ids: ["b1"], pathComponents: ["F1"])

    // Favorites is canonically present in the tree built by PhotoLibraryManager;
    // include it here so the test verifies the batch ignores it. Seed favorites
    // assets too — if the batch incorrectly routed favorites we'd see them in
    // the enqueued count.
    let favorites = PhotoCollectionDescriptor(
      id: "favorites", localIdentifier: nil, title: "Favorites",
      kind: .favorites, pathComponents: [], children: [])
    let favAsset = makeAsset(id: "fav1")
    h.photoLib.favoritesAssets = [favAsset]
    h.photoLib.resourcesByAssetId["fav1"] = [
      ResourceDescriptor(type: .photo, originalFilename: "fav1.HEIC")
    ]

    let folder = PhotoCollectionDescriptor(
      id: "folder:F1", localIdentifier: "F1", title: "F1",
      kind: .folder, pathComponents: [], children: [nestedAlbum])

    h.photoLib.collectionTree = [favorites, topAlbum, folder]

    h.manager.startExportAllAlbums()
    await waitUntil(h.manager.totalJobsEnqueued == 3)

    #expect(h.manager.totalJobsEnqueued == 3)

    // Every queued placement must be an album — never `.favorites` or `.timeline`.
    let kinds = Set(h.manager.pendingJobs.map { $0.placement.kind })
    #expect(kinds.isSubset(of: [.album]))
  }

  @Test func emptyAlbumTreeSetsNoAlbumsMessage() async throws {
    let h = makeHarness()
    defer {
      try? FileManager.default.removeItem(at: h.storeRoot)
      h.dest.cleanup()
    }

    h.photoLib.collectionTree = [
      PhotoCollectionDescriptor(
        id: "favorites", localIdentifier: nil, title: "Favorites",
        kind: .favorites, pathComponents: [], children: [])
    ]

    h.manager.startExportAllAlbums()
    await waitUntil(h.manager.emptyRunMessage != nil)

    #expect(h.manager.emptyRunMessage == "No albums to export.")
    #expect(h.manager.totalJobsEnqueued == 0)
  }

  /// A throw partway through the album loop must not strand earlier albums' jobs in
  /// `pendingJobs` with no active processor. The catch path drains what was queued and
  /// surfaces the partial state via the empty-run message slot.
  @Test func partialEnqueueFailureDrainsTheJobsAlreadyQueued() async throws {
    let h = makeHarness()
    defer {
      try? FileManager.default.removeItem(at: h.storeRoot)
      h.dest.cleanup()
    }

    let albumA = seedAlbum(h.photoLib, localId: "album-A", ids: ["a1", "a2"])
    let albumB = seedAlbum(h.photoLib, localId: "broken-album", ids: ["b1"])
    h.photoLib.collectionTree = [albumA, albumB]
    h.photoLib.fetchAssetsErrorByAlbumId["broken-album"] = NSError(
      domain: "Test", code: 7, userInfo: [NSLocalizedDescriptionKey: "boom"])

    h.manager.startExportAllAlbums()
    await waitUntil(h.manager.totalJobsCompleted == 2)

    // Album A's two jobs were already queued before B threw. They must drain
    // (totalJobsCompleted reaches 2) and the queue empties.
    #expect(h.manager.totalJobsCompleted == 2)
    #expect(h.manager.queueCount == 0)
    #expect(!h.manager.isEnqueueingAll)
    // The partial-failure message lands in the empty-run slot.
    #expect(
      h.manager.emptyRunMessage
        == "Couldn't list every album. Continuing with the photos already queued.")
  }

  @Test func allAlbumsAlreadyExportedSetsAlreadyDoneMessage() async throws {
    let h = makeHarness()
    defer {
      try? FileManager.default.removeItem(at: h.storeRoot)
      h.dest.cleanup()
    }

    let album = seedAlbum(h.photoLib, localId: "done-album", ids: ["d1"])
    h.photoLib.collectionTree = [album]

    // Pre-populate the collection store via the same resolver `enqueueCollection`
    // uses, so the placement id matches what the enqueue path will compute.
    let placement = try ExportPlacementResolver().placement(
      for: .album(collectionId: "done-album"),
      collections: h.photoLib.collectionTree,
      existingPlacements: []
    )
    h.collectionStore.upsertPlacement(placement)
    // Asset has `hasAdjustments: false`, so `.edited` selection mode requires
    // the `.original` variant only.
    h.collectionStore.markVariantExported(
      assetId: "d1", placement: placement, variant: .original,
      filename: "d1.HEIC", exportedAt: Date())

    h.manager.startExportAllAlbums()
    await waitUntil(h.manager.emptyRunMessage != nil)

    #expect(
      h.manager.emptyRunMessage == "All albums in this destination are already exported.")
    #expect(h.manager.totalJobsEnqueued == 0)
  }
}
