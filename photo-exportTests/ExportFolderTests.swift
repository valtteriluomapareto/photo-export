import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Coverage for `ExportManager.startExportFolder(folderId:)` and the supporting
/// `PhotoCollectionDescriptor.albumLocalIds(under:)` subtree-walk helper.
///
/// Mirrors the harness shape from `ExportAllAlbumsTests`: a real `ExportManager` plus
/// fakes, a `seedAlbum` helper, and the same `waitUntil` polling utility. The intent
/// is to verify that "export a folder" enqueues exactly the descendant albums and
/// nothing else — non-descendant albums must remain untouched.
@MainActor
struct ExportFolderTests {

  // MARK: - Tree walk

  @Test func albumLocalIdsUnderReturnsOnlyDescendants() {
    let nestedAlbum = PhotoCollectionDescriptor(
      id: "album:nested", localIdentifier: "nested", title: "Nested",
      kind: .album, pathComponents: ["F1"], children: [])
    let deepAlbum = PhotoCollectionDescriptor(
      id: "album:deep", localIdentifier: "deep", title: "Deep",
      kind: .album, pathComponents: ["F1", "F2"], children: [])
    let innerFolder = PhotoCollectionDescriptor(
      id: "folder:F2", localIdentifier: "F2", title: "F2",
      kind: .folder, pathComponents: ["F1"], children: [deepAlbum])
    let folder = PhotoCollectionDescriptor(
      id: "folder:F1", localIdentifier: "F1", title: "F1",
      kind: .folder, pathComponents: [], children: [nestedAlbum, innerFolder])

    let ids = PhotoCollectionDescriptor.albumLocalIds(under: folder)

    #expect(ids == ["nested", "deep"])
  }

  @Test func albumLocalIdsUnderEmptyForLeafAlbum() {
    let album = PhotoCollectionDescriptor(
      id: "album:A", localIdentifier: "A", title: "A",
      kind: .album, pathComponents: [], children: [])
    #expect(PhotoCollectionDescriptor.albumLocalIds(under: album).isEmpty)
  }

  // MARK: - Test harness (parallel to ExportAllAlbumsTests.Harness)

  @MainActor
  private struct Harness {
    let manager: ExportManager
    let photoLib: FakePhotoLibraryService
    let dest: FakeExportDestination
    let writer: FakeAssetResourceWriter
    let timelineStore: ExportRecordStore
    let collectionStore: CollectionExportRecordStore
    let storeRoot: URL
    let userDefaultsSuite: String

    func cleanup() {
      manager.cancelAndClear()
      timelineStore.flushForTesting()
      collectionStore.flushForTesting()
      try? FileManager.default.removeItem(at: storeRoot)
      dest.cleanup()
      UserDefaults().removePersistentDomain(forName: userDefaultsSuite)
    }
  }

  private func makeHarness() -> Harness {
    let photoLib = FakePhotoLibraryService()
    let dest = FakeExportDestination()
    let writer = FakeAssetResourceWriter()
    let fileSystem = FakeFileSystem()
    let storeRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("ExportFolder-\(UUID().uuidString)", isDirectory: true)
    let timelineStore = ExportRecordStore(baseDirectoryURL: storeRoot)
    timelineStore.configure(for: "test")
    let collectionStore = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    collectionStore.configure(for: "test")
    let suiteName = "test-ExportFolder-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let manager = ExportManager(
      photoLibraryService: photoLib,
      exportDestination: dest,
      exportRecordStore: timelineStore,
      collectionExportRecordStore: collectionStore,
      assetResourceWriter: writer,
      fileSystem: fileSystem,
      userDefaults: defaults
    )
    return Harness(
      manager: manager, photoLib: photoLib, dest: dest, writer: writer,
      timelineStore: timelineStore, collectionStore: collectionStore,
      storeRoot: storeRoot, userDefaultsSuite: suiteName)
  }

  private func makeAsset(id: String) -> AssetDescriptor {
    AssetDescriptor(
      id: id, creationDate: Date(timeIntervalSince1970: 1_700_000_000),
      mediaType: .image, pixelWidth: 100, pixelHeight: 100, duration: 0,
      hasAdjustments: false)
  }

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
    timeout: TimeInterval = 10, _ condition: @autoclosure () -> Bool
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
  }

  // MARK: - Enqueue behaviour

  /// Folder export must enqueue every descendant album (including those nested in
  /// subfolders) and *only* those — albums that live outside the chosen folder must
  /// not be touched.
  @Test func enqueuesOnlyDescendantAlbumsAcrossSubfolders() async throws {
    let h = makeHarness()
    defer { h.cleanup() }

    // Inside the target folder: one direct album + one nested under a subfolder.
    let directAlbum = seedAlbum(
      h.photoLib, localId: "in-direct", ids: ["x1", "x2"], pathComponents: ["Target"])
    let nestedAlbum = seedAlbum(
      h.photoLib, localId: "in-nested", ids: ["x3"],
      pathComponents: ["Target", "Sub"])
    let subFolder = PhotoCollectionDescriptor(
      id: "folder:Sub", localIdentifier: "Sub", title: "Sub",
      kind: .folder, pathComponents: ["Target"], children: [nestedAlbum])
    let target = PhotoCollectionDescriptor(
      id: "folder:Target", localIdentifier: "Target", title: "Target",
      kind: .folder, pathComponents: [],
      children: [directAlbum, subFolder])

    // Outside the target folder: a sibling top-level album that must NOT be queued.
    let outsideAlbum = seedAlbum(h.photoLib, localId: "outside", ids: ["o1"])

    h.photoLib.collectionTree = [target, outsideAlbum]

    h.manager.startExportFolder(folderId: "Target")
    await waitUntil(h.manager.totalJobsEnqueued == 3)

    #expect(h.manager.totalJobsEnqueued == 3)

    // Verify by queued asset ids: only the inside-folder ids should appear.
    let queuedAssetIds = Set(h.manager.pendingJobs.map(\.assetLocalIdentifier))
    #expect(queuedAssetIds == ["x1", "x2", "x3"])
    #expect(!queuedAssetIds.contains("o1"))

    // Every queued placement must be an album.
    let kinds = Set(h.manager.pendingJobs.map { $0.placement.kind })
    #expect(kinds.isSubset(of: [.album]))
  }

  /// A descendant album must produce the exact same `ExportPlacement` it would have
  /// produced if the user had opened the album directly and clicked Export Album. This
  /// is the placement-parity guarantee that makes folder export safe to ship without
  /// any storage-format change: the on-disk path comes from `pathComponents` on each
  /// album, so folder-walk and per-album walk are interchangeable.
  @Test func descendantAlbumPlacementIsIdenticalToDirectExport() async throws {
    let h = makeHarness()
    defer { h.cleanup() }

    let nested = seedAlbum(
      h.photoLib, localId: "summer", ids: ["s1"], pathComponents: ["2025"])
    let folder = PhotoCollectionDescriptor(
      id: "folder:2025", localIdentifier: "2025", title: "2025",
      kind: .folder, pathComponents: [], children: [nested])
    h.photoLib.collectionTree = [folder]

    let directPlacement = try ExportPlacementResolver().placement(
      for: .album(collectionId: "summer"),
      collections: h.photoLib.collectionTree,
      existingPlacements: []
    )

    h.manager.startExportFolder(folderId: "2025")
    await waitUntil(h.manager.totalJobsEnqueued == 1)

    let queued = try #require(h.manager.pendingJobs.first)
    #expect(queued.placement.id == directPlacement.id)
    #expect(queued.placement.relativePath == directPlacement.relativePath)
    #expect(queued.placement.kind == .album)
  }

  @Test func emptyFolderSetsNoAlbumsMessage() async throws {
    let h = makeHarness()
    defer { h.cleanup() }

    let empty = PhotoCollectionDescriptor(
      id: "folder:empty", localIdentifier: "empty", title: "Empty",
      kind: .folder, pathComponents: [], children: [])
    h.photoLib.collectionTree = [empty]

    h.manager.startExportFolder(folderId: "empty")
    await waitUntil(h.manager.emptyRunMessage != nil)

    #expect(h.manager.emptyRunMessage == "This folder has no albums to export.")
    #expect(h.manager.totalJobsEnqueued == 0)
  }

  /// A folder containing only subfolders (no direct albums) still walks recursively
  /// and enqueues the deeply-nested albums. Catches a regression where a future
  /// refactor switches from `albumLocalIds(under:)` (recursive) to a one-level lookup.
  @Test func folderWithOnlySubfoldersStillEnqueuesNestedAlbums() async throws {
    let h = makeHarness()
    defer { h.cleanup() }

    let leafAlbum = seedAlbum(
      h.photoLib, localId: "leaf", ids: ["l1"],
      pathComponents: ["Outer", "Inner"])
    let inner = PhotoCollectionDescriptor(
      id: "folder:Inner", localIdentifier: "Inner", title: "Inner",
      kind: .folder, pathComponents: ["Outer"], children: [leafAlbum])
    let outer = PhotoCollectionDescriptor(
      id: "folder:Outer", localIdentifier: "Outer", title: "Outer",
      kind: .folder, pathComponents: [], children: [inner])
    h.photoLib.collectionTree = [outer]

    h.manager.startExportFolder(folderId: "Outer")
    await waitUntil(h.manager.totalJobsEnqueued == 1)

    #expect(h.manager.totalJobsEnqueued == 1)
    #expect(h.manager.pendingJobs.first?.assetLocalIdentifier == "l1")
  }

  @Test func missingFolderSetsExplanatoryMessage() async throws {
    let h = makeHarness()
    defer { h.cleanup() }

    h.photoLib.collectionTree = []

    h.manager.startExportFolder(folderId: "ghost")
    await waitUntil(h.manager.emptyRunMessage != nil)

    #expect(h.manager.emptyRunMessage == "That folder no longer exists.")
    #expect(h.manager.totalJobsEnqueued == 0)
  }

  /// All albums under a folder already fully exported → the user-visible message
  /// distinguishes "this folder is done" from "this folder is empty".
  @Test func allDescendantsAlreadyExportedSetsAlreadyDoneMessage() async throws {
    let h = makeHarness()
    defer { h.cleanup() }

    let album = seedAlbum(
      h.photoLib, localId: "done", ids: ["d1"], pathComponents: ["F"])
    let folder = PhotoCollectionDescriptor(
      id: "folder:F", localIdentifier: "F", title: "F",
      kind: .folder, pathComponents: [], children: [album])
    h.photoLib.collectionTree = [folder]

    let placement = try ExportPlacementResolver().placement(
      for: .album(collectionId: "done"),
      collections: h.photoLib.collectionTree,
      existingPlacements: []
    )
    h.collectionStore.upsertPlacement(placement)
    h.collectionStore.markVariantExported(
      assetId: "d1", placement: placement, variant: .original,
      filename: "d1.HEIC", exportedAt: Date())

    h.manager.startExportFolder(folderId: "F")
    await waitUntil(h.manager.emptyRunMessage != nil)

    #expect(
      h.manager.emptyRunMessage == "All albums in this folder are already exported.")
    #expect(h.manager.totalJobsEnqueued == 0)
  }
}
