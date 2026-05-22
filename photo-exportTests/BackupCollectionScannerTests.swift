import Foundation
import Testing

@testable import Photo_Export

/// Unit tests for `BackupCollectionScanner.scanCollections(at:)`.
///
/// Issue #106 — Import Existing Backup for `Collections/`. The scanner walks
/// three roots (`Favorites/`, `Albums/` recursive, `Shared Albums/` flat) and
/// emits one `CollectionScanGroup` per leaf folder. Empty leaves are
/// intentionally skipped; foreign subdirectories beneath a leaf are ignored.
struct BackupCollectionScannerTests {

  // MARK: - Empty / missing roots

  @Test func emptyRoot_returnsEmptyList() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let groups = BackupCollectionScanner.scanCollections(at: root)
    #expect(groups.isEmpty)
  }

  @Test func missingCollectionsRoot_returnsEmptyList() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // Plant only timeline content. Collections/ doesn't exist.
    try plant(at: root, path: "2025/06/IMG_0001.JPG")
    let groups = BackupCollectionScanner.scanCollections(at: root)
    #expect(groups.isEmpty)
  }

  // MARK: - Favorites

  @Test func favorites_withTwoFiles_emitsOneGroup() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try plant(at: root, path: "Collections/Favorites/IMG_A.JPG")
    try plant(at: root, path: "Collections/Favorites/IMG_B.JPG")
    let groups = BackupCollectionScanner.scanCollections(at: root)
    #expect(groups.count == 1)
    let group = try #require(groups.first)
    #expect(group.kind == .favorites)
    #expect(group.parentPathComponents == [])
    #expect(group.leafName == "Favorites")
    #expect(Set(group.files.map(\.filename)) == ["IMG_A.JPG", "IMG_B.JPG"])
    #expect(group.files.allSatisfy { $0.subfolder == nil })
  }

  @Test func favorites_empty_isSkipped() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("Collections/Favorites", isDirectory: true),
      withIntermediateDirectories: true)
    let groups = BackupCollectionScanner.scanCollections(at: root)
    #expect(groups.isEmpty)
  }

  // MARK: - Albums

  @Test func album_topLevel_emitsGroupWithEmptyParent() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try plant(at: root, path: "Collections/Albums/Trip/IMG_0001.JPG")
    let groups = BackupCollectionScanner.scanCollections(at: root)
    let albumGroups = groups.filter { $0.kind == .album }
    #expect(albumGroups.count == 1)
    let group = try #require(albumGroups.first)
    #expect(group.parentPathComponents == [])
    #expect(group.leafName == "Trip")
    #expect(group.files.map(\.filename) == ["IMG_0001.JPG"])
  }

  @Test func album_nestedUnderFolder_recordsParentPath() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try plant(at: root, path: "Collections/Albums/Trips/2024/IMG_0001.JPG")
    let groups = BackupCollectionScanner.scanCollections(at: root)
    let albumGroups = groups.filter { $0.kind == .album }
    #expect(albumGroups.count == 1)
    let group = try #require(albumGroups.first)
    #expect(group.parentPathComponents == ["Trips"])
    #expect(group.leafName == "2024")
  }

  @Test func album_folderOfFolders_namesNotConflated() throws {
    // PhotoKit user folder "Trip" containing album "Trip" renders as
    // Collections/Albums/Trip/Trip/. Inner Trip/ is the leaf.
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try plant(at: root, path: "Collections/Albums/Trip/Trip/IMG_0001.JPG")
    let groups = BackupCollectionScanner.scanCollections(at: root)
    let albumGroups = groups.filter { $0.kind == .album }
    #expect(albumGroups.count == 1)
    let group = try #require(albumGroups.first)
    #expect(group.parentPathComponents == ["Trip"])
    #expect(group.leafName == "Trip")
  }

  @Test func album_emptyLeaf_isSkipped() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("Collections/Albums/EmptyTrip", isDirectory: true),
      withIntermediateDirectories: true)
    let groups = BackupCollectionScanner.scanCollections(at: root)
    #expect(groups.isEmpty)
  }

  @Test func album_withFilesAndForeignSubdir_emitsLeafIgnoresSubdir() throws {
    // Real exports never produce album/foo/ alongside files in the album.
    // The scanner should treat the directory as a leaf and skip the foreign
    // subdirectory rather than recurse into it as a phantom sub-album.
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try plant(at: root, path: "Collections/Albums/Trip/IMG_0001.JPG")
    try plant(at: root, path: "Collections/Albums/Trip/foreign/IMG_X.JPG")
    let groups = BackupCollectionScanner.scanCollections(at: root)
    let albumGroups = groups.filter { $0.kind == .album }
    #expect(albumGroups.count == 1)
    let group = try #require(albumGroups.first)
    #expect(group.leafName == "Trip")
    #expect(group.files.map(\.filename) == ["IMG_0001.JPG"])
  }

  // MARK: - Albums + videos/ subfolder

  @Test func album_descendsVideosSubfolder() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try plant(at: root, path: "Collections/Albums/Trip/IMG_0001.JPG")
    try plant(at: root, path: "Collections/Albums/Trip/videos/IMG_0002.MOV")
    let groups = BackupCollectionScanner.scanCollections(at: root)
    let group = try #require(groups.first(where: { $0.kind == .album }))
    let byName = Dictionary(uniqueKeysWithValues: group.files.map { ($0.filename, $0) })
    #expect(byName["IMG_0001.JPG"]?.subfolder == nil)
    #expect(byName["IMG_0002.MOV"]?.subfolder == "videos")
  }

  @Test func album_videosOnly_stillEmitsLeaf() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try plant(at: root, path: "Collections/Albums/VideoOnly/videos/IMG_VID.MOV")
    let groups = BackupCollectionScanner.scanCollections(at: root)
    let albumGroups = groups.filter { $0.kind == .album }
    #expect(albumGroups.count == 1)
    let group = try #require(albumGroups.first)
    #expect(group.leafName == "VideoOnly")
    #expect(group.files.count == 1)
    #expect(group.files.first?.subfolder == "videos")
  }

  @Test func album_videosFolderEmpty_treatedAsParentFolderRecurseFails() throws {
    // An empty `videos/` child contributes no files. If the parent has no
    // direct files either, the parent should be treated as a folder and
    // recurse — but there are no non-`videos` subdirectories, so no leaf
    // is emitted.
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(
        "Collections/Albums/EmptyVideos/videos", isDirectory: true),
      withIntermediateDirectories: true)
    let groups = BackupCollectionScanner.scanCollections(at: root)
    #expect(groups.isEmpty)
  }

  @Test func album_videosAtWrongNestingDepth_notDescended() throws {
    // Collections/Albums/videos/Trip/IMG.MOV — `videos/` here is at the
    // Albums-root level, not the leaf level. The scanner should treat
    // `videos` as a regular folder name and surface `Trip/` as a normal
    // album leaf with parent "videos".
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try plant(at: root, path: "Collections/Albums/videos/Trip/IMG_0001.MOV")
    let groups = BackupCollectionScanner.scanCollections(at: root)
    let albumGroups = groups.filter { $0.kind == .album }
    #expect(albumGroups.count == 1)
    let group = try #require(albumGroups.first)
    #expect(group.parentPathComponents == ["videos"])
    #expect(group.leafName == "Trip")
    // The .MOV file is in the leaf directly — no videos/ descent at this depth.
    #expect(group.files.first?.subfolder == nil)
  }

  // MARK: - Shared Albums

  @Test func sharedAlbums_twoSiblings_emitsOneGroupEach() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try plant(at: root, path: "Collections/Shared Albums/Vacation/IMG_A.JPG")
    try plant(at: root, path: "Collections/Shared Albums/Wedding/IMG_B.JPG")
    let groups = BackupCollectionScanner.scanCollections(at: root)
    let shared = groups.filter { $0.kind == .sharedAlbum }
    #expect(shared.count == 2)
    #expect(shared.allSatisfy { $0.parentPathComponents.isEmpty })
    let leafNames = Set(shared.map(\.leafName))
    #expect(leafNames == ["Vacation", "Wedding"])
  }

  @Test func sharedAlbums_empty_isSkipped() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(
        "Collections/Shared Albums/EmptyAlbum", isDirectory: true),
      withIntermediateDirectories: true)
    let groups = BackupCollectionScanner.scanCollections(at: root)
    #expect(groups.isEmpty)
  }

  @Test func sharedAlbums_videosSubfolderDescent() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try plant(at: root, path: "Collections/Shared Albums/Trip/IMG.JPG")
    try plant(at: root, path: "Collections/Shared Albums/Trip/videos/IMG.MOV")
    let groups = BackupCollectionScanner.scanCollections(at: root)
    let shared = try #require(groups.first(where: { $0.kind == .sharedAlbum }))
    let byName = Dictionary(uniqueKeysWithValues: shared.files.map { ($0.filename, $0) })
    #expect(byName["IMG.JPG"]?.subfolder == nil)
    #expect(byName["IMG.MOV"]?.subfolder == "videos")
  }

  // MARK: - Mixed timeline + collections

  @Test func mixedTimelineAndCollections_scanCollectionsOnlyReturnsCollectionGroups() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try plant(at: root, path: "2025/06/IMG_T.JPG")
    try plant(at: root, path: "Collections/Favorites/IMG_F.JPG")
    let groups = BackupCollectionScanner.scanCollections(at: root)
    #expect(groups.count == 1)
    #expect(groups.first?.kind == .favorites)
  }

  // MARK: - Helpers

  private func makeTempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("BackupCollectionScanner-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// Plants a regular file at `root/path` (creating intermediate directories).
  /// `path` is a relative slash-separated string.
  private func plant(at root: URL, path: String, content: String = "x") throws {
    let fileURL = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try Data(content.utf8).write(to: fileURL)
  }
}
