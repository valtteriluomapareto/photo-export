import Foundation
import Testing

@testable import Photo_Export

/// The claim index both record stores keep: which filenames variant records name, per
/// folder. It must match the records after every kind of change, since an unclaimed
/// identical file may be adopted.
@MainActor
struct FilenameClaimsTests {
  @Test func namesCompareCaseFoldedAndInNFC() {
    var claims = FilenameClaims<String>()
    claims.add("Cafe\u{301}.JPG", in: "folder")
    #expect(claims.count("caf\u{E9}.jpg", in: "folder") == 1)
    #expect(claims.count("CAFÉ.JPG", in: "folder") == 1)
    #expect(claims.count("Cafe.JPG", in: "folder") == 0)
    #expect(claims.count("caf\u{E9}.jpg", in: "other") == 0)
  }

  @Test func claimsAreCountedPerRecord() {
    var claims = FilenameClaims<String>()
    claims.add("IMG.JPG", in: "f")
    claims.add("img.jpg", in: "f")
    claims.remove("IMG.JPG", in: "f")
    #expect(claims.count("IMG.JPG", in: "f") == 1)
    claims.remove("IMG.JPG", in: "f")
    claims.remove("IMG.JPG", in: "f")
    #expect(claims.count("IMG.JPG", in: "f") == 0)
    claims.add("IMG.JPG", in: "f")
    #expect(claims.count("IMG.JPG", in: "f") == 1)
    claims.add(nil, in: "f")
    claims.add("", in: "f")
    #expect(claims.count("", in: "f") == 0)
  }

  private static func root() -> URL { TestScratch.directory("FilenameClaims") }

  private static func timelineStore(_ root: URL) -> ExportRecordStore {
    let store = ExportRecordStore(baseDirectoryURL: root)
    store.configure(for: "dest")
    return store
  }

  private static func exported(
    _ store: ExportRecordStore, _ assetId: String, _ variant: ExportVariant = .original,
    filename: String, month: Int = 6, subfolder: String? = nil
  ) {
    store.markVariantExported(
      assetId: assetId, variant: variant, year: 2025, month: month,
      relPath: String(format: "2025/%02d/", month), filename: filename, exportedAt: Date(),
      subfolder: subfolder)
  }

  private static func claimed(
    _ store: ExportRecordStore, _ filename: String, month: Int = 6, subfolder: String? = nil,
    excluding assetId: String = "someone-else", variant: ExportVariant = .original
  ) -> Bool {
    store.isFilenameClaimed(
      filename, year: 2025, month: month, subfolder: subfolder, excludingAssetId: assetId,
      variant: variant)
  }

  /// The job's own variant record is not a claim; the asset's other variants are, and only
  /// in the folder their records name.
  @Test func timelineClaimsExcludeOnlyTheVariantBeingWritten() {
    let root = Self.root()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = Self.timelineStore(root)
    Self.exported(store, "asset", filename: "IMG.JPG")
    Self.exported(store, "asset", .edited, filename: "IMG (1).JPG")
    Self.exported(store, "clip", filename: "CLIP.MOV", subfolder: "videos")

    #expect(Self.claimed(store, "img.jpg"))
    #expect(!Self.claimed(store, "IMG.JPG", excluding: "asset", variant: .original))
    #expect(Self.claimed(store, "IMG.JPG", excluding: "asset", variant: .edited))
    #expect(Self.claimed(store, "IMG (1).JPG", excluding: "asset", variant: .original))
    #expect(!Self.claimed(store, "IMG.JPG", month: 7))
    #expect(!Self.claimed(store, "CLIP.MOV"))
    #expect(Self.claimed(store, "CLIP.MOV", subfolder: "videos"))
    #expect(!Self.claimed(store, "IMG.JPG", subfolder: "videos"))
  }

  /// The own record is subtracted only in the folder it names: another asset's claim in a
  /// different month still counts there.
  @Test func ownRecordIsExcludedOnlyInItsOwnFolder() {
    let root = Self.root()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = Self.timelineStore(root)
    Self.exported(store, "own", filename: "X.JPG", month: 6)
    Self.exported(store, "other", filename: "X.JPG", month: 7)

    #expect(Self.claimed(store, "X.JPG", month: 7, excluding: "own"))
    #expect(!Self.claimed(store, "X.JPG", month: 6, excluding: "own"))
  }

  /// Claims follow every mutation: a variant renamed or removed, a record moved to another
  /// month, an import, a reload from the log and snapshot, a prune and a reset.
  @Test func timelineClaimsFollowEveryMutation() async throws {
    let root = Self.root()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = Self.timelineStore(root)
    Self.exported(store, "a", filename: "A.JPG")
    Self.exported(store, "b", filename: "A.JPG")
    store.removeVariant(assetId: "a", variant: .original)
    #expect(Self.claimed(store, "A.JPG"))
    Self.exported(store, "b", filename: "B.JPG")
    #expect(!Self.claimed(store, "A.JPG"))
    #expect(Self.claimed(store, "B.JPG"))
    store.markVariantInProgress(
      assetId: "b", variant: .original, year: 2025, month: 7, relPath: "2025/07/",
      filename: "B.JPG")
    #expect(!Self.claimed(store, "B.JPG"))
    #expect(Self.claimed(store, "B.JPG", month: 7))
    store.markVariantFailed(assetId: "b", variant: .original, error: "x", at: Date())
    #expect(Self.claimed(store, "B.JPG", month: 7))

    store.bulkImportRecords([
      ExportRecord(
        id: "imported", year: 2025, month: 6, relPath: "2025/06/",
        variants: [
          .original: ExportVariantRecord(
            filename: "IMPORTED.JPG", status: .done, exportDate: Date(), lastError: nil)
        ])
    ])
    #expect(Self.claimed(store, "IMPORTED.JPG"))

    try await store.flush()
    store.configure(for: "dest")
    #expect(Self.claimed(store, "B.JPG", month: 7))
    #expect(Self.claimed(store, "IMPORTED.JPG"))
    #expect(!Self.claimed(store, "A.JPG"))

    // Nothing is on disk under this root, so the import's completed variant is pruned.
    let destination = TestScratch.directory("FilenameClaimsDestination")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: destination) }
    let summary = try await store.reconcileAgainstFilesystem(at: destination)
    #expect(summary.prunedVariants == 1)
    #expect(!Self.claimed(store, "IMPORTED.JPG"))
    #expect(Self.claimed(store, "B.JPG", month: 7))

    try await store.flush()
    try Data("corrupt".utf8).write(
      to: root.appendingPathComponent("dest").appendingPathComponent(
        ExportRecordStore.Constants.snapshotFileName))
    store.configure(for: "dest")
    #expect(store.state == .failed)
    #expect(!Self.claimed(store, "B.JPG", month: 7))
    store.resetToEmpty()
    #expect(!Self.claimed(store, "B.JPG", month: 7))
  }

  private static func collectionClaimed(
    _ store: CollectionExportRecordStore, _ filename: String, placement: ExportPlacement,
    subfolder: String? = nil, excluding assetId: String = "someone-else",
    variant: ExportVariant = .original
  ) -> Bool {
    store.isFilenameClaimed(
      filename, placement: placement, subfolder: subfolder, excludingAssetId: assetId,
      variant: variant)
  }

  @Test func collectionClaimsFollowEveryMutation() async throws {
    let root = Self.root()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CollectionExportRecordStore(baseDirectoryURL: root)
    store.configure(for: "dest")
    let favorites = ExportPlacement.favorites()
    let album = ExportPlacement(
      kind: .album, id: "album:1", displayName: "Trip", collectionLocalIdentifier: "1",
      relativePath: "Collections/Albums/Trip/", createdAt: Date())
    store.upsertPlacement(favorites)
    store.upsertPlacement(album)
    store.markVariantExported(
      assetId: "a", placement: favorites, variant: .original, filename: "A.JPG",
      exportedAt: Date())
    store.markVariantExported(
      assetId: "a", placement: album, variant: .original, filename: "A.JPG",
      exportedAt: Date())
    store.markVariantExported(
      assetId: "v", placement: album, variant: .original, filename: "V.MOV",
      exportedAt: Date(), subfolder: "videos")

    #expect(Self.collectionClaimed(store, "a.jpg", placement: favorites))
    #expect(!Self.collectionClaimed(store, "A.JPG", placement: favorites, excluding: "a"))
    #expect(
      Self.collectionClaimed(store, "A.JPG", placement: favorites, excluding: "a", variant: .edited)
    )
    #expect(!Self.collectionClaimed(store, "V.MOV", placement: album))
    #expect(Self.collectionClaimed(store, "V.MOV", placement: album, subfolder: "videos"))

    store.removeVariant(assetId: "a", placement: favorites, variant: .original)
    #expect(!Self.collectionClaimed(store, "A.JPG", placement: favorites))
    #expect(Self.collectionClaimed(store, "A.JPG", placement: album))

    try await store.flush()
    store.configure(for: "dest")
    #expect(Self.collectionClaimed(store, "A.JPG", placement: album))
    #expect(Self.collectionClaimed(store, "V.MOV", placement: album, subfolder: "videos"))
    #expect(!Self.collectionClaimed(store, "A.JPG", placement: favorites))

    store.deletePlacement(id: album.id)
    #expect(!Self.collectionClaimed(store, "A.JPG", placement: album))
    #expect(!Self.collectionClaimed(store, "V.MOV", placement: album, subfolder: "videos"))
  }
}
