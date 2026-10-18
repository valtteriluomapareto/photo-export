import Foundation

@testable import Photo_Export

/// Original-only conveniences for historical storage fixtures.
@MainActor
extension ExportRecordStore {
  func markExported(
    assetId: String,
    year: Int,
    month: Int,
    relPath: String,
    filename: String,
    exportedAt: Date
  ) {
    markVariantExported(
      assetId: assetId, variant: .original, year: year, month: month, relPath: relPath,
      filename: filename, exportedAt: exportedAt)
  }

  func markFailed(assetId: String, error: String, at date: Date) {
    markVariantFailed(assetId: assetId, variant: .original, error: error, at: date)
  }

  func markInProgress(
    assetId: String, year: Int, month: Int, relPath: String, filename: String?
  ) {
    markVariantInProgress(
      assetId: assetId, variant: .original, year: year, month: month, relPath: relPath,
      filename: filename)
  }

  /// Whether a historical fixture's original variant is done.
  func isExported(assetId: String) -> Bool {
    recordsById[assetId]?.variants[.original]?.status == .done
  }

}
