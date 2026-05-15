import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Phase 4a unit tests for `ExportJobPlanner`. The planner is the only place that
/// decides whether an asset becomes a job; everything around it (PhotoKit fetch,
/// pending-jobs mutation, queue counters) stays on `ExportManager` for Phase 4a and
/// moves into `ExportQueueCoordinator` in Phase 4b.
///
/// These tests pin the per-asset decision so a future regression cannot accidentally
/// enqueue work for an already-exported asset, or skip an asset that AutoSync would have
/// retried.
struct ExportJobPlannerTests {

  // MARK: - Fixtures

  private func asset(_ id: String, creationDate: Date? = Date()) -> AssetDescriptor {
    TestAssetFactory.makeAsset(id: id, creationDate: creationDate)
  }

  private let timelineJuly = ExportPlacement.timeline(year: 2025, month: 7)
  private let favorites = ExportPlacement.favorites()

  // MARK: - plan (placement-fixed)

  @Test func plan_emptyAssets_returnsEmpty() {
    let jobs = ExportJobPlanner.plan(
      assets: [], placement: timelineJuly, selection: .edited,
      isExported: { _ in false },
      shouldSkipForRetry: { _, _, _ in false })
    #expect(jobs.isEmpty)
  }

  @Test func plan_noSkips_returnsJobForEveryAsset() {
    let assets = [asset("a1"), asset("a2"), asset("a3")]
    let jobs = ExportJobPlanner.plan(
      assets: assets, placement: timelineJuly, selection: .edited,
      isExported: { _ in false },
      shouldSkipForRetry: { _, _, _ in false })
    #expect(jobs.count == 3)
    #expect(jobs.map(\.assetLocalIdentifier) == ["a1", "a2", "a3"])
    #expect(jobs.allSatisfy { $0.placement == timelineJuly && $0.selection == .edited })
  }

  @Test func plan_isExportedSkipsAsset() {
    let assets = [asset("done"), asset("pending"), asset("also-done")]
    let exported: Set<String> = ["done", "also-done"]
    let jobs = ExportJobPlanner.plan(
      assets: assets, placement: timelineJuly, selection: .edited,
      isExported: { exported.contains($0.id) },
      shouldSkipForRetry: { _, _, _ in false })
    #expect(jobs.map(\.assetLocalIdentifier) == ["pending"])
  }

  @Test func plan_retryGateSkipsAsset() {
    let assets = [asset("retry"), asset("eligible")]
    let blockedByRetry: Set<String> = ["retry"]
    let jobs = ExportJobPlanner.plan(
      assets: assets, placement: timelineJuly, selection: .edited,
      isExported: { _ in false },
      shouldSkipForRetry: { a, _, _ in blockedByRetry.contains(a.id) })
    #expect(jobs.map(\.assetLocalIdentifier) == ["eligible"])
  }

  @Test func plan_predicateOrder_isExportedRunsBeforeRetryGate() {
    // Load-bearing: skipForAutoSyncRetry has a counter-bumping side effect. Running it
    // for assets that are already exported would inflate the skip counter. The planner
    // must check `isExported` first.
    var retryCallsForExported: [String] = []
    _ = ExportJobPlanner.plan(
      assets: [asset("already-done")], placement: timelineJuly, selection: .edited,
      isExported: { _ in true },
      shouldSkipForRetry: { a, _, _ in
        retryCallsForExported.append(a.id)
        return false
      })
    #expect(retryCallsForExported.isEmpty,
      "shouldSkipForRetry must NOT be called for assets that are already exported")
  }

  @Test func plan_placementAndSelectionThreadedThroughToShouldSkipForRetry() {
    var seenInRetryGate: [(placement: ExportPlacement, selection: ExportVersionSelection)] = []
    _ = ExportJobPlanner.plan(
      assets: [asset("a1")], placement: favorites, selection: .editedWithOriginals,
      isExported: { _ in false },
      shouldSkipForRetry: { _, p, s in
        seenInRetryGate.append((placement: p, selection: s))
        return false
      })
    #expect(seenInRetryGate.first?.placement == favorites)
    #expect(seenInRetryGate.first?.selection == .editedWithOriginals)
  }

  // MARK: - planTimelineYear

  @Test func planTimelineYear_dropsAssetsWithoutCreationDate() {
    let dated = asset("dated", creationDate: makeDate(year: 2025, month: 3, day: 15))
    let undated = asset("undated", creationDate: nil)
    let jobs = ExportJobPlanner.planTimelineYear(
      assets: [dated, undated], year: 2025, selection: .edited,
      isExported: { _ in false },
      shouldSkipForRetry: { _, _, _ in false })
    #expect(jobs.map(\.assetLocalIdentifier) == ["dated"])
  }

  @Test func planTimelineYear_placementDerivedFromAssetMonth() {
    let mar = asset("mar", creationDate: makeDate(year: 2025, month: 3, day: 15))
    let dec = asset("dec", creationDate: makeDate(year: 2025, month: 12, day: 1))
    let jobs = ExportJobPlanner.planTimelineYear(
      assets: [mar, dec], year: 2025, selection: .edited,
      isExported: { _ in false },
      shouldSkipForRetry: { _, _, _ in false })
    #expect(jobs.count == 2)
    #expect(jobs[0].placement == ExportPlacement.timeline(year: 2025, month: 3))
    #expect(jobs[1].placement == ExportPlacement.timeline(year: 2025, month: 12))
  }

  @Test func planTimelineYear_isExportedSkipsAsset() {
    let a = asset("a", creationDate: makeDate(year: 2025, month: 6, day: 1))
    let b = asset("b", creationDate: makeDate(year: 2025, month: 7, day: 1))
    let exported: Set<String> = ["a"]
    let jobs = ExportJobPlanner.planTimelineYear(
      assets: [a, b], year: 2025, selection: .edited,
      isExported: { exported.contains($0.id) },
      shouldSkipForRetry: { _, _, _ in false })
    #expect(jobs.map(\.assetLocalIdentifier) == ["b"])
  }

  @Test func planTimelineYear_retryGateSkipsAsset() {
    let a = asset("a", creationDate: makeDate(year: 2025, month: 6, day: 1))
    let b = asset("b", creationDate: makeDate(year: 2025, month: 7, day: 1))
    let jobs = ExportJobPlanner.planTimelineYear(
      assets: [a, b], year: 2025, selection: .edited,
      isExported: { _ in false },
      shouldSkipForRetry: { x, _, _ in x.id == "a" })
    #expect(jobs.map(\.assetLocalIdentifier) == ["b"])
  }

  /// Boundary test: Dec 31 23:30 GMT must derive month=12 with a GMT calendar. The
  /// planner accepts the calendar as a parameter precisely so the year/month derivation
  /// is deterministic across machines and CI runners. Without an explicit calendar a
  /// future refactor that switched to `Calendar(identifier: .gregorian)` with a
  /// non-GMT timezone could silently shift a late-December asset to January of the
  /// next year.
  @Test func planTimelineYear_decemberBoundary_withExplicitGMTCalendar() {
    var gmt = Calendar(identifier: .gregorian)
    gmt.timeZone = TimeZone(secondsFromGMT: 0)!
    var components = DateComponents()
    components.year = 2025
    components.month = 12
    components.day = 31
    components.hour = 23
    components.minute = 30
    let dateInGMT = gmt.date(from: components)!

    let dec31 = asset("dec31", creationDate: dateInGMT)
    let jobs = ExportJobPlanner.planTimelineYear(
      assets: [dec31], year: 2025, selection: .edited,
      isExported: { _ in false },
      shouldSkipForRetry: { _, _, _ in false },
      calendar: gmt)
    #expect(jobs.count == 1)
    #expect(jobs.first?.placement == ExportPlacement.timeline(year: 2025, month: 12))
  }

  @Test func planTimelineYear_predicateOrder_isExportedFirst() {
    var retryCalls: [String] = []
    let dated = asset("a", creationDate: makeDate(year: 2025, month: 6, day: 1))
    _ = ExportJobPlanner.planTimelineYear(
      assets: [dated], year: 2025, selection: .edited,
      isExported: { _ in true },
      shouldSkipForRetry: { a, _, _ in retryCalls.append(a.id); return false })
    #expect(retryCalls.isEmpty,
      "shouldSkipForRetry must NOT be called for already-exported assets")
  }

  // MARK: - Helpers

  private func makeDate(year: Int, month: Int, day: Int) -> Date {
    var c = DateComponents()
    c.year = year
    c.month = month
    c.day = day
    c.hour = 12
    return Calendar.current.date(from: c)!
  }
}
