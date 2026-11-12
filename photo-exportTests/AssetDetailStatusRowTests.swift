import SwiftUI
import Testing

@testable import Photo_Export

struct AssetDetailStatusRowTests {
  private func record(
    _ status: ExportStatus, error: String? = nil, reason: ExportVariantReason? = nil
  ) -> ExportVariantRecord {
    .init(filename: "FILE.JPG", status: status, exportDate: nil, lastError: error, reason: reason)
  }

  @Test func ownedLibraryVersionsKeepOrderStatusCopyAndTones() {
    let asset = TestAssetFactory.makeAsset(hasAdjustments: true, isLivePhoto: true)
    let variants: [ExportVariant: ExportVariantRecord] = [
      .original: record(.done), .originalPairedVideo: record(.pending),
      .edited: record(.failed, error: "Disk full"), .editedPairedVideo: record(.inProgress),
    ]
    for kind: ExportPlacement.Kind in [.timeline, .favorites, .album] {
      let rows = AssetDetailStatusRow.rows(asset: asset, kind: kind, variants: variants)
      #expect(
        rows.map(\.text) == [
          "Original: Exported", "Live Photo video: Pending", "Edited failed: Disk full",
          "Edited Live Photo video: In progress",
        ])
      #expect(rows.map(\.color) == [.primary, .primary, .red, .primary])
    }
    #expect(
      AssetDetailStatusRow.rows(asset: asset, kind: .sharedAlbum, variants: variants)
        == [.init(text: "Original: Exported", color: .primary)])
  }

  @Test func recordedVersionsRemainVisibleWhenPhotosReportsNoEditOrLivePhoto() {
    let asset = TestAssetFactory.makeAsset()
    #expect(
      AssetDetailStatusRow.rows(asset: asset, kind: .album, variants: [.edited: record(.done)])
        == [.init(text: "Edited: Exported", color: .primary)])
    let rows = AssetDetailStatusRow.rows(
      asset: asset, kind: .timeline,
      variants: [
        .originalPairedVideo: record(.pending), .edited: record(.done),
        .editedPairedVideo: record(.failed),
      ])
    #expect(
      rows.map(\.text) == [
        "Live Photo video: Pending", "Edited: Exported",
        "Edited Live Photo video failed: Unknown error",
      ])
    #expect(rows.last?.color == .red)
    #expect(AssetDetailStatusRow.rows(asset: asset, kind: .album, variants: [:]).isEmpty)
  }

  @Test func typedRecoveryRowsKeepLiteralCopyAndSecondaryTone() {
    let rows = AssetDetailStatusRow.rows(
      asset: TestAssetFactory.makeAsset(hasAdjustments: true, isLivePhoto: true), kind: .album,
      variants: [
        .original: record(.done),
        .originalPairedVideo: record(.failed, reason: .pairedVideoUnavailable),
        .edited: record(.failed, reason: .editedUnavailableOriginalBackedUp),
      ])
    #expect(
      rows.map(\.text) == [
        "Original: Exported",
        "Live Photo video: Photos doesn't currently expose a paired video for this Live Photo. The still was exported.",
        "Edited version was unavailable. The original was saved as a `_orig` companion.",
      ])
    #expect(rows.map(\.color) == [.primary, .secondary, .secondary])
  }

  @Test func exportedDateAppendsTheExistingDateLabel() throws {
    var variant = record(.done)
    variant.exportDate = Date(timeIntervalSince1970: 1_700_000_000)
    let row = try #require(
      AssetDetailStatusRow.rows(
        asset: TestAssetFactory.makeAsset(), kind: .timeline, variants: [.original: variant]
      ).first)
    #expect(row.text.hasPrefix("Original: Exported "))
    #expect(row.text.count > "Original: Exported ".count)
    #expect(row.color == .primary)
  }
}
