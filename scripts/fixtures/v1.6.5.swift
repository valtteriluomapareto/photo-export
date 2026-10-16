import Foundation

@main
struct GenerateVariants {
  @MainActor static func main() throws {
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let timeline = ExportRecordStore(baseDirectoryURL: root)
    let collections = CollectionExportRecordStore(baseDirectoryURL: root)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    timeline.configure(for: "A")
    collections.configure(for: "A")
    func done(
      _ id: String, _ name: String, variant: ExportVariant = .original, subfolder: String? = nil
    ) {
      timeline.markVariantExported(
        assetId: id, variant: variant, year: 2024, month: 4, relPath: "2024/04/", filename: name,
        exportedAt: date, subfolder: subfolder)
    }
    timeline.markVariantInProgress(
      assetId: "shared", variant: .original, year: 2024, month: 4, relPath: "2024/04/",
      filename: "OLD.JPG")
    timeline.markVariantFailed(
      assetId: "shared", variant: .original, error: "Modern retry", at: date)
    done("deleted", "DELETE.JPG")
    timeline.markVariantInProgress(
      assetId: "interrupted", variant: .original, year: 2024, month: 4, relPath: "2024/04/",
      filename: "PARTIAL.JPG")
    for _ in 0..<1000 { done("snapshot-only", "SNAP.JPG") }
    timeline.flushForTesting()
    done("shared", "REPLAY.JPG")
    timeline.remove(assetId: "deleted")
    done("log-only", "LOG.JPG")
    done("fallback", "F_orig.HEIC")
    timeline.markVariantFailed(
      assetId: "fallback", variant: .edited,
      error: ExportVariantRecovery.editedUnavailableOriginalBackedUpMessage, at: date)
    done("live", "LIVE.HEIC")
    timeline.markVariantFailed(
      assetId: "live", variant: .originalPairedVideo,
      error: ExportVariantRecovery.pairedVideoUnavailableMessage, at: date)
    done("video", "VIDEO.MOV", subfolder: "videos")
    timeline.flushForTesting()

    let favorites = ExportPlacement.favorites(createdAt: date)
    let album = ExportPlacement(
      kind: .album, id: "fixture-album", displayName: "Nested/Album",
      collectionLocalIdentifier: "fixture-collection",
      relativePath: "Collections/Albums/Nested/Album/", createdAt: date)
    let shared = ExportPlacement(
      kind: .sharedAlbum, id: "fixture-shared", displayName: "Shared",
      collectionLocalIdentifier: "fixture-shared-collection",
      relativePath: "Collections/Shared Albums/Shared/", createdAt: date)
    for placement in [favorites, album, shared] { collections.upsertPlacement(placement) }
    collections.markVariantInProgress(
      assetId: "shared", placement: favorites, variant: .original, filename: "OLD-FAV.JPG")
    collections.markVariantFailed(
      assetId: "shared", placement: favorites, variant: .original, error: "Favorite retry", at: date
    )
    collections.markVariantExported(
      assetId: "deleted", placement: favorites, variant: .original, filename: "DELETE.JPG",
      exportedAt: date)
    collections.markVariantInProgress(
      assetId: "interrupted", placement: album, variant: .original, filename: "PARTIAL.JPG")
    collections.markVariantInProgress(
      assetId: "shared", placement: album, variant: .original, filename: "ALBUM.JPG")
    collections.markVariantFailed(
      assetId: "shared", placement: album, variant: .original, error: "Album disk error", at: date)
    collections.markVariantExported(
      assetId: "shared", placement: shared, variant: .original, filename: "SHARED.JPG",
      exportedAt: date)
    for _ in 0..<1000 {
      collections.markVariantExported(
        assetId: "snapshot-only", placement: favorites, variant: .original, filename: "SNAP.JPG",
        exportedAt: date)
    }
    collections.flushForTesting()
    collections.markVariantExported(
      assetId: "shared", placement: favorites, variant: .original, filename: "REPLAY-FAV.JPG",
      exportedAt: date)
    collections.remove(assetId: "deleted", placement: favorites)
    collections.markVariantExported(
      assetId: "log-only", placement: album, variant: .original, filename: "LOG.JPG",
      exportedAt: date)
    collections.markVariantExported(
      assetId: "video", placement: album, variant: .original, filename: "VIDEO.MOV",
      exportedAt: date, subfolder: "videos")
    collections.markVariantExported(
      assetId: "fallback", placement: album, variant: .original, filename: "F_orig.HEIC",
      exportedAt: date)
    collections.markVariantFailed(
      assetId: "fallback", placement: album, variant: .edited,
      error: ExportVariantRecovery.editedUnavailableOriginalBackedUpMessage, at: date)
    collections.markVariantExported(
      assetId: "live", placement: album, variant: .original, filename: "LIVE.HEIC", exportedAt: date
    )
    collections.markVariantFailed(
      assetId: "live", placement: album, variant: .originalPairedVideo,
      error: ExportVariantRecovery.pairedVideoUnavailableMessage, at: date)
    collections.flushForTesting()
    timeline.configure(for: "B")
    collections.configure(for: "B")
    timeline.markVariantInProgress(
      assetId: "shared", variant: .original, year: 2030, month: 1, relPath: "2030/01/",
      filename: "OTHER.JPG")
    timeline.markVariantFailed(
      assetId: "shared", variant: .original, error: "Other destination", at: date)
    collections.upsertPlacement(favorites)
    collections.markVariantFailed(
      assetId: "shared", placement: favorites, variant: .original, error: "Other destination",
      at: date)
    timeline.flushForTesting()
    collections.flushForTesting()
  }
}
