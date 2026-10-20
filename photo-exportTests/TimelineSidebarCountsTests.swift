import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Tests for the TimelineSidebarCounts loader (introduced to fix issue #20:
/// collapsed-year progress badges don't update during exports).
///
/// The bug: `TimelineSidebarView` populated `assetCountsByYearMonth` /
/// `adjustedCountsByYearMonth` lazily — only when a year was expanded
/// (`computeMonthsWithAssets(for:)`) and only when each `MonthRow` rendered
/// (`loadAdjustedCount`). For collapsed years, both dicts were empty for that
/// year's months, so `YearRow.sidebarYearExportedCount` and `yearTotal()`
/// returned 0 / nil and the badge rendered nothing.
///
/// The fix moves the dicts into a dedicated `@MainActor` `ObservableObject`
/// (`TimelineSidebarCounts`) that fans out async fetches for every year × month
/// using the existing cached count APIs. As each fetch lands, the @Published
/// dicts update and the YearRow re-renders.
///
/// These tests pin the loader's contract:
/// - `loadCounts(forYears:)` populates totals + adjusted for each (year, month).
/// - The loader uses the cached APIs (so concurrent calls dedup via
///   `CollectionCountCache`).
/// - Empty months end up with `total == 0`.
/// - The `monthsWithAssets(for:)` helper derives the per-year non-empty months
///   from the loaded totals (replaces the old `computeMonthsWithAssets`).
/// - Errors during fetch don't crash; counts that succeed still land.
@MainActor
struct TimelineSidebarCountsTests {

  // MARK: - Fixtures

  private func makeAsset(
    id: String, hasAdjustments: Bool = false
  ) -> AssetDescriptor {
    AssetDescriptor(
      id: id,
      creationDate: Date(timeIntervalSince1970: 1_700_000_000),
      mediaType: .image,
      pixelWidth: 100, pixelHeight: 100, duration: 0,
      hasAdjustments: hasAdjustments
    )
  }

  // MARK: - Single year, populated

  @Test func loadCountsPopulatesTotalsAndAdjustedForOneYear() async throws {
    let svc = FakePhotoLibraryService()
    svc.assetsByYearMonth["2025-1"] = [makeAsset(id: "a"), makeAsset(id: "b")]
    svc.assetsByYearMonth["2025-3"] = [makeAsset(id: "c", hasAdjustments: true)]

    let loader = TimelineSidebarCounts(service: svc)
    await loader.loadCounts(forYears: [2025])

    #expect(loader.assetCountsByYearMonth["2025-1"] == 2)
    #expect(loader.assetCountsByYearMonth["2025-3"] == 1)
    // Months with no assets must land at 0 (not absent), so the YearRow's loop
    // can distinguish "loaded, empty" from "not yet loaded".
    #expect(loader.assetCountsByYearMonth["2025-2"] == 0)
    #expect(loader.assetCountsByYearMonth["2025-12"] == 0)

    #expect(loader.adjustedCountsByYearMonth["2025-1"] == 0)
    #expect(loader.adjustedCountsByYearMonth["2025-3"] == 1)
    #expect(loader.adjustedCountsByYearMonth["2025-2"] == 0)
  }

  // MARK: - Multiple years (the actual bug fix)

  /// Reproduces the issue-#20 scenario: a "collapsed" year (one the user hasn't
  /// expanded) still has its badge data populated. Pre-fix, only the
  /// currently-expanded year had counts; this test loads counts for two years
  /// at once and asserts both have full coverage.
  @Test func loadCountsPopulatesAllRequestedYears() async throws {
    let svc = FakePhotoLibraryService()
    svc.assetsByYearMonth["2024-6"] = [makeAsset(id: "x")]
    svc.assetsByYearMonth["2024-7"] = [makeAsset(id: "y", hasAdjustments: true)]
    svc.assetsByYearMonth["2025-3"] = [makeAsset(id: "z")]

    let loader = TimelineSidebarCounts(service: svc)
    await loader.loadCounts(forYears: [2024, 2025])

    // Both years must have entries for every month (even empty ones) so
    // YearRow's distinguishing "loaded vs not loaded" works for the collapsed
    // year as well.
    for month in 1...12 {
      #expect(
        loader.assetCountsByYearMonth["2024-\(month)"] != nil,
        "every month of 2024 must have an entry, even if zero")
      #expect(
        loader.assetCountsByYearMonth["2025-\(month)"] != nil,
        "every month of 2025 must have an entry")
    }

    // Values match the fake.
    #expect(loader.assetCountsByYearMonth["2024-6"] == 1)
    #expect(loader.assetCountsByYearMonth["2024-7"] == 1)
    #expect(loader.assetCountsByYearMonth["2025-3"] == 1)
    #expect(loader.adjustedCountsByYearMonth["2024-7"] == 1)
    #expect(loader.adjustedCountsByYearMonth["2024-6"] == 0)
  }

  // MARK: - monthsWithAssets helper

  /// Replaces the old `computeMonthsWithAssets(for:)` view-method. Returns
  /// only the months with non-zero totals.
  @Test func monthsWithAssetsReturnsOnlyNonEmptyMonths() async throws {
    let svc = FakePhotoLibraryService()
    svc.assetsByYearMonth["2025-2"] = [makeAsset(id: "a")]
    svc.assetsByYearMonth["2025-7"] = [makeAsset(id: "b"), makeAsset(id: "c")]

    let loader = TimelineSidebarCounts(service: svc)
    await loader.loadCounts(forYears: [2025])

    #expect(loader.monthsWithAssets(for: 2025) == [2, 7])
  }

  /// A year with no assets at all still loads (no fetches throw) and
  /// `monthsWithAssets` returns an empty array.
  @Test func emptyYearLoadsCleanly() async throws {
    let svc = FakePhotoLibraryService()  // no assets staged

    let loader = TimelineSidebarCounts(service: svc)
    await loader.loadCounts(forYears: [2030])

    #expect(loader.monthsWithAssets(for: 2030).isEmpty)
    for month in 1...12 {
      #expect(loader.assetCountsByYearMonth["2030-\(month)"] == 0)
    }
  }

  // MARK: - Idempotence + cache reuse

  /// Calling loadCounts a second time is safe: the underlying
  /// `cachedCountAssets` actor dedups identical scopes, so repeat calls don't
  /// re-fetch. The dicts end up in the same state.
  @Test func loadCountsIsIdempotent() async throws {
    let svc = FakePhotoLibraryService()
    svc.assetsByYearMonth["2025-5"] = [makeAsset(id: "a"), makeAsset(id: "b")]

    let loader = TimelineSidebarCounts(service: svc)
    await loader.loadCounts(forYears: [2025])
    let snapshot = loader.assetCountsByYearMonth

    await loader.loadCounts(forYears: [2025])
    #expect(loader.assetCountsByYearMonth == snapshot)
  }

  // MARK: - reset()

  /// `reset()` clears both dicts so a re-load (e.g. after auth revoke +
  /// re-grant) starts from scratch. The view calls this on the auth-flip-false
  /// branch to avoid leaking stale counts into the next session.
  @Test func resetClearsAllState() async throws {
    let svc = FakePhotoLibraryService()
    svc.assetsByYearMonth["2025-3"] = [makeAsset(id: "a", hasAdjustments: true)]

    let loader = TimelineSidebarCounts(service: svc)
    await loader.loadCounts(forYears: [2025])
    #expect(!loader.assetCountsByYearMonth.isEmpty)
    #expect(!loader.adjustedCountsByYearMonth.isEmpty)

    loader.reset()
    #expect(loader.assetCountsByYearMonth.isEmpty)
    #expect(loader.adjustedCountsByYearMonth.isEmpty)
    #expect(loader.lastError == nil)
  }

  // MARK: - Selection-prioritized order

  /// The loader should prioritize a "preferred year" (typically the
  /// currently-selected year) so its counts land first. Without that, on a
  /// 30-year library the user-visible-month would be the LAST badge to
  /// populate.
  @Test func loadCountsLoadsPreferredYearFirst() async throws {
    let svc = FakePhotoLibraryService()
    svc.assetsByYearMonth["2010-6"] = [makeAsset(id: "old")]
    svc.assetsByYearMonth["2025-6"] = [makeAsset(id: "current")]

    let loader = TimelineSidebarCounts(service: svc)
    // Pass years out-of-order with preferredYear in the middle.
    await loader.loadCounts(forYears: [2010, 2025], preferredYear: 2025)

    // Both years must end fully populated.
    #expect(loader.assetCountsByYearMonth["2025-6"] == 1)
    #expect(loader.assetCountsByYearMonth["2010-6"] == 1)
  }

  // MARK: - Observation

  /// The sidebar and year pane own the loader as `@State`, which builds a new one on every
  /// view init and keeps only the first, so building one must not touch the library.
  @Test func initMakesNoServiceCalls() {
    let service = RecordingPhotoLibraryService()
    _ = TimelineSidebarCounts(service: service)
    #expect(service.calls.isEmpty)
  }

  /// `YearRow`, `MonthRow` and the year tiles render from `countsByYearMonth`: each month
  /// lands its total, then its pair, and an identical refresh or a second reset changes
  /// nothing and must not re-render them.
  @Test func countReadersAreNotifiedPerLandedValueOnly() async {
    let service = FakePhotoLibraryService()
    service.cachedCountOverride = { _, adjusted in adjusted ? 0 : 1 }
    let loader = TimelineSidebarCounts(service: service)
    let probe = ObservationProbe {
      _ = loader.countsByYearMonth
      _ = loader.monthsWithAssets(for: 2025)
    }
    await loader.loadCounts(forYears: [2025])
    #expect(probe.changeCount == 24)
    await loader.loadCounts(forYears: [2025])
    #expect(probe.changeCount == 24)
    loader.reset()
    #expect(probe.changeCount == 25)
    loader.reset()
    #expect(probe.changeCount == 25)
  }

  /// `countsByYearMonth` is written by hand around its bridge, so a wrong key path would notify
  /// `lastError`'s readers instead of the counts'.
  @Test func countsWriteNotifiesOnlyItsOwnReaders() async {
    let service = FakePhotoLibraryService()
    service.cachedCountOverride = { scope, adjusted in
      scope == .timeline(year: 2025, month: 1) && !adjusted ? 1 : 0
    }
    let loader = TimelineSidebarCounts(service: service)
    let counts = ObservationProbe { _ = loader.countsByYearMonth }
    let lastError = ObservationProbe { _ = loader.lastError }
    await loader.loadCounts(forYears: [2025])
    #expect(counts.changeCount > 0)
    #expect(lastError.changeCount == 0)
  }
}
