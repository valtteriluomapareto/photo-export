import Foundation
import Testing

@testable import Photo_Export

/// Integration tests for `ExportCleanupCoordinator` — the Cleanup options'
/// disk/record-store passes — driven through a fully-wired `ExportManager`
/// harness so the real record stores, router, destination, and filesystem seams
/// participate.
@MainActor
struct ExportCleanupCoordinatorTests {

  @MainActor
  private struct Harness {
    let manager: ExportManager
    let photoLib: FakePhotoLibraryService
    let dest: FakeExportDestination
    let fileSystem: FakeFileSystem
    let store: ExportRecordStore
    let collectionStore: CollectionExportRecordStore
    let storeRoot: URL
    let userDefaultsSuite: String

    func cleanup() async {
      manager.cancelAndClear()
      store.flushForTesting()
      collectionStore.flushForTesting()
      try? FileManager.default.removeItem(at: storeRoot)
      dest.cleanup()
      UserDefaults().removePersistentDomain(forName: userDefaultsSuite)
    }
  }

  private func makeHarness() -> Harness {
    let photoLib = FakePhotoLibraryService()
    let dest = FakeExportDestination()
    let fileSystem = FakeFileSystem()
    let storeRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("ExportCleanup-\(UUID().uuidString)", isDirectory: true)
    let store = ExportRecordStore(baseDirectoryURL: storeRoot)
    store.configure(for: "test")
    let collectionStore = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    collectionStore.configure(for: "test")
    let suiteName = "test-ExportCleanup-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let manager = ExportManager(
      photoLibraryService: photoLib,
      exportDestination: dest,
      exportRecordStore: store,
      collectionExportRecordStore: collectionStore,
      fileSystem: fileSystem,
      userDefaults: defaults
    )
    return Harness(
      manager: manager, photoLib: photoLib, dest: dest, fileSystem: fileSystem,
      store: store, collectionStore: collectionStore,
      storeRoot: storeRoot, userDefaultsSuite: suiteName)
  }

  private func writeFile(_ url: URL, content: String = "fake") throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try content.write(to: url, atomically: true, encoding: .utf8)
  }

  // MARK: - Remove deleted files (timeline month scope)

  @Test func timelineMonthScopeDeletesMissingAssetFileAndRecord() async throws {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }

    let oldDate = Date(timeIntervalSince1970: 100)
    harness.store.markVariantExported(
      assetId: "gone", variant: .original, year: 2025, month: 2,
      relPath: "2025/02/", filename: "GONE.HEIC", exportedAt: oldDate)
    harness.store.markVariantExported(
      assetId: "kept", variant: .original, year: 2025, month: 2,
      relPath: "2025/02/", filename: "KEPT.HEIC", exportedAt: oldDate)
    try writeFile(harness.dest.rootURL.appendingPathComponent("2025/02/GONE.HEIC"))
    try writeFile(harness.dest.rootURL.appendingPathComponent("2025/02/KEPT.HEIC"))

    let summary = await harness.manager.cleanupCoordinator.removeDeletedAssets(
      in: .timelineMonth(year: 2025, month: 2, existingAssetIds: ["kept"]), generation: 0)

    #expect(summary.removedFiles == 1)
    #expect(summary.removedRecords == 1)
    #expect(!FileManager.default.fileExists(
      atPath: harness.dest.rootURL.appendingPathComponent("2025/02/GONE.HEIC").path))
    #expect(FileManager.default.fileExists(
      atPath: harness.dest.rootURL.appendingPathComponent("2025/02/KEPT.HEIC").path))
    #expect(harness.store.exportInfo(assetId: "gone") == nil)
    #expect(harness.store.exportInfo(assetId: "kept") != nil)
  }

  // MARK: - Remove deleted files (timeline year scope, month drift)

  @Test func timelineYearScopeDetectsMonthDrift() async throws {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }

    let oldDate = Date(timeIntervalSince1970: 100)
    // "drifted" was exported to January but the library now reports it in March.
    harness.store.markVariantExported(
      assetId: "drifted", variant: .original, year: 2025, month: 1,
      relPath: "2025/01/", filename: "DRIFTED.HEIC", exportedAt: oldDate)
    // "stable" stayed in January.
    harness.store.markVariantExported(
      assetId: "stable", variant: .original, year: 2025, month: 1,
      relPath: "2025/01/", filename: "STABLE.HEIC", exportedAt: oldDate)
    try writeFile(harness.dest.rootURL.appendingPathComponent("2025/01/DRIFTED.HEIC"))
    try writeFile(harness.dest.rootURL.appendingPathComponent("2025/01/STABLE.HEIC"))

    let summary = await harness.manager.cleanupCoordinator.removeDeletedAssets(
      in: .timelineYear(
        year: 2025,
        existingAssetIds: ["drifted", "stable"],
        existingAssetIdsByMonth: [1: ["stable"], 3: ["drifted"]]),
      generation: 0)

    #expect(summary.removedRecords == 1)
    #expect(harness.store.exportInfo(assetId: "drifted") == nil)
    #expect(harness.store.exportInfo(assetId: "stable") != nil)
    #expect(!FileManager.default.fileExists(
      atPath: harness.dest.rootURL.appendingPathComponent("2025/01/DRIFTED.HEIC").path))
    #expect(FileManager.default.fileExists(
      atPath: harness.dest.rootURL.appendingPathComponent("2025/01/STABLE.HEIC").path))
  }

  // MARK: - Remove deleted files (collection scope)

  @Test func collectionScopeDeletesRemovedAlbumMembers() async throws {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }

    let placement = ExportPlacement(
      kind: .album, id: "collections:album:abc:123", displayName: "Trip",
      collectionLocalIdentifier: "album-1", relativePath: "Collections/Albums/Trip/",
      createdAt: Date())
    harness.collectionStore.upsertPlacement(placement)
    let oldDate = Date(timeIntervalSince1970: 100)
    harness.collectionStore.markVariantExported(
      assetId: "removed-from-album", placement: placement, variant: .original,
      filename: "REMOVED.HEIC", exportedAt: oldDate)
    harness.collectionStore.markVariantExported(
      assetId: "still-member", placement: placement, variant: .original,
      filename: "MEMBER.HEIC", exportedAt: oldDate)
    try writeFile(
      harness.dest.rootURL.appendingPathComponent("Collections/Albums/Trip/REMOVED.HEIC"))
    try writeFile(
      harness.dest.rootURL.appendingPathComponent("Collections/Albums/Trip/MEMBER.HEIC"))

    let summary = await harness.manager.cleanupCoordinator.removeDeletedAssets(
      in: .collection(placement: placement, existingAssetIds: ["still-member"]), generation: 0)

    #expect(summary.removedFiles == 1)
    #expect(summary.removedRecords == 1)
    #expect(!FileManager.default.fileExists(
      atPath: harness.dest.rootURL.appendingPathComponent("Collections/Albums/Trip/REMOVED.HEIC")
        .path))
    #expect(FileManager.default.fileExists(
      atPath: harness.dest.rootURL.appendingPathComponent("Collections/Albums/Trip/MEMBER.HEIC")
        .path))
    #expect(
      harness.collectionStore.exportInfo(assetId: "removed-from-album", placement: placement)
        == nil)
  }

  // MARK: - Remove empty albums

  @Test func staleAlbumPlacementIsRemovedWithFolderFilesAndRecords() async throws {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }

    // Tree contains a different album only — the "Trip" placement (any id
    // shape) is stale because its collection id is absent from the tree.
    let placement = ExportPlacement(
      kind: .album, id: "collections:album:abc:123", displayName: "Trip",
      collectionLocalIdentifier: "album-1", relativePath: "Collections/Albums/Trip/",
      createdAt: Date())
    harness.collectionStore.upsertPlacement(placement)
    harness.collectionStore.markVariantExported(
      assetId: "asset-in-trip", placement: placement, variant: .original,
      filename: "TRIP.HEIC", exportedAt: Date(timeIntervalSince1970: 100))
    try writeFile(
      harness.dest.rootURL.appendingPathComponent("Collections/Albums/Trip/TRIP.HEIC"))

    let liveAlbum = PhotoCollectionDescriptor(
      id: "album:album-2", localIdentifier: "album-2", title: "Stay", kind: .album,
      pathComponents: [], children: [])
    let summary = await harness.manager.cleanupCoordinator.removeStaleAlbumPlacements(
      candidates: [placement], tree: [liveAlbum], ancestorCeiling: "Collections", generation: 0)

    #expect(summary.removedFiles == 1)
    #expect(summary.removedFolders == 3, "Trip folder + empty Collections/Albums + Collections")
    #expect(summary.removedRecords == 1)
    #expect(!FileManager.default.fileExists(
      atPath: harness.dest.rootURL.appendingPathComponent("Collections/Albums/Trip").path))
    #expect(harness.collectionStore.placement(id: placement.id) == nil)
    #expect(
      harness.collectionStore.exportInfo(assetId: "asset-in-trip", placement: placement) == nil)
  }

  @Test func liveAlbumPlacementIsKept() async throws {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }

    // The live album's placement must carry the id the resolver would
    // compute for its CURRENT path — that's what "live" means under the
    // stale-path check (a moved/renamed album computes a different id).
    let liveAlbum = PhotoCollectionDescriptor(
      id: "album:album-1", localIdentifier: "album-1", title: "Trip", kind: .album,
      pathComponents: [], children: [])
    let liveId = try #require(ExportPlacementResolver.candidatePlacementId(for: liveAlbum))
    let placement = ExportPlacement(
      kind: .album, id: liveId, displayName: "Trip",
      collectionLocalIdentifier: "album-1", relativePath: "Collections/Albums/Trip/",
      createdAt: Date())
    harness.collectionStore.upsertPlacement(placement)
    harness.collectionStore.markVariantExported(
      assetId: "asset-in-trip", placement: placement, variant: .original,
      filename: "TRIP.HEIC", exportedAt: Date(timeIntervalSince1970: 100))
    try writeFile(
      harness.dest.rootURL.appendingPathComponent("Collections/Albums/Trip/TRIP.HEIC"))

    let summary = await harness.manager.cleanupCoordinator.removeStaleAlbumPlacements(
      candidates: [placement], tree: [liveAlbum], ancestorCeiling: nil, generation: 0)

    #expect(summary.isEmpty)
    #expect(harness.collectionStore.placement(id: placement.id) != nil)
  }

  // MARK: - Folder-structure cleanup (empty-directory half)

  @Test func emptyFoldersRemovedBottomUpWithinScopedSubtrees() async throws {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }

    // Empty month folder chain; a folder with a file; a nested empty album folder.
    try FileManager.default.createDirectory(
      at: harness.dest.rootURL.appendingPathComponent("2025/01"),
      withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: harness.dest.rootURL.appendingPathComponent("2026/03"),
      withIntermediateDirectories: true)
    try writeFile(harness.dest.rootURL.appendingPathComponent("2026/03/KEEP.HEIC"))
    try FileManager.default.createDirectory(
      at: harness.dest.rootURL.appendingPathComponent("Collections/Albums/Gone"),
      withIntermediateDirectories: true)

    let summary = await harness.manager.cleanupCoordinator.removeEmptyFolders(
      scopes: [
        .init(subtree: "2025", ancestorCeiling: nil),
        .init(subtree: "2026/03", ancestorCeiling: nil),
        .init(subtree: "Collections", ancestorCeiling: nil),
      ], generation: 0)

    // Empty chains collapse *within the passed subtrees*: 2025/01 → 2025 (2),
    // Collections/Albums/Gone → Albums → Collections (3). The file-bearing
    // 2026/03 stays. Outside subtrees nothing is touched.
    #expect(summary.removedFolders == 5)
    #expect(!FileManager.default.fileExists(
      atPath: harness.dest.rootURL.appendingPathComponent("2025").path))
    #expect(FileManager.default.fileExists(
      atPath: harness.dest.rootURL.appendingPathComponent("2026/03/KEEP.HEIC").path))
    #expect(!FileManager.default.fileExists(
      atPath: harness.dest.rootURL.appendingPathComponent("Collections").path))
    #expect(harness.dest.rootURL.doesDirectoryExist)
  }

  /// Regression: Finder writes a `.DS_Store` the moment the user browses the
  /// backup — a browsed folder must still qualify as empty (the hidden
  /// metadata is deleted with it). This is why browsed `Collections/Favorites`
  /// or album folders used to persist.
  @Test func dotfileOnlyFoldersCountAsEmpty() async throws {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }

    try FileManager.default.createDirectory(
      at: harness.dest.rootURL.appendingPathComponent("2025/01"),
      withIntermediateDirectories: true)
    try writeFile(harness.dest.rootURL.appendingPathComponent("2025/01/.DS_Store"))
    try FileManager.default.createDirectory(
      at: harness.dest.rootURL.appendingPathComponent("Collections/Albums/Familie"),
      withIntermediateDirectories: true)
    try writeFile(harness.dest.rootURL.appendingPathComponent("Collections/Albums/Familie/.DS_Store"))

    // A full-library-style reconcile: the month has no ceiling above it, the
    // collection subtree may prune up to (and including) `Collections`.
    let summary = await harness.manager.cleanupCoordinator.removeEmptyFolders(
      scopes: [
        .init(subtree: "2025/01", ancestorCeiling: nil),
        .init(subtree: "Collections/Albums/Familie", ancestorCeiling: "Collections"),
      ], generation: 0)

    // 2025/01, Familie + Collections/Albums + Collections (ceiling inclusive).
    #expect(summary.removedFolders == 4)
    #expect(
      FileManager.default.fileExists(
        atPath: harness.dest.rootURL.appendingPathComponent("2025").path),
      "the year folder is above the month scope's ceiling and must survive")
    #expect(!FileManager.default.fileExists(
      atPath: harness.dest.rootURL.appendingPathComponent("Collections").path))
  }

  /// Deletion ceilings: a month scope (no ancestor ceiling) never removes its
  /// year folder; a scope with an ancestor ceiling prunes exactly up to it.
  /// Other scopes' areas are never touched.
  @Test func emptyFolderWalkRespectsDeletionCeilings() async throws {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }

    try FileManager.default.createDirectory(
      at: harness.dest.rootURL.appendingPathComponent("2025/01"),
      withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: harness.dest.rootURL.appendingPathComponent("Collections/Albums/Ghost"),
      withIntermediateDirectories: true)

    // A timeline month run's scope is only its own month folder — the year
    // umbrella above it stays even when empty (month = max deletion node).
    let summary = await harness.manager.cleanupCoordinator.removeEmptyFolders(
      scopes: [.init(subtree: "2025/01", ancestorCeiling: nil)], generation: 0)

    #expect(summary.removedFolders == 1)
    #expect(
      FileManager.default.fileExists(
        atPath: harness.dest.rootURL.appendingPathComponent("2025").path),
      "the year folder is above a month run's deletion ceiling and must survive")
    #expect(
      FileManager.default.fileExists(
        atPath: harness.dest.rootURL.appendingPathComponent("Collections/Albums/Ghost").path),
      "album areas are outside a timeline run's scope and must stay untouched")

    // The full-library run's collection scopes carry the Collections ceiling:
    // the emptied album folder, the Albums umbrella, and Collections itself
    // all go (never the root).
    let collectionSummary = await harness.manager.cleanupCoordinator.removeEmptyFolders(
      scopes: [
        .init(subtree: "Collections/Albums/Ghost", ancestorCeiling: "Collections")
      ], generation: 0)

    #expect(collectionSummary.removedFolders == 3)
    #expect(
      !FileManager.default.fileExists(
        atPath: harness.dest.rootURL.appendingPathComponent("Collections").path),
      "the Collections umbrella is the full run's ceiling and is removed when empty")
  }
}

extension URL {
  var doesDirectoryExist: Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
      && isDir.boolValue
  }
}
