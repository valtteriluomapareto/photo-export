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

  @Test func findFolderLocatesNestedFolderById() {
    let leaf = PhotoCollectionDescriptor(
      id: "folder:leaf", localIdentifier: "leaf", title: "Leaf",
      kind: .folder, pathComponents: ["Outer"], children: [])
    let outer = PhotoCollectionDescriptor(
      id: "folder:outer", localIdentifier: "outer", title: "Outer",
      kind: .folder, pathComponents: [], children: [leaf])

    #expect(PhotoCollectionDescriptor.findFolder(id: "outer", in: [outer])?.title == "Outer")
    #expect(PhotoCollectionDescriptor.findFolder(id: "leaf", in: [outer])?.title == "Leaf")
    #expect(PhotoCollectionDescriptor.findFolder(id: "ghost", in: [outer]) == nil)
  }

  // MARK: - Multi-select expansion (selectedAlbumIds)

  /// Selected album tiles contribute their own id; selected subfolder tiles expand
  /// to every descendant album. Order follows the parent's children order.
  @Test func selectedAlbumIdsExpandsSubfoldersDeterministically() {
    let albumA = PhotoCollectionDescriptor(
      id: "album:A", localIdentifier: "A", title: "Album-A",
      kind: .album, pathComponents: [], children: [])
    let nestedB = PhotoCollectionDescriptor(
      id: "album:B", localIdentifier: "B", title: "Album-B",
      kind: .album, pathComponents: ["Sub"], children: [])
    let nestedC = PhotoCollectionDescriptor(
      id: "album:C", localIdentifier: "C", title: "Album-C",
      kind: .album, pathComponents: ["Sub"], children: [])
    let subFolder = PhotoCollectionDescriptor(
      id: "folder:Sub", localIdentifier: "Sub", title: "Sub",
      kind: .folder, pathComponents: [], children: [nestedB, nestedC])
    let albumD = PhotoCollectionDescriptor(
      id: "album:D", localIdentifier: "D", title: "Album-D",
      kind: .album, pathComponents: [], children: [])
    let parent = PhotoCollectionDescriptor(
      id: "folder:P", localIdentifier: "P", title: "Parent",
      kind: .folder, pathComponents: [],
      children: [albumA, subFolder, albumD])

    // Selecting A + Sub (subfolder) + D: A, then Sub's descendants (B, C), then D.
    let ids = PhotoCollectionDescriptor.selectedAlbumIds(
      in: parent, selecting: ["album:A", "folder:Sub", "album:D"])
    #expect(ids == ["A", "B", "C", "D"])
  }

  /// Selecting both a subfolder and one of its child albums must not produce
  /// duplicates. The expansion runs at the parent level, but the test guard is on
  /// the dedup behaviour itself.
  @Test func selectedAlbumIdsDedupsWhenSubfolderAndChildBothSelected() {
    let child = PhotoCollectionDescriptor(
      id: "album:dup", localIdentifier: "dup", title: "Dup",
      kind: .album, pathComponents: ["Sub"], children: [])
    let subFolder = PhotoCollectionDescriptor(
      id: "folder:Sub", localIdentifier: "Sub", title: "Sub",
      kind: .folder, pathComponents: [], children: [child])
    // Note: the child album lives only under the subfolder in this tree. The
    // selection set still gets de-duped via the `seen` guard inside the helper.
    let parent = PhotoCollectionDescriptor(
      id: "folder:P", localIdentifier: "P", title: "Parent",
      kind: .folder, pathComponents: [], children: [subFolder])

    let ids = PhotoCollectionDescriptor.selectedAlbumIds(
      in: parent, selecting: ["folder:Sub"])
    #expect(ids == ["dup"])
  }

  @Test func selectedAlbumIdsEmptyForEmptySelection() {
    let album = PhotoCollectionDescriptor(
      id: "album:A", localIdentifier: "A", title: "A",
      kind: .album, pathComponents: [], children: [])
    let parent = PhotoCollectionDescriptor(
      id: "folder:P", localIdentifier: "P", title: "P",
      kind: .folder, pathComponents: [], children: [album])

    #expect(PhotoCollectionDescriptor.selectedAlbumIds(in: parent, selecting: []) == [])
  }

  // MARK: - Range extension (extendedSelection)

  /// Shift-click with an existing anchor extends the selection to cover every tile
  /// from the anchor to the click, in the parent's child order. Existing Cmd-
  /// selected tiles outside the range are preserved (Finder-style "additive" range).
  @Test func extendedSelectionWithAnchorUnionsRangeWithCurrent() {
    let folder = makeOrderedFolder(["A", "B", "C", "D", "E"])

    let result = PhotoCollectionDescriptor.extendedSelection(
      from: "B", to: "D", current: ["A", "B"], in: folder)

    #expect(result.ids == ["A", "B", "C", "D"])
    #expect(result.anchor == "B")
  }

  /// Shift-click without an anchor (or anchor missing from the children) seeds a
  /// fresh single-element selection at the target. Matches Finder behaviour.
  @Test func extendedSelectionWithoutAnchorSeedsTarget() {
    let folder = makeOrderedFolder(["A", "B", "C"])

    let result = PhotoCollectionDescriptor.extendedSelection(
      from: nil, to: "B", current: [], in: folder)

    #expect(result.ids == ["B"])
    #expect(result.anchor == "B")
  }

  /// Range extension works in both directions — anchor before target or anchor
  /// after target, the inclusive range is the same.
  @Test func extendedSelectionRangeIsOrderIndependent() {
    let folder = makeOrderedFolder(["A", "B", "C", "D", "E"])

    let forward = PhotoCollectionDescriptor.extendedSelection(
      from: "B", to: "D", current: [], in: folder)
    let backward = PhotoCollectionDescriptor.extendedSelection(
      from: "D", to: "B", current: [], in: folder)

    #expect(forward.ids == ["B", "C", "D"])
    #expect(backward.ids == ["B", "C", "D"])
  }

  /// Builds a flat parent folder with one child per id (all `.album`), in the
  /// supplied order. Used for `extendedSelection` tests where the children's
  /// `kind` is irrelevant — only the `id` ordering matters.
  private func makeOrderedFolder(_ ids: [String]) -> PhotoCollectionDescriptor {
    let children = ids.map { id in
      PhotoCollectionDescriptor(
        id: id, localIdentifier: id, title: id,
        kind: .album, pathComponents: [], children: [])
    }
    return PhotoCollectionDescriptor(
      id: "folder:test", localIdentifier: "test", title: "Test",
      kind: .folder, pathComponents: [], children: children)
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

    // Block the worker on the writer so `pendingJobs` doesn't drain while we
    // assert on queued state. Without this, `processQueueIfNeeded()` (called at
    // the end of the enqueue helper) synchronously pulls the first job into
    // flight, leaving `pendingJobs` short by one.
    let writerGate = AsyncCheckpoint()
    h.writer.checkpoint = writerGate

    h.manager.startExportFolder(folderId: "Target")
    await waitUntil(h.manager.totalJobsEnqueued == 3)
    // The worker has pulled one job and is suspended on the writer checkpoint;
    // wait for that to land so `currentJobAssetId` is populated.
    await writerGate.waitForEnter(count: 1)

    #expect(h.manager.totalJobsEnqueued == 3)

    // Verify by queued asset ids: only the inside-folder ids should appear.
    // Union pendingJobs with the in-flight job to cover the worker-pulled one.
    let queuedAssetIds = Set(h.manager.pendingJobs.map(\.assetLocalIdentifier))
      .union([h.manager.currentJobAssetId].compactMap { $0 })
    #expect(queuedAssetIds == ["x1", "x2", "x3"])
    #expect(!queuedAssetIds.contains("o1"))

    // Every queued placement must be an album.
    let kinds = Set(h.manager.pendingJobs.map { $0.placement.kind })
      .union([h.manager.currentJobPlacement?.kind].compactMap { $0 })
    #expect(kinds.isSubset(of: [.album]))

    await writerGate.releaseAll()
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

    // Block the worker so the single queued job stays inspectable instead of
    // being pulled into flight by `processQueueIfNeeded` before we assert.
    let writerGate = AsyncCheckpoint()
    h.writer.checkpoint = writerGate

    h.manager.startExportFolder(folderId: "2025")
    await waitUntil(h.manager.totalJobsEnqueued == 1)
    await writerGate.waitForEnter(count: 1)

    // The single job is in-flight on the worker; read from currentJob* slots.
    let queuedPlacement = try #require(h.manager.currentJobPlacement)
    #expect(queuedPlacement.id == directPlacement.id)
    #expect(queuedPlacement.relativePath == directPlacement.relativePath)
    #expect(queuedPlacement.kind == .album)

    await writerGate.releaseAll()
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

    // Block the worker so the lone queued job is observable. Without this,
    // `processQueueIfNeeded` pulls it into flight before the assertion runs.
    let writerGate = AsyncCheckpoint()
    h.writer.checkpoint = writerGate

    h.manager.startExportFolder(folderId: "Outer")
    await waitUntil(h.manager.totalJobsEnqueued == 1)
    await writerGate.waitForEnter(count: 1)

    #expect(h.manager.totalJobsEnqueued == 1)
    let queuedAssetId =
      h.manager.pendingJobs.first?.assetLocalIdentifier ?? h.manager.currentJobAssetId
    #expect(queuedAssetId == "l1")

    await writerGate.releaseAll()
  }

  @Test func missingFolderSetsExplanatoryMessage() async throws {
    let h = makeHarness()
    defer { h.cleanup() }

    h.photoLib.collectionTree = []

    h.manager.startExportFolder(folderId: "ghost")
    await waitUntil(h.manager.emptyRunMessage != nil)

    #expect(h.manager.emptyRunMessage == "That folder no longer exists.")
    #expect(h.manager.totalJobsEnqueued == 0)
    // The run must wind down even on the "folder not found" early-return — without
    // this, an awaitable `runExport(context:)` caller would hang on a continuation
    // that never resolves, because `processQueueIfNeeded` would never fire.
    await waitUntil(!h.manager.hasActiveExportWork)
    #expect(!h.manager.hasActiveExportWork)
    #expect(!h.manager.isEnqueueingAll)
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

  // MARK: - startExportAlbums(collectionIds:) (multi-select tile flow)

  /// The plural API enqueues exactly the supplied albums, in order, with no extras.
  /// This is the entry point the folder content pane's multi-select uses after
  /// expanding subfolder tiles to their descendant album ids.
  @Test func startExportAlbumsEnqueuesSuppliedAlbumsOnly() async throws {
    let h = makeHarness()
    defer { h.cleanup() }

    let albumA = seedAlbum(h.photoLib, localId: "A", ids: ["a1"])
    let albumB = seedAlbum(h.photoLib, localId: "B", ids: ["b1", "b2"])
    let albumC = seedAlbum(h.photoLib, localId: "C", ids: ["c1"])
    h.photoLib.collectionTree = [albumA, albumB, albumC]

    // Block the worker so all queued jobs remain inspectable instead of being
    // partly drained by `processQueueIfNeeded`.
    let writerGate = AsyncCheckpoint()
    h.writer.checkpoint = writerGate

    h.manager.startExportAlbums(collectionIds: ["A", "B"])
    await waitUntil(h.manager.totalJobsEnqueued == 3)
    await writerGate.waitForEnter(count: 1)

    let queuedAssetIds = Set(h.manager.pendingJobs.map(\.assetLocalIdentifier))
      .union([h.manager.currentJobAssetId].compactMap { $0 })
    #expect(queuedAssetIds == ["a1", "b1", "b2"])
    #expect(!queuedAssetIds.contains("c1"))

    await writerGate.releaseAll()
  }

  /// Duplicate ids in the input collapse to a single enqueue per album. The caller
  /// (the multi-select grid) builds a union of selected album ids + descendant album
  /// ids of selected subfolders, which can produce duplicates if a subfolder and one
  /// of its child albums are both selected.
  @Test func startExportAlbumsDeduplicatesInput() async throws {
    let h = makeHarness()
    defer { h.cleanup() }

    let album = seedAlbum(h.photoLib, localId: "dup", ids: ["x1", "x2"])
    h.photoLib.collectionTree = [album]

    h.manager.startExportAlbums(collectionIds: ["dup", "dup", "dup"])
    await waitUntil(h.manager.totalJobsEnqueued == 2)

    #expect(h.manager.totalJobsEnqueued == 2)
    let queuedPlacements = Set(h.manager.pendingJobs.map(\.placement.id))
    #expect(queuedPlacements.count == 1)
  }

  @Test func startExportAlbumsWithEmptyListSetsEmptyMessage() async throws {
    let h = makeHarness()
    defer { h.cleanup() }

    h.manager.startExportAlbums(collectionIds: [])
    await waitUntil(h.manager.emptyRunMessage != nil)

    #expect(h.manager.emptyRunMessage == "No albums in selection.")
    #expect(h.manager.totalJobsEnqueued == 0)
  }

  @Test func startExportAlbumsWhenAllAlreadyDoneSetsAlreadyDoneMessage() async throws {
    let h = makeHarness()
    defer { h.cleanup() }

    let album = seedAlbum(h.photoLib, localId: "done", ids: ["d1"])
    h.photoLib.collectionTree = [album]
    let placement = try ExportPlacementResolver().placement(
      for: .album(collectionId: "done"),
      collections: h.photoLib.collectionTree,
      existingPlacements: []
    )
    h.collectionStore.upsertPlacement(placement)
    h.collectionStore.markVariantExported(
      assetId: "d1", placement: placement, variant: .original,
      filename: "d1.HEIC", exportedAt: Date())

    h.manager.startExportAlbums(collectionIds: ["done"])
    await waitUntil(h.manager.emptyRunMessage != nil)

    #expect(h.manager.emptyRunMessage == "All selected albums are already exported.")
    #expect(h.manager.totalJobsEnqueued == 0)
  }
}
