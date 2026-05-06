import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Behavioral characterization tests for every public count/summary method on
/// `ExportRecordStore`. Each test drives a fixed, hand-picked set of mutations and asserts
/// the **exact integer outputs** of every query method on the resulting state.
///
/// These tests exist to lock in current behavior before the planned performance work that
/// replaces the linear `recordsById.values.reduce` scans with incrementally-maintained
/// indices. Any change to the store that produces different counts for these fixtures
/// breaks the test, even if the change "looks like a refactor."
///
/// Each fixture is small enough to enumerate by hand in the test comments, so a future
/// reader can verify the asserted numbers without running the test.
@MainActor
struct ExportRecordStoreQueryGoldenTests {

  // MARK: - Fixtures

  private func makeStore() throws -> (URL, ExportRecordStore) {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ExportRecordStoreQuery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = ExportRecordStore(baseDirectoryURL: dir)
    store.configure(for: "test")
    return (dir, store)
  }

  private func asset(
    id: String, year: Int, month: Int, hasAdjustments: Bool = false
  ) -> AssetDescriptor {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = 15
    let date = Calendar.current.date(from: components)!
    return AssetDescriptor(
      id: id,
      creationDate: date,
      mediaType: .image,
      pixelWidth: 100,
      pixelHeight: 100,
      duration: 0,
      hasAdjustments: hasAdjustments
    )
  }

  // MARK: - empty store

  @Test func emptyStoreReturnsZeros() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(store.yearExportedCount(year: 2025) == 0)
    #expect(store.recordCount(year: 2025, month: 6, variant: .original, status: .done) == 0)
    #expect(store.recordCount(year: 2025, month: 6, variant: .edited, status: .done) == 0)
    #expect(store.recordCountEditedDone(year: 2025, month: 6) == 0)
    #expect(store.recordCountBothVariantsDone(year: 2025, month: 6) == 0)
    #expect(store.recordCountOriginalDoneAtNaturalStem(year: 2025, month: 6) == 0)

    let summary = store.monthSummary(year: 2025, month: 6, totalAssets: 0)
    #expect(summary.exportedCount == 0)
    #expect(summary.totalCount == 0)
    #expect(summary.status == .notExported)

    // sidebarSummary returns nil when adjustedCount is nil (loading state).
    #expect(
      store.sidebarSummary(
        year: 2025, month: 6, totalCount: 10, adjustedCount: nil, selection: .edited)
        == nil)

    #expect(
      store.sidebarYearExportedCount(
        year: 2025, totalCountsByMonth: [:], adjustedCountsByMonth: [:], selection: .edited)
        == 0)
  }

  // MARK: - yearExportedCount

  /// Fixture: 5 assets across 2025-06 and 2025-07, plus 2 assets in 2024-12 (out of scope).
  /// All have `.original.done`. Year 2025 yearExportedCount == 5; year 2024 == 2.
  @Test func yearExportedCountCountsOnlyOriginalDoneInScope() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date(timeIntervalSince1970: 0)

    // 2024-12: 2 records, both .original.done.
    for i in 1...2 {
      store.markVariantExported(
        assetId: "2024-12-\(i)", variant: .original,
        year: 2024, month: 12, relPath: "2024/12/",
        filename: "IMG_\(i).HEIC", exportedAt: now)
    }
    // 2025-06: 3 records, .original.done.
    for i in 1...3 {
      store.markVariantExported(
        assetId: "2025-06-\(i)", variant: .original,
        year: 2025, month: 6, relPath: "2025/06/",
        filename: "IMG_\(i).HEIC", exportedAt: now)
    }
    // 2025-07: 2 records, .original.done.
    for i in 1...2 {
      store.markVariantExported(
        assetId: "2025-07-\(i)", variant: .original,
        year: 2025, month: 7, relPath: "2025/07/",
        filename: "IMG_\(i).HEIC", exportedAt: now)
    }
    // 2025-08: 1 record, .original.failed → must NOT count.
    store.markVariantFailed(
      assetId: "2025-08-failed", variant: .original, error: "test", at: now)

    #expect(store.yearExportedCount(year: 2024) == 2)
    #expect(store.yearExportedCount(year: 2025) == 5)
    #expect(store.yearExportedCount(year: 2026) == 0)
  }

  // MARK: - recordCount(year:month:variant:status:)

  /// Fixture: in 2025-06, drive every variant × status combination once.
  /// Asserts the per-cell count is 1 for set cells and 0 for unset cells.
  ///
  /// Note: `markVariantFailed` does not take year/month arguments — it preserves the
  /// existing record's year/month, or defaults to 0/0 for brand-new asset ids. To plant
  /// failed records at year=2025/month=6 we first call `markVariantInProgress` (which
  /// does take year/month) and then transition to failed.
  @Test func recordCountReturnsExactCellsByVariantAndStatus() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date(timeIntervalSince1970: 0)
    let yr = 2025
    let mo = 6
    let rel = "2025/06/"

    // .original.done at "img-1"
    store.markVariantExported(
      assetId: "img-1", variant: .original, year: yr, month: mo, relPath: rel,
      filename: "IMG_1.HEIC", exportedAt: now)
    // .edited.done at "img-2"
    store.markVariantExported(
      assetId: "img-2", variant: .edited, year: yr, month: mo, relPath: rel,
      filename: "IMG_2.JPG", exportedAt: now)
    // .original.failed at "img-3" (plant year/month via in-progress first).
    store.markVariantInProgress(
      assetId: "img-3", variant: .original, year: yr, month: mo, relPath: rel, filename: nil)
    store.markVariantFailed(
      assetId: "img-3", variant: .original, error: "Disk full", at: now)
    // .edited.failed at "img-4".
    store.markVariantInProgress(
      assetId: "img-4", variant: .edited, year: yr, month: mo, relPath: rel, filename: nil)
    store.markVariantFailed(
      assetId: "img-4", variant: .edited, error: "Permission denied", at: now)
    // .original.inProgress at "img-5".
    store.markVariantInProgress(
      assetId: "img-5", variant: .original, year: yr, month: mo, relPath: rel, filename: nil)

    #expect(store.recordCount(year: yr, month: mo, variant: .original, status: .done) == 1)
    #expect(store.recordCount(year: yr, month: mo, variant: .edited, status: .done) == 1)
    #expect(store.recordCount(year: yr, month: mo, variant: .original, status: .failed) == 1)
    #expect(store.recordCount(year: yr, month: mo, variant: .edited, status: .failed) == 1)
    #expect(store.recordCount(year: yr, month: mo, variant: .original, status: .inProgress) == 1)
    #expect(store.recordCount(year: yr, month: mo, variant: .edited, status: .inProgress) == 0)
    #expect(store.recordCount(year: yr, month: mo, variant: .original, status: .pending) == 0)

    // Out of scope.
    #expect(store.recordCount(year: yr, month: 5, variant: .original, status: .done) == 0)
    #expect(store.recordCount(year: 2026, month: mo, variant: .original, status: .done) == 0)
  }

  /// Quirk: `markVariantFailed` for a brand-new asset id creates the record at
  /// year=0/month=0/relPath="". Production wouldn't normally hit this (the run loop
  /// always calls `markVariantInProgress` before `markVariantFailed`), but the API
  /// allows it and tests should pin the behavior so a future refactor doesn't change
  /// it silently.
  @Test func failedCallForNewAssetCreatesRecordAtZeroYearMonth() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    store.markVariantFailed(
      assetId: "orphan", variant: .original, error: "test",
      at: Date(timeIntervalSince1970: 0))

    let info = store.exportInfo(assetId: "orphan")
    #expect(info?.year == 0)
    #expect(info?.month == 0)
    #expect(info?.relPath == "")
    #expect(info?.variants[.original]?.status == .failed)
    // It counts at year=0/month=0, not at any "real" year.
    #expect(store.recordCount(year: 0, month: 0, variant: .original, status: .failed) == 1)
    #expect(store.recordCount(year: 2025, month: 6, variant: .original, status: .failed) == 0)
  }

  // MARK: - recordCountBothVariantsDone + recordCountEditedDone

  /// Fixture: 4 assets in 2025-06.
  /// - both: original.done + edited.done       → 2 assets
  /// - edited only: edited.done                → 1 asset
  /// - original only: original.done             → 1 asset
  /// recordCountBothVariantsDone == 2
  /// recordCountEditedDone == 3 (the 2 "both" assets + the "edited only" asset)
  @Test func bothVariantsDoneAndEditedDoneCountIndependentOfOtherVariant() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date(timeIntervalSince1970: 0)
    let yr = 2025
    let mo = 6
    let rel = "2025/06/"

    for i in 1...2 {
      store.markVariantExported(
        assetId: "both-\(i)", variant: .original, year: yr, month: mo, relPath: rel,
        filename: "B\(i).HEIC", exportedAt: now)
      store.markVariantExported(
        assetId: "both-\(i)", variant: .edited, year: yr, month: mo, relPath: rel,
        filename: "B\(i).JPG", exportedAt: now)
    }
    store.markVariantExported(
      assetId: "edited-only", variant: .edited, year: yr, month: mo, relPath: rel,
      filename: "E.JPG", exportedAt: now)
    store.markVariantExported(
      assetId: "original-only", variant: .original, year: yr, month: mo, relPath: rel,
      filename: "O.HEIC", exportedAt: now)

    #expect(store.recordCountBothVariantsDone(year: yr, month: mo) == 2)
    #expect(store.recordCountEditedDone(year: yr, month: mo) == 3)
    #expect(store.recordCount(year: yr, month: mo, variant: .original, status: .done) == 3)
  }

  // MARK: - recordCountOriginalDoneAtNaturalStem

  /// Fixture: 4 records in 2025-06.
  /// - "img-A": .original.done at "IMG_A.HEIC" (natural stem), .edited not done → counts.
  /// - "img-B": .original.done at "IMG_B_orig.HEIC" (orig companion) → does NOT count.
  /// - "img-C": .original.done at "IMG_C.HEIC", .edited.done at "IMG_C.JPG" → does NOT count
  ///   (filtered by `record.variants[.edited]?.status == .done` short-circuit).
  /// - "img-D": .original.done with filename = nil → does NOT count.
  /// Expected: count == 1 (only "img-A").
  @Test func originalDoneAtNaturalStemFiltersCompanionsAndAccompaniedEdits() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date(timeIntervalSince1970: 0)
    let yr = 2025
    let mo = 6
    let rel = "2025/06/"

    store.markVariantExported(
      assetId: "img-A", variant: .original, year: yr, month: mo, relPath: rel,
      filename: "IMG_A.HEIC", exportedAt: now)
    store.markVariantExported(
      assetId: "img-B", variant: .original, year: yr, month: mo, relPath: rel,
      filename: "IMG_B_orig.HEIC", exportedAt: now)
    store.markVariantExported(
      assetId: "img-C", variant: .original, year: yr, month: mo, relPath: rel,
      filename: "IMG_C.HEIC", exportedAt: now)
    store.markVariantExported(
      assetId: "img-C", variant: .edited, year: yr, month: mo, relPath: rel,
      filename: "IMG_C.JPG", exportedAt: now)
    // img-D: simulate via markVariantInProgress → markVariantExported with nil filename;
    // the API requires a filename, so skip this branch — the nil-filename case is
    // exercised through `markVariantFailed` paths covered elsewhere.

    #expect(store.recordCountOriginalDoneAtNaturalStem(year: yr, month: mo) == 1)
  }

  // MARK: - sidebarSummary — .edited mode

  /// Fixture in 2025-06: total photos = 10, adjusted (edited) = 3, unedited = 7.
  /// Records:
  /// - 2 records: edited.done (one with original.done, one without).
  /// - 4 records: original.done only at natural stem (no edited.done).
  /// - 1 record:  original.done only at _orig companion (excluded from natural-stem count).
  /// .edited mode formula: editedDone + min(origOnlyAtStem, uneditedCount)
  ///                     = 2 + min(4, 7) = 6
  @Test func sidebarSummaryEditedModeFormula() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date(timeIntervalSince1970: 0)
    let yr = 2025
    let mo = 6
    let rel = "2025/06/"

    // 2 edited.done records.
    for i in 1...2 {
      store.markVariantExported(
        assetId: "ed-\(i)", variant: .edited, year: yr, month: mo, relPath: rel,
        filename: "E\(i).JPG", exportedAt: now)
    }
    store.markVariantExported(
      assetId: "ed-1", variant: .original, year: yr, month: mo, relPath: rel,
      filename: "E1.HEIC", exportedAt: now)
    // 4 original.done at natural stem.
    for i in 1...4 {
      store.markVariantExported(
        assetId: "ns-\(i)", variant: .original, year: yr, month: mo, relPath: rel,
        filename: "NS\(i).HEIC", exportedAt: now)
    }
    // 1 original.done at _orig companion (no edited).
    store.markVariantExported(
      assetId: "comp", variant: .original, year: yr, month: mo, relPath: rel,
      filename: "COMP_orig.HEIC", exportedAt: now)

    let summary = store.sidebarSummary(
      year: yr, month: mo, totalCount: 10, adjustedCount: 3, selection: .edited)
    #expect(summary != nil)
    #expect(summary?.exportedCount == 6)  // 2 + min(4, 7)
    #expect(summary?.totalCount == 10)
    #expect(summary?.status == .partial)

    // Loading state.
    #expect(
      store.sidebarSummary(
        year: yr, month: mo, totalCount: 10, adjustedCount: nil, selection: .edited)
        == nil)
  }

  // MARK: - sidebarSummary — .editedWithOriginals mode

  /// Same setup as above, .editedWithOriginals formula:
  /// bothDone + min(origOnlyAtStem, uneditedCount) = 1 + min(4, 7) = 5.
  /// (Of the two edited records, only "ed-1" has both variants done; "ed-2" has edited only.)
  @Test func sidebarSummaryEditedWithOriginalsModeFormula() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date(timeIntervalSince1970: 0)
    let yr = 2025
    let mo = 6
    let rel = "2025/06/"

    for i in 1...2 {
      store.markVariantExported(
        assetId: "ed-\(i)", variant: .edited, year: yr, month: mo, relPath: rel,
        filename: "E\(i).JPG", exportedAt: now)
    }
    store.markVariantExported(
      assetId: "ed-1", variant: .original, year: yr, month: mo, relPath: rel,
      filename: "E1.HEIC", exportedAt: now)
    for i in 1...4 {
      store.markVariantExported(
        assetId: "ns-\(i)", variant: .original, year: yr, month: mo, relPath: rel,
        filename: "NS\(i).HEIC", exportedAt: now)
    }
    store.markVariantExported(
      assetId: "comp", variant: .original, year: yr, month: mo, relPath: rel,
      filename: "COMP_orig.HEIC", exportedAt: now)

    let summary = store.sidebarSummary(
      year: yr, month: mo, totalCount: 10, adjustedCount: 3,
      selection: .editedWithOriginals)
    #expect(summary?.exportedCount == 5)  // 1 + min(4, 7)
    #expect(summary?.status == .partial)
  }

  /// Edge: the natural-stem cap prevents over-counting when origOnlyAtStem >> uneditedCount.
  /// Setup: 10 unedited assets (out of 12 total, 2 adjusted). 12 records all .original.done
  /// at natural stem (i.e. records belonging to currently-adjusted assets that exist as
  /// natural-stem rows). The cap clamps to 10.
  /// .edited mode formula: 0 + min(12, 10) = 10.
  @Test func sidebarSummaryNaturalStemCappedByUneditedCount() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date(timeIntervalSince1970: 0)
    let yr = 2025
    let mo = 6
    let rel = "2025/06/"

    for i in 1...12 {
      store.markVariantExported(
        assetId: "img-\(i)", variant: .original, year: yr, month: mo, relPath: rel,
        filename: "IMG_\(i).HEIC", exportedAt: now)
    }

    let summary = store.sidebarSummary(
      year: yr, month: mo, totalCount: 12, adjustedCount: 2, selection: .edited)
    #expect(summary?.exportedCount == 10)  // capped, not 12
  }

  // MARK: - sidebarYearExportedCount

  /// Sums per-month sidebar summaries across the year. Months without total counts or
  /// without adjusted counts contribute zero.
  ///
  /// Fixture: in 2025, three months have data:
  /// - 06: total=10, adjusted=3, with the same records as `sidebarSummaryEditedModeFormula`
  ///   (exported = 6 in .edited)
  /// - 07: total=5, adjusted=0, 2 .original.done at natural stem → 0 + min(2, 5) = 2.
  /// - 08: total=0, no data → 0.
  /// Year total under .edited = 6 + 2 + 0 = 8.
  @Test func sidebarYearExportedCountSumsAcrossMonths() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date(timeIntervalSince1970: 0)

    // 2025-06 — same as sidebarSummaryEditedModeFormula above.
    for i in 1...2 {
      store.markVariantExported(
        assetId: "ed-\(i)", variant: .edited, year: 2025, month: 6,
        relPath: "2025/06/", filename: "E\(i).JPG", exportedAt: now)
    }
    store.markVariantExported(
      assetId: "ed-1", variant: .original, year: 2025, month: 6,
      relPath: "2025/06/", filename: "E1.HEIC", exportedAt: now)
    for i in 1...4 {
      store.markVariantExported(
        assetId: "ns-\(i)", variant: .original, year: 2025, month: 6,
        relPath: "2025/06/", filename: "NS\(i).HEIC", exportedAt: now)
    }
    store.markVariantExported(
      assetId: "comp", variant: .original, year: 2025, month: 6,
      relPath: "2025/06/", filename: "COMP_orig.HEIC", exportedAt: now)

    // 2025-07 — 2 natural-stem .original.done records.
    for i in 1...2 {
      store.markVariantExported(
        assetId: "july-\(i)", variant: .original, year: 2025, month: 7,
        relPath: "2025/07/", filename: "JUL\(i).HEIC", exportedAt: now)
    }

    let yearTotal = store.sidebarYearExportedCount(
      year: 2025,
      totalCountsByMonth: [6: 10, 7: 5, 8: 0],
      adjustedCountsByMonth: [6: 3, 7: 0, 8: nil],
      selection: .edited
    )
    #expect(yearTotal == 8)

    // Adjusted nil for a month with totals → that month contributes 0, total stays the same.
    let yearTotalWithLoading = store.sidebarYearExportedCount(
      year: 2025,
      totalCountsByMonth: [6: 10, 7: 5, 8: 0],
      adjustedCountsByMonth: [6: 3, 7: nil, 8: nil],
      selection: .edited
    )
    #expect(yearTotalWithLoading == 6)  // only month 6 contributes
  }

  // MARK: - monthSummary(year:month:totalAssets:) — legacy original-done flavor

  /// Counts records whose `.original` variant is `.done`. Adjusted-but-edited assets that
  /// have no `.original` variant don't show up here; this is the legacy flavor used by
  /// callers without descriptors.
  @Test func legacyMonthSummaryCountsOriginalDoneOnly() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date(timeIntervalSince1970: 0)
    let yr = 2025
    let mo = 6
    let rel = "2025/06/"

    // 3 .original.done.
    for i in 1...3 {
      store.markVariantExported(
        assetId: "od-\(i)", variant: .original, year: yr, month: mo, relPath: rel,
        filename: "OD\(i).HEIC", exportedAt: now)
    }
    // 2 .edited.done (no .original).
    for i in 1...2 {
      store.markVariantExported(
        assetId: "ed-\(i)", variant: .edited, year: yr, month: mo, relPath: rel,
        filename: "ED\(i).JPG", exportedAt: now)
    }

    let summary = store.monthSummary(year: yr, month: mo, totalAssets: 5)
    #expect(summary.exportedCount == 3)  // legacy: .original.done only
    #expect(summary.totalCount == 5)
    #expect(summary.status == .partial)

    // Status when nothing is done.
    let zero = store.monthSummary(year: yr, month: 99, totalAssets: 5)
    #expect(zero.exportedCount == 0)
    #expect(zero.status == .notExported)

    // Status when total is zero.
    let none = store.monthSummary(year: yr, month: 99, totalAssets: 0)
    #expect(none.status == .notExported)
  }

  // MARK: - monthSummary(assets:selection:) — selection-aware

  /// Provided a list of asset descriptors, the strict per-asset isExported(asset:selection:)
  /// is consulted. Adjusted assets need .edited.done (and .original.done under
  /// .editedWithOriginals); unedited assets need .original.done.
  ///
  /// Fixture (5 assets in 2025-06):
  /// - "u-1" unedited: .original.done.
  /// - "u-2" unedited: nothing.
  /// - "a-1" adjusted: .edited.done, .original missing.
  /// - "a-2" adjusted: .edited.done, .original.done.
  /// - "a-3" adjusted: .original.done only.
  ///
  /// .edited mode: u-1 ✓, u-2 ✗, a-1 ✓ (.edited.done is sufficient), a-2 ✓, a-3 ✗ → 3 / 5.
  /// .editedWithOriginals: u-1 ✓, u-2 ✗, a-1 ✗ (needs .original too), a-2 ✓, a-3 ✗ → 2 / 5.
  @Test func selectionAwareMonthSummaryEvaluatesEachAsset() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date(timeIntervalSince1970: 0)
    let yr = 2025
    let mo = 6
    let rel = "2025/06/"

    let u1 = asset(id: "u-1", year: yr, month: mo, hasAdjustments: false)
    let u2 = asset(id: "u-2", year: yr, month: mo, hasAdjustments: false)
    let a1 = asset(id: "a-1", year: yr, month: mo, hasAdjustments: true)
    let a2 = asset(id: "a-2", year: yr, month: mo, hasAdjustments: true)
    let a3 = asset(id: "a-3", year: yr, month: mo, hasAdjustments: true)

    store.markVariantExported(
      assetId: u1.id, variant: .original, year: yr, month: mo, relPath: rel,
      filename: "U1.HEIC", exportedAt: now)
    store.markVariantExported(
      assetId: a1.id, variant: .edited, year: yr, month: mo, relPath: rel,
      filename: "A1.JPG", exportedAt: now)
    store.markVariantExported(
      assetId: a2.id, variant: .edited, year: yr, month: mo, relPath: rel,
      filename: "A2.JPG", exportedAt: now)
    store.markVariantExported(
      assetId: a2.id, variant: .original, year: yr, month: mo, relPath: rel,
      filename: "A2.HEIC", exportedAt: now)
    store.markVariantExported(
      assetId: a3.id, variant: .original, year: yr, month: mo, relPath: rel,
      filename: "A3.HEIC", exportedAt: now)

    let assets = [u1, u2, a1, a2, a3]

    let editedSummary = store.monthSummary(assets: assets, selection: .edited)
    #expect(editedSummary.exportedCount == 3)
    #expect(editedSummary.totalCount == 5)
    #expect(editedSummary.status == .partial)

    let editedWithOriginals = store.monthSummary(
      assets: assets, selection: .editedWithOriginals)
    #expect(editedWithOriginals.exportedCount == 2)
    #expect(editedWithOriginals.totalCount == 5)
    #expect(editedWithOriginals.status == .partial)
  }

  // MARK: - isExported(assetId:) and isExported(asset:selection:)

  /// `isExported(assetId:)` is the legacy-shaped helper that only checks `.original.done`.
  /// `isExported(asset:selection:)` uses requiredVariants based on the asset's
  /// `hasAdjustments`.
  @Test func isExportedHelpersBehaveDifferentlyForAdjustedAssets() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date(timeIntervalSince1970: 0)
    let yr = 2025
    let mo = 6
    let rel = "2025/06/"

    let unedited = asset(id: "u", year: yr, month: mo, hasAdjustments: false)
    let adjusted = asset(id: "a", year: yr, month: mo, hasAdjustments: true)

    // Both get .original.done only.
    store.markVariantExported(
      assetId: unedited.id, variant: .original, year: yr, month: mo, relPath: rel,
      filename: "U.HEIC", exportedAt: now)
    store.markVariantExported(
      assetId: adjusted.id, variant: .original, year: yr, month: mo, relPath: rel,
      filename: "A.HEIC", exportedAt: now)

    // Legacy shim: both look "exported" because legacy ignores adjustment status.
    #expect(store.isExported(assetId: unedited.id))
    #expect(store.isExported(assetId: adjusted.id))

    // Strict: unedited is satisfied; adjusted is not (needs .edited.done).
    #expect(store.isExported(asset: unedited, selection: .edited))
    #expect(!store.isExported(asset: adjusted, selection: .edited))
    #expect(store.isExported(asset: unedited, selection: .editedWithOriginals))
    #expect(!store.isExported(asset: adjusted, selection: .editedWithOriginals))

    // Add the adjusted asset's edited variant — now it satisfies .edited but not
    // .editedWithOriginals (the .original is still done from above so it does).
    store.markVariantExported(
      assetId: adjusted.id, variant: .edited, year: yr, month: mo, relPath: rel,
      filename: "A.JPG", exportedAt: now)
    #expect(store.isExported(asset: adjusted, selection: .edited))
    #expect(store.isExported(asset: adjusted, selection: .editedWithOriginals))
  }

  // MARK: - Incremental counter integrity under churn

  /// Stress-test the incremental counter maintenance: drive a sequence that visits every
  /// transition shape (insert, update, cross-month move, variant add/remove, full-record
  /// delete) and verify each public count method matches a recompute-from-scratch over
  /// `recordsById` after every step. If the counter diff implementation drifts from the
  /// linear scan it replaced, this test fires.
  ///
  /// This covers the path that `apply(_:recordCounters: true)` exercises in production
  /// — every mutation routes through `apply` via `append`. The golden-state tests above
  /// verify end-state correctness on hand-checked fixtures; this test verifies that the
  /// counter map stays consistent through arbitrary mutation sequences.
  @Test func incrementalCountersStayConsistentUnderChurn() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date(timeIntervalSince1970: 0)

    func assertConsistentCountsForAllCells() {
      // Recompute every count method by scanning recordsById from scratch and assert
      // the public method returns the same value. We probe a few (year, month) cells
      // and a few variant×status combinations covering the whole 2024–2026 range so a
      // counter leak in any direction surfaces.
      for year in [2024, 2025, 2026] {
        var yearOriginalDone = 0
        for month in 1...12 {
          var byVariantStatus: [ExportVariant: [ExportStatus: Int]] = [:]
          var bothDone = 0
          var origAtNaturalStem = 0
          var editedFallback = 0
          for record in store.recordsById.values
          where record.year == year && record.month == month {
            for (variant, variantRec) in record.variants {
              byVariantStatus[variant, default: [:]][variantRec.status, default: 0] += 1
            }
            let originalDone = record.variants[.original]?.status == .done
            let editedDone = record.variants[.edited]?.status == .done
            if originalDone && editedDone { bothDone += 1 }
            if originalDone, !editedDone,
              let filename = record.variants[.original]?.filename,
              !ExportFilenamePolicy.isOrigCompanion(filename: filename)
            {
              origAtNaturalStem += 1
            }
            if originalDone,
              let editedRecord = record.variants[.edited],
              editedRecord.status == .failed,
              editedRecord.lastError
                == ExportVariantRecovery.editedUnavailableOriginalBackedUpMessage
            {
              editedFallback += 1
            }
            if originalDone { yearOriginalDone += 1 }
          }
          for variant in [ExportVariant.original, .edited] {
            for status in [ExportStatus.pending, .inProgress, .done, .failed] {
              let expected = byVariantStatus[variant]?[status] ?? 0
              let actual = store.recordCount(
                year: year, month: month, variant: variant, status: status)
              #expect(
                actual == expected,
                "recordCount(\(year)-\(month), \(variant), \(status)) = \(actual), expected \(expected)"
              )
            }
          }
          #expect(store.recordCountBothVariantsDone(year: year, month: month) == bothDone)
          #expect(
            store.recordCountOriginalDoneAtNaturalStem(year: year, month: month)
              == origAtNaturalStem)
          #expect(
            store.recordCountEditedFallback(year: year, month: month) == editedFallback,
            "recordCountEditedFallback(\(year)-\(month)) drift")
        }
        #expect(
          store.yearExportedCount(year: year) == yearOriginalDone,
          "yearExportedCount(\(year)) = \(store.yearExportedCount(year: year)), expected \(yearOriginalDone)"
        )
      }
    }

    // Step 1: insert across multiple (year, month) cells.
    store.markVariantExported(
      assetId: "a", variant: .original, year: 2025, month: 6, relPath: "2025/06/",
      filename: "A.HEIC", exportedAt: now)
    assertConsistentCountsForAllCells()

    store.markVariantExported(
      assetId: "b", variant: .original, year: 2025, month: 7, relPath: "2025/07/",
      filename: "B.HEIC", exportedAt: now)
    assertConsistentCountsForAllCells()

    store.markVariantExported(
      assetId: "c", variant: .original, year: 2024, month: 12, relPath: "2024/12/",
      filename: "C.HEIC", exportedAt: now)
    assertConsistentCountsForAllCells()

    // Step 2: add edited variant — both-done count and natural-stem count should diff.
    store.markVariantExported(
      assetId: "a", variant: .edited, year: 2025, month: 6, relPath: "2025/06/",
      filename: "A.JPG", exportedAt: now)
    assertConsistentCountsForAllCells()

    // Step 3: switch a's original filename to a _orig companion (simulating a paired
    // export). Natural-stem count should decrement.
    store.markVariantExported(
      assetId: "a", variant: .original, year: 2025, month: 6, relPath: "2025/06/",
      filename: "A_orig.HEIC", exportedAt: now)
    assertConsistentCountsForAllCells()

    // Step 4: in-progress + failed transitions.
    store.markVariantInProgress(
      assetId: "d", variant: .original, year: 2025, month: 6, relPath: "2025/06/",
      filename: nil)
    assertConsistentCountsForAllCells()
    store.markVariantFailed(
      assetId: "d", variant: .original, error: "test", at: now)
    assertConsistentCountsForAllCells()

    // Step 5: remove a single variant.
    store.removeVariant(assetId: "a", variant: .edited)
    assertConsistentCountsForAllCells()

    // Step 6: full-record delete.
    store.remove(assetId: "c")
    assertConsistentCountsForAllCells()

    // Step 7: re-add with a different year/month (cross-cell move on re-insert).
    store.markVariantExported(
      assetId: "c", variant: .original, year: 2026, month: 1, relPath: "2026/01/",
      filename: "C.HEIC", exportedAt: now)
    assertConsistentCountsForAllCells()

    // Step 8: compose a fallback record in 2026-02 — `.original` `.done` at a
    // `_orig` filename plus `.edited` `.failed` with the explicit
    // fallback-covered sentinel. Exercises the `editedFallbackCovered`
    // counter's increment path.
    store.markVariantExported(
      assetId: "fb", variant: .original, year: 2026, month: 2, relPath: "2026/02/",
      filename: "FB_orig.HEIC", exportedAt: now)
    store.markVariantFailed(
      assetId: "fb", variant: .edited,
      error: ExportVariantRecovery.editedUnavailableOriginalBackedUpMessage, at: now)
    assertConsistentCountsForAllCells()

    // Step 9: transition `.edited` to `.done` (the edit becomes available on a
    // future run) — fallback counter must decrement, both-done counter must
    // increment.
    store.markVariantExported(
      assetId: "fb", variant: .edited, year: 2026, month: 2, relPath: "2026/02/",
      filename: "FB.JPG", exportedAt: now)
    assertConsistentCountsForAllCells()

    // Step 10: remove the fallback-covering record entirely (e.g. a reconcile
    // pass after the user deleted the file). Counter must drop to zero.
    store.markVariantFailed(
      assetId: "fb2", variant: .edited,
      error: ExportVariantRecovery.editedUnavailableOriginalBackedUpMessage, at: now)
    store.markVariantExported(
      assetId: "fb2", variant: .original, year: 2026, month: 3, relPath: "2026/03/",
      filename: "FB2_orig.HEIC", exportedAt: now)
    assertConsistentCountsForAllCells()
    store.remove(assetId: "fb2")
    assertConsistentCountsForAllCells()
  }

  // MARK: - Mutation transitions

  /// Drives a sequence of state transitions on one record and asserts counts after each.
  /// Locks in: counts respond to upserts, deletes, and variant transitions in the obvious
  /// way.
  @Test func countsRespondToMutationSequence() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date(timeIntervalSince1970: 0)
    let yr = 2025
    let mo = 6
    let rel = "2025/06/"

    // Step 1: upsert original.done.
    store.markVariantExported(
      assetId: "x", variant: .original, year: yr, month: mo, relPath: rel,
      filename: "X.HEIC", exportedAt: now)
    #expect(store.recordCount(year: yr, month: mo, variant: .original, status: .done) == 1)
    #expect(store.recordCountOriginalDoneAtNaturalStem(year: yr, month: mo) == 1)

    // Step 2: add edited.done — natural-stem count drops to 0 (filtered by edited.done).
    store.markVariantExported(
      assetId: "x", variant: .edited, year: yr, month: mo, relPath: rel,
      filename: "X.JPG", exportedAt: now)
    #expect(store.recordCountEditedDone(year: yr, month: mo) == 1)
    #expect(store.recordCountBothVariantsDone(year: yr, month: mo) == 1)
    #expect(store.recordCountOriginalDoneAtNaturalStem(year: yr, month: mo) == 0)

    // Step 3: removeVariant(.edited) — back to original-only.
    store.removeVariant(assetId: "x", variant: .edited)
    #expect(store.recordCountEditedDone(year: yr, month: mo) == 0)
    #expect(store.recordCountBothVariantsDone(year: yr, month: mo) == 0)
    #expect(store.recordCountOriginalDoneAtNaturalStem(year: yr, month: mo) == 1)

    // Step 4: remove(assetId:) — record gone, all counts zero.
    store.remove(assetId: "x")
    #expect(store.recordCount(year: yr, month: mo, variant: .original, status: .done) == 0)
    #expect(store.recordCountOriginalDoneAtNaturalStem(year: yr, month: mo) == 0)
  }

  // MARK: - Cross-cell move via the failed-then-inProgress quirk

  /// Closes a coverage gap from the c15c159 review: `markVariantFailed` for a brand-new
  /// asset id creates the record at year=0/month=0 (the API doesn't take year/month for
  /// failed). A subsequent `markVariantInProgress` for the same asset id sets the real
  /// year/month, which routes through `apply(.upsert(...))` with a counter diff that
  /// must subtract from the (0,0) cell and add to the real cell.
  ///
  /// The diff is correct by inspection (subtract-old, add-new), but
  /// `incrementalCountersStayConsistentUnderChurn` only exercises the in-progress→failed
  /// direction. This test pins the reverse — failed-first-then-inProgress — and verifies
  /// the counter map at (0,0) returns to zero after the move while (year,month) picks up
  /// the contribution.
  @Test func failedThenInProgressMovesCountersAcrossCells() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date(timeIntervalSince1970: 0)

    // Step 1: failed call for a brand-new asset id → record at (0, 0).
    store.markVariantFailed(
      assetId: "moving", variant: .original, error: "test", at: now)
    #expect(store.exportInfo(assetId: "moving")?.year == 0)
    #expect(store.exportInfo(assetId: "moving")?.month == 0)
    #expect(
      store.recordCount(year: 0, month: 0, variant: .original, status: .failed) == 1,
      "(0,0) cell holds the orphan failed record")
    #expect(
      store.recordCount(year: 2025, month: 6, variant: .original, status: .failed) == 0)

    // Step 2: in-progress call sets year=2025/month=6 → cross-cell move.
    store.markVariantInProgress(
      assetId: "moving", variant: .original, year: 2025, month: 6, relPath: "2025/06/",
      filename: nil)
    #expect(store.exportInfo(assetId: "moving")?.year == 2025)
    #expect(store.exportInfo(assetId: "moving")?.month == 6)

    // (0,0) cell must have decremented to 0; (2025,6) cell picked up the in-progress.
    #expect(
      store.recordCount(year: 0, month: 0, variant: .original, status: .failed) == 0,
      "(0,0) cell counter must drop to zero after cross-cell move")
    #expect(
      store.recordCount(year: 0, month: 0, variant: .original, status: .inProgress) == 0,
      "no inProgress at (0,0) — record was moved before transition")
    #expect(
      store.recordCount(year: 2025, month: 6, variant: .original, status: .inProgress) == 1,
      "(2025,6) cell holds the in-progress contribution")

    // Step 3: complete the move with markVariantExported.
    store.markVariantExported(
      assetId: "moving", variant: .original, year: 2025, month: 6, relPath: "2025/06/",
      filename: "MOVING.HEIC", exportedAt: now)
    #expect(
      store.recordCount(year: 2025, month: 6, variant: .original, status: .inProgress) == 0)
    #expect(
      store.recordCount(year: 2025, month: 6, variant: .original, status: .done) == 1)
    #expect(store.yearExportedCount(year: 2025) == 1)
    #expect(store.yearExportedCount(year: 0) == 0)
  }

  // MARK: - bulkImportRecords counter consistency

  /// Closes a coverage gap from the c15c159 review: `bulkImportRecords` constructs a
  /// merged record (preserving existing `.done` variants, accepting weaker imports) and
  /// routes through `append(.upsert(merged))`. The same counter diff applies, but the
  /// merge-with-precedence logic combined with cross-record changes wasn't exercised
  /// directly by the churn test.
  ///
  /// Fixture: pre-populate the store with one `.original.failed` record. Then bulk-import
  /// two records: one that promotes the existing failed asset to `.original.done`, and
  /// one fresh asset with `.edited.done`. After import, every public count method
  /// matches a recompute-from-scratch over `recordsById`.
  @Test func bulkImportRecordsKeepsCountersConsistent() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date(timeIntervalSince1970: 0)
    let yr = 2025
    let mo = 8
    let rel = "2025/08/"

    // Pre-state: one .original.failed via the standard mutation path.
    store.markVariantInProgress(
      assetId: "promoted", variant: .original, year: yr, month: mo, relPath: rel,
      filename: nil)
    store.markVariantFailed(
      assetId: "promoted", variant: .original, error: "test", at: now)
    #expect(store.recordCount(year: yr, month: mo, variant: .original, status: .failed) == 1)

    // Bulk-import: promote the failed asset's .original to .done, and add a fresh
    // asset's .edited.done. `bulkImportRecords` builds `merged` per id and calls
    // `append(.upsert(merged))`, which routes through the diff path.
    let promotedDone = ExportRecord(
      id: "promoted", year: yr, month: mo, relPath: rel,
      variants: [
        .original: ExportVariantRecord(
          filename: "PROMOTED.HEIC", status: .done, exportDate: now, lastError: nil)
      ])
    let freshEdited = ExportRecord(
      id: "fresh", year: yr, month: mo, relPath: rel,
      variants: [
        .edited: ExportVariantRecord(
          filename: "FRESH.JPG", status: .done, exportDate: now, lastError: nil)
      ])
    store.bulkImportRecords([promotedDone, freshEdited])

    // Recompute every count from scratch and verify the public methods agree.
    var byVariantStatus: [ExportVariant: [ExportStatus: Int]] = [:]
    var bothDone = 0
    var origAtNaturalStem = 0
    for record in store.recordsById.values
    where record.year == yr && record.month == mo {
      for (variant, variantRec) in record.variants {
        byVariantStatus[variant, default: [:]][variantRec.status, default: 0] += 1
      }
      let originalDone = record.variants[.original]?.status == .done
      let editedDone = record.variants[.edited]?.status == .done
      if originalDone && editedDone { bothDone += 1 }
      if originalDone, !editedDone,
        let filename = record.variants[.original]?.filename,
        !ExportFilenamePolicy.isOrigCompanion(filename: filename)
      {
        origAtNaturalStem += 1
      }
    }
    for variant in [ExportVariant.original, .edited] {
      for status in [ExportStatus.pending, .inProgress, .done, .failed] {
        let expected = byVariantStatus[variant]?[status] ?? 0
        #expect(
          store.recordCount(year: yr, month: mo, variant: variant, status: status) == expected
        )
      }
    }
    #expect(store.recordCountBothVariantsDone(year: yr, month: mo) == bothDone)
    #expect(
      store.recordCountOriginalDoneAtNaturalStem(year: yr, month: mo) == origAtNaturalStem)
    #expect(store.yearExportedCount(year: yr) == byVariantStatus[.original]?[.done] ?? 0)

    // Sanity: the failed record is gone (promoted to done) and the fresh edited landed.
    #expect(store.recordCount(year: yr, month: mo, variant: .original, status: .failed) == 0)
    #expect(store.recordCount(year: yr, month: mo, variant: .original, status: .done) == 1)
    #expect(store.recordCount(year: yr, month: mo, variant: .edited, status: .done) == 1)
  }

  // MARK: - configure(for:) reload roundtrip

  /// Covers the **log-only reload path**: store A's mutations live in the JSONL log
  /// (compaction triggers at 1000 mutations and we only plant ~10), so when store B
  /// configures, `loaded.snapshot` is `nil` and the `recordsById = snapshot` branch is
  /// skipped — the entire state is reconstructed by replaying log ops via
  /// `apply(_:recordCounters: false)`, then `recoverInProgressVariants()` rewrites
  /// in-progress variants to failed in-place, then `rebuildCountersFromRecords()`
  /// materializes the counter map in one O(N) pass.
  ///
  /// The companion test `configureReloadFromSnapshotPlusLogReproducesCounters` covers
  /// the snapshot-load path (`recordsById = snapshot` branch); together they exercise
  /// every load shape `configure(for:)` can take.
  @Test func configureReloadFromLogOnlyReproducesCounters() throws {
    let (dir, storeA) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date(timeIntervalSince1970: 0)
    let yr = 2025
    let mo = 6
    let rel = "2025/06/"

    // Drive a mix of completed, failed, and in-progress variants. The in-progress
    // ones will be rewritten to failed by recoverInProgressVariants on the second
    // store's load, so the second-store counts reflect that recovery — verifying the
    // post-recovery counter rebuild is consistent.
    for i in 1...3 {
      storeA.markVariantExported(
        assetId: "done-\(i)", variant: .original, year: yr, month: mo, relPath: rel,
        filename: "D\(i).HEIC", exportedAt: now)
    }
    storeA.markVariantInProgress(
      assetId: "stuck", variant: .original, year: yr, month: mo, relPath: rel,
      filename: nil)
    storeA.markVariantInProgress(
      assetId: "alsostuck", variant: .edited, year: yr, month: mo, relPath: rel,
      filename: nil)
    storeA.markVariantInProgress(
      assetId: "fail", variant: .original, year: yr, month: mo, relPath: rel,
      filename: nil)
    storeA.markVariantFailed(
      assetId: "fail", variant: .original, error: "test", at: now)
    storeA.markVariantExported(
      assetId: "both", variant: .original, year: yr, month: mo, relPath: rel,
      filename: "BOTH.HEIC", exportedAt: now)
    storeA.markVariantExported(
      assetId: "both", variant: .edited, year: yr, month: mo, relPath: rel,
      filename: "BOTH.JPG", exportedAt: now)
    storeA.flushForTesting()  // ensure the JSONL log is durable

    // Construct a fresh store against the same on-disk directory. Triggers
    // configure → snapshot/log load → recoverInProgressVariants → rebuild.
    let storeB = ExportRecordStore(baseDirectoryURL: dir)
    storeB.configure(for: "test")
    #expect(storeB.state == .ready)

    // Recovery transitions the two .inProgress variants → .failed. Both stores'
    // observable state should now match.
    #expect(
      storeB.recordCount(year: yr, month: mo, variant: .original, status: .inProgress) == 0,
      "stuck inProgress recovered to failed")
    #expect(
      storeB.recordCount(year: yr, month: mo, variant: .edited, status: .inProgress) == 0,
      "stuck inProgress recovered to failed")

    // Final-state count cross-check: every public count method on storeB matches a
    // recompute over storeB.recordsById.
    var byVariantStatus: [ExportVariant: [ExportStatus: Int]] = [:]
    var bothDone = 0
    var origAtNaturalStem = 0
    for record in storeB.recordsById.values
    where record.year == yr && record.month == mo {
      for (variant, variantRec) in record.variants {
        byVariantStatus[variant, default: [:]][variantRec.status, default: 0] += 1
      }
      let originalDone = record.variants[.original]?.status == .done
      let editedDone = record.variants[.edited]?.status == .done
      if originalDone && editedDone { bothDone += 1 }
      if originalDone, !editedDone,
        let filename = record.variants[.original]?.filename,
        !ExportFilenamePolicy.isOrigCompanion(filename: filename)
      {
        origAtNaturalStem += 1
      }
    }
    for variant in [ExportVariant.original, .edited] {
      for status in [ExportStatus.pending, .inProgress, .done, .failed] {
        let expected = byVariantStatus[variant]?[status] ?? 0
        let actual = storeB.recordCount(
          year: yr, month: mo, variant: variant, status: status)
        #expect(
          actual == expected,
          "post-reload recordCount(\(variant), \(status)) = \(actual), expected \(expected)"
        )
      }
    }
    #expect(storeB.recordCountBothVariantsDone(year: yr, month: mo) == bothDone)
    #expect(
      storeB.recordCountOriginalDoneAtNaturalStem(year: yr, month: mo) == origAtNaturalStem)
    #expect(storeB.yearExportedCount(year: yr) == byVariantStatus[.original]?[.done] ?? 0)

    // Concrete spot-checks:
    // - 3 done-N records + 1 both = 4 .original.done.
    // - 1 .both = 1 .edited.done.
    // - 1 stuck (originally .original.inProgress) recovered → .original.failed.
    // - 1 alsostuck (originally .edited.inProgress) recovered → .edited.failed.
    // - 1 fail = 1 .original.failed.
    // Total: .original.done = 4, .original.failed = 2, .edited.done = 1, .edited.failed = 1.
    #expect(storeB.recordCount(year: yr, month: mo, variant: .original, status: .done) == 4)
    #expect(storeB.recordCount(year: yr, month: mo, variant: .original, status: .failed) == 2)
    #expect(storeB.recordCount(year: yr, month: mo, variant: .edited, status: .done) == 1)
    #expect(storeB.recordCount(year: yr, month: mo, variant: .edited, status: .failed) == 1)
    #expect(storeB.recordCountBothVariantsDone(year: yr, month: mo) == 1)
  }

  /// Covers the **snapshot-load path** plus **multi-cell in-progress recovery**, both
  /// of which are unreachable through the standard `markVariant*` API at small scale
  /// (compaction triggers at 1000 mutations). We hand-craft a snapshot file containing
  /// records across two `(year, month)` cells, with `.inProgress` variants in BOTH
  /// cells, plus a small log overlay. After `configure(for:)`:
  /// - `loaded.snapshot != nil` so the `recordsById = snapshot` branch runs.
  /// - Log replay overlays one additional record.
  /// - `recoverInProgressVariants()` rewrites the in-progress variants to failed
  ///   across both cells (a regression that truncates recovery to a single cell would
  ///   fire here).
  /// - `rebuildCountersFromRecords()` populates `monthCounters` from the final
  ///   `recordsById`. The resulting counts must match a recompute exactly.
  @Test func configureReloadFromSnapshotPlusLogReproducesCounters() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ExportRecordStoreSnapshotReload-\(UUID().uuidString)",
        isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let dest = "test"
    let storeDir = dir.appendingPathComponent(dest, isDirectory: true)
    try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
    let now = Date(timeIntervalSince1970: 0)

    func record(
      id: String, year: Int, month: Int, variant: ExportVariant, status: ExportStatus,
      filename: String?
    ) -> ExportRecord {
      ExportRecord(
        id: id, year: year, month: month,
        relPath: "\(year)/\(String(format: "%02d", month))/",
        variants: [
          variant: ExportVariantRecord(
            filename: filename, status: status, exportDate: now, lastError: nil)
        ])
    }

    // Snapshot: 4 records across 2025-06 and 2024-12, with .inProgress in BOTH cells.
    let snapshotRecords: [String: ExportRecord] = [
      "june-done": record(
        id: "june-done", year: 2025, month: 6, variant: .original, status: .done,
        filename: "JD.HEIC"),
      "june-stuck": record(
        id: "june-stuck", year: 2025, month: 6, variant: .original, status: .inProgress,
        filename: nil),
      "dec-done": record(
        id: "dec-done", year: 2024, month: 12, variant: .original, status: .done,
        filename: "DD.HEIC"),
      "dec-stuck": record(
        id: "dec-stuck", year: 2024, month: 12, variant: .edited, status: .inProgress,
        filename: nil),
    ]
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let snapshotData = try encoder.encode(snapshotRecords)
    let snapshotURL = storeDir.appendingPathComponent(
      ExportRecordStore.Constants.snapshotFileName)
    try snapshotData.write(to: snapshotURL)

    // Log overlay: one fresh record in 2025-06 (proves snapshot+log overlay works).
    let fresh = record(
      id: "fresh", year: 2025, month: 6, variant: .original, status: .done,
      filename: "F.HEIC")
    let overlay = ExportRecordMutation.upsert(fresh)
    var logData = try encoder.encode(overlay)
    logData.append(0x0A)
    let logURL = storeDir.appendingPathComponent(ExportRecordStore.Constants.logFileName)
    try logData.write(to: logURL)

    let store = ExportRecordStore(baseDirectoryURL: dir)
    store.configure(for: dest)

    #expect(store.state == .ready)
    #expect(store.recordsById.count == 5, "4 from snapshot + 1 from log")

    // Multi-cell recovery: both stuck records transitioned to failed in their own cells.
    #expect(
      store.recordCount(year: 2025, month: 6, variant: .original, status: .inProgress) == 0)
    #expect(
      store.recordCount(year: 2024, month: 12, variant: .edited, status: .inProgress) == 0)
    #expect(
      store.recordCount(year: 2025, month: 6, variant: .original, status: .failed) == 1,
      "june-stuck recovered → .failed")
    #expect(
      store.recordCount(year: 2024, month: 12, variant: .edited, status: .failed) == 1,
      "dec-stuck recovered → .failed")

    // Snapshot+log overlay landed.
    #expect(
      store.recordCount(year: 2025, month: 6, variant: .original, status: .done) == 2,
      "june-done + fresh")
    #expect(
      store.recordCount(year: 2024, month: 12, variant: .original, status: .done) == 1,
      "dec-done")

    // Year roll-up sums across all months in scope.
    #expect(store.yearExportedCount(year: 2025) == 2)
    #expect(store.yearExportedCount(year: 2024) == 1)

    // Recompute-from-scratch sanity across both cells.
    for (year, month) in [(2025, 6), (2024, 12)] {
      var byVariantStatus: [ExportVariant: [ExportStatus: Int]] = [:]
      var bothDone = 0
      var origAtNaturalStem = 0
      for rec in store.recordsById.values where rec.year == year && rec.month == month {
        for (variant, variantRec) in rec.variants {
          byVariantStatus[variant, default: [:]][variantRec.status, default: 0] += 1
        }
        let originalDone = rec.variants[.original]?.status == .done
        let editedDone = rec.variants[.edited]?.status == .done
        if originalDone && editedDone { bothDone += 1 }
        if originalDone, !editedDone,
          let filename = rec.variants[.original]?.filename,
          !ExportFilenamePolicy.isOrigCompanion(filename: filename)
        {
          origAtNaturalStem += 1
        }
      }
      for variant in [ExportVariant.original, .edited] {
        for status in [ExportStatus.pending, .inProgress, .done, .failed] {
          let expected = byVariantStatus[variant]?[status] ?? 0
          let actual = store.recordCount(
            year: year, month: month, variant: variant, status: status)
          #expect(
            actual == expected,
            "post-reload recordCount(\(year)-\(month), \(variant), \(status)) = \(actual), expected \(expected)"
          )
        }
      }
      #expect(store.recordCountBothVariantsDone(year: year, month: month) == bothDone)
      #expect(
        store.recordCountOriginalDoneAtNaturalStem(year: year, month: month)
          == origAtNaturalStem)
    }
  }

  // MARK: - resetToEmpty post-reset counter state

  /// Closes the post-reset coverage gap from the c15c159 review: production code clears
  /// `monthCounters` in `resetToEmpty` (alongside `recordsById`), but no existing test
  /// queried any count method after a reset to verify the counters were actually
  /// cleared. A regression that left stale counters would silently survive.
  ///
  /// This test forces the store into `.failed` (corrupt-snapshot path), populates
  /// counters via the standard mutation API on a fresh store, plants a corrupt
  /// snapshot file, reloads → `.failed`, calls `resetToEmpty`, then asserts every
  /// public count method returns 0 for the previously-populated cell.
  @Test func resetToEmptyClearsCounters() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ExportRecordStoreResetClears-\(UUID().uuidString)",
        isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let dest = "test"
    let storeDir = dir.appendingPathComponent(dest, isDirectory: true)
    try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
    let now = Date(timeIntervalSince1970: 0)

    // Step 1: drive mutations on a healthy store so counters are populated.
    let storeA = ExportRecordStore(baseDirectoryURL: dir)
    storeA.configure(for: dest)
    storeA.markVariantExported(
      assetId: "x", variant: .original, year: 2025, month: 6, relPath: "2025/06/",
      filename: "X.HEIC", exportedAt: now)
    storeA.markVariantExported(
      assetId: "y", variant: .edited, year: 2025, month: 6, relPath: "2025/06/",
      filename: "Y.JPG", exportedAt: now)
    #expect(storeA.recordCount(year: 2025, month: 6, variant: .original, status: .done) == 1)
    #expect(storeA.recordCount(year: 2025, month: 6, variant: .edited, status: .done) == 1)
    storeA.flushForTesting()

    // Step 2: corrupt the snapshot on disk and reload — store transitions to .failed.
    // We have to write a file to the snapshot path to force the corrupt path; the
    // log alone won't trigger it.
    let snapshotURL = storeDir.appendingPathComponent(
      ExportRecordStore.Constants.snapshotFileName)
    try Data("not valid json".utf8).write(to: snapshotURL)
    let storeB = ExportRecordStore(baseDirectoryURL: dir)
    storeB.configure(for: dest)
    #expect(storeB.state == .failed)

    // Step 3: resetToEmpty — should clear monthCounters along with recordsById.
    storeB.resetToEmpty()
    #expect(storeB.state == .ready)
    #expect(storeB.recordsById.isEmpty)

    // Step 4: every public count method must return 0 for the previously-populated
    // cell. A regression that left stale counters in `monthCounters` after reset would
    // surface here.
    #expect(storeB.recordCount(year: 2025, month: 6, variant: .original, status: .done) == 0)
    #expect(storeB.recordCount(year: 2025, month: 6, variant: .edited, status: .done) == 0)
    #expect(storeB.recordCount(year: 2025, month: 6, variant: .original, status: .failed) == 0)
    #expect(storeB.recordCountBothVariantsDone(year: 2025, month: 6) == 0)
    #expect(storeB.recordCountOriginalDoneAtNaturalStem(year: 2025, month: 6) == 0)
    #expect(storeB.recordCountEditedDone(year: 2025, month: 6) == 0)
    #expect(storeB.recordCountEditedFallback(year: 2025, month: 6) == 0)
    #expect(storeB.yearExportedCount(year: 2025) == 0)
    let summary = storeB.monthSummary(year: 2025, month: 6, totalAssets: 5)
    #expect(summary.exportedCount == 0)
    #expect(summary.status == .notExported)
  }
}
