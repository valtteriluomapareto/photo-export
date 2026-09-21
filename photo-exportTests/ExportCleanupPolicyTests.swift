import Foundation
import Testing

@testable import Photo_Export

/// Pure decision tests for `ExportCompletionPolicy.isUpdatedAfterExport` — the
/// staleness rule behind the "Replace updated files" Cleanup option.
@MainActor
struct ExportCleanupPolicyTests {

  private func variant(
    status: ExportStatus, exportDate: Date? = nil
  ) -> ExportVariantRecord {
    ExportVariantRecord(
      filename: "IMG_0001.HEIC", status: status, exportDate: exportDate, lastError: nil,
      subfolder: nil)
  }

  @Test func noDoneVariantsIsNeverStale() {
    let asset = TestAssetFactory.makeAsset(
      id: "a", modificationDate: Date(timeIntervalSince1970: 1_000))
    let stale = ExportCompletionPolicy.isUpdatedAfterExport(
      asset: asset,
      variants: [
        .original: variant(status: .failed, exportDate: Date(timeIntervalSince1970: 500))
      ])
    #expect(!stale, "no .done variant → nothing to be stale")
  }

  @Test func nilModificationDateIsNeverStale() {
    let asset = TestAssetFactory.makeAsset(id: "a", modificationDate: nil)
    let stale = ExportCompletionPolicy.isUpdatedAfterExport(
      asset: asset,
      variants: [.original: variant(status: .done, exportDate: Date(timeIntervalSince1970: 1))])
    #expect(!stale, "unknown modification date must keep today's never-replace behavior")
  }

  @Test func exportDateAfterModificationIsNotStale() {
    let asset = TestAssetFactory.makeAsset(
      id: "a", modificationDate: Date(timeIntervalSince1970: 1_000))
    let stale = ExportCompletionPolicy.isUpdatedAfterExport(
      asset: asset,
      variants: [
        .original: variant(status: .done, exportDate: Date(timeIntervalSince1970: 2_000))
      ])
    #expect(!stale, "export written after the last modification is current")
  }

  @Test func exportDateBeforeModificationIsStale() {
    let asset = TestAssetFactory.makeAsset(
      id: "a", modificationDate: Date(timeIntervalSince1970: 1_000))
    let stale = ExportCompletionPolicy.isUpdatedAfterExport(
      asset: asset,
      variants: [
        .original: variant(status: .done, exportDate: Date(timeIntervalSince1970: 500))
      ])
    #expect(stale, "export written before the last modification is outdated")
  }

  @Test func nilExportDateOnDoneVariantIsStale() {
    let asset = TestAssetFactory.makeAsset(
      id: "a", modificationDate: Date(timeIntervalSince1970: 1_000))
    let stale = ExportCompletionPolicy.isUpdatedAfterExport(
      asset: asset,
      variants: [.original: variant(status: .done, exportDate: nil)])
    #expect(stale, "a .done variant without a recorded export date is conservatively stale")
  }

  @Test func oneStaleVariantAmongSeveralMakesAssetStale() {
    let asset = TestAssetFactory.makeAsset(
      id: "a", modificationDate: Date(timeIntervalSince1970: 1_000))
    let stale = ExportCompletionPolicy.isUpdatedAfterExport(
      asset: asset,
      variants: [
        .edited: variant(status: .done, exportDate: Date(timeIntervalSince1970: 2_000)),
        .original: variant(status: .done, exportDate: Date(timeIntervalSince1970: 500)),
      ])
    #expect(stale, "asset-level granularity: any stale .done variant marks the asset")
  }
}
