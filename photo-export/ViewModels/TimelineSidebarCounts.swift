import Foundation
import Observation

/// Loader for the per-(year, month) total + adjusted asset counts the
/// timeline sidebar's `YearRow` and `MonthRow` need to compute their progress
/// badges.
///
/// Counts must load even for collapsed years so their progress badges remain
/// meaningful during export. The loader fans out async fetches for every known
/// year × month at startup, using the existing cached count APIs
/// (`PhotoLibraryService.cachedCountAssets(in:)` and
/// `cachedCountAdjustedAssets(in:)`). The `CollectionCountCache` actor
/// dedups overlapping calls, so calling `loadCounts(forYears:)` multiple
/// times is cheap. As each (year, month) pair lands, the observed snapshot
/// updates and dependent `YearRow` / `MonthRow` views re-render
/// progressively.
///
/// Cost (see `AGENTS.md` perf notes): a typical 10-year library is ~120
/// fetches, completing sub-second; a 30-year archive is ~360 fetches, a few
/// seconds of background work. None of it blocks the main actor — each
/// call to `cachedCountAssets` dispatches into `Task.detached` inside
/// `PhotoLibraryManager`, and the wrapper `await` here simply yields the
/// runloop while the detached fetch runs.
@Observable
@MainActor
final class TimelineSidebarCounts {
  struct MonthCounts: Equatable {
    let total: Int
    let adjusted: Int?
  }

  private(set) var countsByYearMonth: [String: MonthCounts] = [:]
  /// Last error encountered while fetching counts. Surfaces once so a future
  /// view-side banner can mention "couldn't load progress" without us having
  /// to thread Result types throughout the loader.
  private(set) var lastError: Error?

  @ObservationIgnored private let service: any PhotoLibraryService
  @ObservationIgnored private var generation = 0

  init(service: any PhotoLibraryService) {
    self.service = service
  }

  /// Fetches per-month total + adjusted counts for every (year ∈ years) × (month ∈ 1...12).
  /// `preferredYear` is loaded first so its badge data lands quickly even on
  /// large libraries (typically the user's currently-selected year, surfaced
  /// by `TimelineSidebarView`).
  ///
  /// Within a year, all 12 months are dispatched in parallel via a
  /// `TaskGroup`. Each child task issues its month's total + adjusted fetches
  /// concurrently via `async let`. The `cachedCount*` methods on
  /// `PhotoLibraryService` are `nonisolated async` and dispatch their work to
  /// detached tasks internally, so the actual PhotoKit fetches run on the
  /// global executor in parallel even though the per-month child tasks
  /// themselves hop back to `@MainActor` to update the observed dicts.
  /// Across years, loading is sequential — that keeps the in-flight count
  /// bounded at 12 fetches at a time even on 30-year libraries.
  func loadCounts(forYears years: [Int], preferredYear: Int? = nil) async {
    guard !Task.isCancelled else { return }
    generation &+= 1
    let gen = generation
    // Keep each previous pair visible until its replacement is ready.
    if lastError != nil { lastError = nil }
    let ordered = orderYears(years, preferredYear: preferredYear)
    for year in ordered {
      guard isCurrent(gen) else { return }
      await loadYear(year, generation: gen)
    }
  }

  /// Clears all loaded counts. Call when the user revokes Photos access or
  /// when the underlying library is replaced (e.g. signing into a different
  /// iCloud account in Photos.app). The next `loadCounts(forYears:)` will
  /// repopulate from scratch.
  func reset() {
    generation &+= 1
    if !countsByYearMonth.isEmpty { countsByYearMonth = [:] }
    if lastError != nil { lastError = nil }
  }

  // MARK: - Read helpers

  var assetCountsByYearMonth: [String: Int] {
    countsByYearMonth.mapValues(\.total)
  }

  var adjustedCountsByYearMonth: [String: Int] {
    countsByYearMonth.compactMapValues(\.adjusted)
  }

  /// Months 1...12 of `year` whose total count is non-zero. Replaces the old
  /// `computeMonthsWithAssets(for:)` view-method; the loader's dict is the
  /// new source of truth.
  func monthsWithAssets(for year: Int) -> [Int] {
    var months: [Int] = []
    for month in 1...12 where (countsByYearMonth["\(year)-\(month)"]?.total ?? 0) > 0 {
      months.append(month)
    }
    return months
  }

  // MARK: - Internals

  /// Loads one year's twelve months in parallel via a `TaskGroup`. Each
  /// child task hops back to `@MainActor` (`loadMonth(year:month:)` is
  /// `@MainActor`-isolated) to read `service` and write the observed
  /// dicts, but the underlying `cachedCount*` calls dispatch detached
  /// tasks internally — so the actual PhotoKit fetches run concurrently
  /// on the global executor.
  private func loadYear(_ year: Int, generation: Int) async {
    await withTaskGroup(of: Void.self) { group in
      for month in 1...12 {
        group.addTask { [weak self] in
          await self?.loadMonth(year: year, month: month, generation: generation)
        }
      }
    }
  }

  /// Refreshes a month's pair atomically. Initial totals can introduce a row
  /// before coverage is known; loaded pairs remain visible during refresh.
  /// A current failure clears only this month's coverage, never pairing a
  /// retained total with a fresh adjusted count.
  private func loadMonth(year: Int, month: Int, generation: Int) async {
    guard isCurrent(generation) else { return }
    async let totalTask = service.cachedCountAssets(
      in: .timeline(year: year, month: month))
    async let adjustedTask = service.cachedCountAdjustedAssets(
      in: .timeline(year: year, month: month))

    let key = "\(year)-\(month)"
    var freshTotal: Int?
    var freshAdjusted: Int?
    do {
      let total = try await totalTask
      guard isCurrent(generation) else { return }
      freshTotal = total
      if countsByYearMonth[key] == nil {
        update(MonthCounts(total: total, adjusted: nil), for: key)
      }
    } catch {
      guard isCurrent(generation) else { return }
      lastError = error
    }
    do {
      let adjusted = try await adjustedTask
      guard isCurrent(generation) else { return }
      freshAdjusted = adjusted
    } catch {
      guard isCurrent(generation) else { return }
      lastError = error
    }
    guard isCurrent(generation), let total = freshTotal ?? countsByYearMonth[key]?.total else {
      return
    }
    update(MonthCounts(total: total, adjusted: freshTotal == nil ? nil : freshAdjusted), for: key)
  }

  private func update(_ counts: MonthCounts, for key: String) {
    guard countsByYearMonth[key] != counts else { return }
    countsByYearMonth[key] = counts
  }

  private func isCurrent(_ gen: Int) -> Bool {
    gen == generation && !Task.isCancelled
  }

  private func orderYears(_ years: [Int], preferredYear: Int?) -> [Int] {
    guard let preferredYear, years.contains(preferredYear) else { return years }
    var ordered = [preferredYear]
    ordered.append(contentsOf: years.filter { $0 != preferredYear })
    return ordered
  }
}
