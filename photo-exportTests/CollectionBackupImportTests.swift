import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Regression gates for Import Existing Backup adopting album, shared-album and Favorites
/// history from the folders under `Collections/`, so exporting those collections again after a
/// reinstall writes nothing for files already there.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct CollectionBackupImportTests {
  typealias F = CollectionBackupFixture

  // MARK: - Exporting again after an import writes nothing

  /// Favorites, a nested album with a photo and a video, and a shared album, with their files
  /// where an export puts them.
  private func plantExportedCollections(in h: CollectionImportHarness) throws {
    h.library.collectionTree = [
      F.favorites,
      F.folder("trips", "Trips", children: [F.album("paris", "Paris", in: ["Trips"])]),
      F.sharedAlbum("family", "Family"),
    ]
    let photo = h.addAsset("photo", "IMG_0001.JPG", date: F.date(1))
    let video = h.addAsset("video", "IMG_0002.MOV", date: F.date(2), mediaType: .video)
    let favorite = h.addAsset("favorite", "IMG_0003.JPG", date: F.date(3))
    let shared = h.addAsset("shared", "IMG_0004.JPG", date: F.date(4))
    h.library.assetsByAlbumLocalId["paris"] = [photo, video]
    h.library.favoritesAssets = [photo, favorite]
    h.library.assetsBySharedAlbumLocalId["family"] = [shared]

    let placed: [(LibrarySelection, AssetDescriptor, String)] = [
      (.album(collectionId: "paris"), photo, "IMG_0001.JPG"),
      (.album(collectionId: "paris"), video, "IMG_0002.MOV"),
      (.favorites, photo, "IMG_0001.JPG"),
      (.favorites, favorite, "IMG_0003.JPG"),
      (.sharedAlbum(collectionId: "family"), shared, "IMG_0004.JPG"),
    ]
    for (selection, asset, name) in placed {
      try F.plant(
        at: h.root, try h.exportDirectory(for: selection, asset: asset), name,
        date: try #require(asset.creationDate))
    }
    try #require(
      FileManager.default.fileExists(
        atPath: h.root.appendingPathComponent("Collections/Albums/Trips/Paris/videos/IMG_0002.MOV")
          .path))
  }

  /// Every way to export the planted collections: each one manually, then the Auto Export runs.
  private func exportCollectionsAgain(_ h: CollectionImportHarness) async {
    h.manager.startExportAlbum(collectionId: "paris")
    await h.manager.waitForQueueDrained()
    h.manager.startExportFavorites()
    await h.manager.waitForQueueDrained()
    h.manager.startExportSharedAlbum(collectionId: "family")
    await h.manager.waitForQueueDrained()
    for scope in [ExportRunScope.favoritesFull, .allAlbumsFull, .allSharedAlbumsFull] {
      let summary = await h.manager.runExport(
        context: ExportRunContext(
          source: .autoSync, visibility: .background, scope: scope, selection: .edited))
      #expect(summary.result == .completed, "\(scope)")
      #expect(summary.enqueuedCount == 0, "\(scope)")
      await h.manager.waitForQueueDrained()
    }
  }

  @Test func importAdoptsAlbumHistorySoExportsWriteNothing() async throws {
    let h = CollectionImportHarness("CollectionBackupImportRepro")
    try plantExportedCollections(in: h)
    let before = try F.listing(of: h.root)
    try #require(before.count == 5)

    await h.importBackup()
    try #require(h.manager.importError == nil)
    await exportCollectionsAgain(h)

    #expect(h.writer.writeCalls.isEmpty, "\(h.writer.writeCalls.map(\.url.lastPathComponent))")
    #expect(h.fileSystem.copyCalls.isEmpty)
    #expect(h.fileSystem.moveCalls.isEmpty)
    #expect(try F.listing(of: h.root) == before)
    #expect(h.manager.importResult?.collectionMatchedCount == 5)
    #expect(h.manager.importResult?.unrecognizedCollectionFolders == [])
    await h.cleanup()
  }

  /// Without the import the same exports write every file again, so the gate above is proving
  /// the adoption and not an export that never ran.
  @Test func withoutTheImportTheSameExportsWriteAgain() async throws {
    let h = CollectionImportHarness("CollectionBackupImportControl")
    try plantExportedCollections(in: h)
    let before = try F.listing(of: h.root)

    h.manager.startExportAlbum(collectionId: "paris")
    await h.manager.waitForQueueDrained()

    #expect(!h.writer.writeCalls.isEmpty)
    #expect(try F.listing(of: h.root) != before)
    await h.cleanup()
  }

  // MARK: - Export, forget, import, export again

  @Test func exportWipeImportRoundTripRestoresPlacements() async throws {
    let h = CollectionImportHarness("CollectionBackupImportRoundTrip")
    h.library.collectionTree = [
      F.favorites,
      F.folder(
        "trips", "Trips",
        children: [
          F.album("paris", "Paris", in: ["Trips"]),
          F.folder("y2024", "2024", in: ["Trips"], children: [F.album("rome", "Rome", in: ["Trips", "2024"])]),
        ]),
      F.album("beach-b", "Beach"),
      F.album("beach-a", "Beach"),
      F.album("plans", "Q1: Plans?"),
      F.sharedAlbum("friends", "Friends"),
    ]
    let assets = [
      h.addAsset("paris-1", "P1.JPG", date: F.date(1)),
      h.addAsset("rome-1", "R1.HEIC", date: F.date(2)),
      h.addAsset("rome-clip", "R2.MOV", date: F.date(3), mediaType: .video),
      h.addAsset("beach-1", "B1.JPG", date: F.date(4)),
      h.addAsset("beach-2", "B2.JPG", date: F.date(5)),
      h.addAsset("plans-1", "Q1.PNG", date: F.date(6)),
      h.addAsset("fav-1", "F1.JPG", date: F.date(7)),
      h.addAsset("friends-1", "S1.JPG", date: F.date(8)),
    ]
    let byId = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
    h.library.assetsByAlbumLocalId = [
      "paris": [byId["paris-1"]!],
      "rome": [byId["rome-1"]!, byId["rome-clip"]!],
      "beach-b": [byId["beach-1"]!],
      "beach-a": [byId["beach-2"]!],
      "plans": [byId["plans-1"]!],
    ]
    h.library.favoritesAssets = [byId["fav-1"]!, byId["paris-1"]!]
    h.library.assetsBySharedAlbumLocalId["friends"] = [byId["friends-1"]!]

    h.manager.startExportAlbums(collectionIds: ["paris", "rome", "beach-b", "beach-a", "plans"])
    await h.manager.waitForQueueDrained()
    h.manager.startExportFavorites()
    await h.manager.waitForQueueDrained()
    h.manager.startExportSharedAlbum(collectionId: "friends")
    await h.manager.waitForQueueDrained()

    let exported = h.collections.placements
    let paths = Set(exported.values.map(\.relativePath))
    try #require(
      paths == [
        "Collections/Albums/Trips/Paris/", "Collections/Albums/Trips/2024/Rome/",
        "Collections/Albums/Beach/", "Collections/Albums/Beach_2/",
        "Collections/Albums/Q1_ Plans_/", "Collections/Favorites/",
        "Collections/Shared Albums/Friends/",
      ])
    try #require(
      FileManager.default.fileExists(
        atPath: h.root.appendingPathComponent("Collections/Albums/Trips/2024/Rome/videos/R2.MOV")
          .path))
    let writes = h.writer.writeCalls.count
    let copies = h.fileSystem.copyCalls.count
    let moves = h.fileSystem.moveCalls.count
    let listing = try F.listing(of: h.root)

    h.wipeHistory()
    try #require(h.collections.placements.isEmpty)
    await h.importBackup()
    try #require(h.manager.importError == nil)

    let adopted = h.collections.placements
    #expect(Set(adopted.keys) == Set(exported.keys))
    for (id, original) in exported {
      #expect(adopted[id]?.relativePath == original.relativePath, "\(id)")
      #expect(adopted[id]?.kind == original.kind, "\(id)")
      #expect(
        adopted[id]?.collectionLocalIdentifier == original.collectionLocalIdentifier, "\(id)")
    }

    h.manager.startExportAlbums(collectionIds: ["paris", "rome", "beach-b", "beach-a", "plans"])
    await h.manager.waitForQueueDrained()
    h.manager.startExportFavorites()
    await h.manager.waitForQueueDrained()
    h.manager.startExportSharedAlbum(collectionId: "friends")
    await h.manager.waitForQueueDrained()

    #expect(h.writer.writeCalls.count == writes)
    #expect(h.fileSystem.copyCalls.count == copies)
    #expect(h.fileSystem.moveCalls.count == moves)
    #expect(try F.listing(of: h.root) == listing)
    await h.cleanup()
  }
}
