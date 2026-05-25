import SwiftUI

/// Sidebar for the Timeline section: years → months tree. Extracted from `ContentView`
/// during the Phase 4 refactor so the same content area can host either a Timeline
/// sidebar or a Collections sidebar without duplicating the surrounding split view.
///
/// Per-(year, month) total + adjusted counts are owned by `TimelineSidebarCounts`,
/// which fans out async fetches for every year on appear so that **collapsed years'
/// progress badges populate too** (issue #20). Selection is bridged out through
/// `selection: Binding<LibrarySelection?>` so the content view receives a unified
/// selection regardless of which section is active.
struct TimelineSidebarView: View {
  @EnvironmentObject private var photoLibraryManager: PhotoLibraryManager
  @EnvironmentObject private var exportRecordStore: ExportRecordStore
  @EnvironmentObject private var exportManager: ExportManager

  /// Multi-select state bound from `LibraryRootView`. The binding filter below
  /// strips non-timeline values defensively so the sidebar can never persist a
  /// collection-shaped tag into the timeline state.
  @Binding var selectionSet: Set<LibrarySelection>

  @State private var years: [Int] = []
  @State private var expandedYears: Set<Int> = []
  @State private var assetCountsByYear: [Int: Int] = [:]
  @StateObject private var counts: TimelineSidebarCounts

  init(
    selectionSet: Binding<Set<LibrarySelection>>, photoLibraryService: any PhotoLibraryService
  ) {
    self._selectionSet = selectionSet
    _counts = StateObject(
      wrappedValue: TimelineSidebarCounts(service: photoLibraryService))
  }

  var body: some View {
    List(selection: timelineSelection) {
      Section("Photos by Year") {
        ForEach(years, id: \.self) { year in
          DisclosureGroup(
            isExpanded: Binding(
              get: { expandedYears.contains(year) },
              set: { newValue in
                if newValue {
                  expandedYears.insert(year)
                } else {
                  expandedYears.remove(year)
                }
              }
            )
          ) {
            ForEach(counts.monthsWithAssets(for: year), id: \.self) { month in
              MonthRow(
                year: year,
                month: month,
                total: counts.assetCountsByYearMonth["\(year)-\(month)"] ?? 0,
                adjusted: counts.adjustedCountsByYearMonth["\(year)-\(month)"]
              )
              .tag(LibrarySelection.timelineMonth(year: year, month: month))
            }
          } label: {
            YearRow(
              year: year,
              totalAssets: assetCountsByYear[year] ?? 0,
              totalCountsByMonth: monthTotals(for: year),
              adjustedCountsByMonth: adjustedMonths(for: year)
            )
            // Year row is selectable so multi-select can target whole years.
            // The DisclosureGroup chevron continues to drive expansion; this
            // tag only controls List's selection model.
            .tag(LibrarySelection.timelineYear(year: year))
          }
        }
      }
    }
    .navigationTitle("Photo Export")
    .onAppear { handleAppear() }
    .onChange(of: photoLibraryManager.isAuthorized) { _, new in
      if new {
        handleAppear()
      } else {
        years = []
        expandedYears.removeAll()
        assetCountsByYear.removeAll()
        counts.reset()
      }
    }
    // Self-heal after Photos.app mutations. `libraryRevision` bumps in
    // `PhotoLibraryManager.invalidateCache()` after every `photoLibraryDidChange`;
    // the underlying `CollectionCountCache` is invalidated at the same time, so
    // re-running `handleAppear` triggers fresh fetches that bypass stale cache
    // entries. Without this, a user adding/removing photos in Photos.app while
    // the sidebar is open would see stale badges until the next app launch.
    .onChange(of: photoLibraryManager.libraryRevision) { _, _ in
      handleAppear()
    }
    .measureBodyInvalidations("TimelineSidebarView")
  }

  // MARK: - Selection bridging

  /// `List(selection:)` accepts a `Set` of the row tag type for multi-select. We
  /// bridge the parent's `selectionSet` and filter writes to only the timeline-shaped
  /// values so the sidebar can never persist a stray collection-shape into the
  /// timeline's last-state slot. Setting the set to empty is allowed (e.g. clicking
  /// a List empty-area) and matches macOS conventions. Cmd+A is wired through the
  /// Edit menu in `photo_exportApp` rather than via a hidden keyboard host here —
  /// see `SelectAllSidebarItemsCommand`.
  private var timelineSelection: Binding<Set<LibrarySelection>> {
    Binding(
      get: { selectionSet.filter(\.isTimeline) },
      set: { newValue in
        let filtered = newValue.filter(\.isTimeline)
        // Preserve any non-timeline values that may live in the parent's set during
        // a section flip transition. In steady state the parent's set is always
        // section-pure, so this union is a no-op.
        let preserved = selectionSet.filter { !$0.isTimeline }
        selectionSet = filtered.union(preserved)
      }
    )
  }

  // MARK: - Helpers

  private func handleAppear() {
    guard photoLibraryManager.isAuthorized else { return }
    loadYears()
    var preferredYear: Int?
    if let monthSel = selectionSet.first(where: {
      if case .timelineMonth = $0 { return true } else { return false }
    }), case .timelineMonth(let year, _) = monthSel {
      expandedYears.insert(year)
      preferredYear = year
    }
    // Fan out per-month total + adjusted count fetches for every year. Lands
    // progressively via `@Published` updates on `counts` — collapsed years'
    // badges populate as their data arrives. The current year (if selected)
    // goes first so its data is ready by the time the user might expand it.
    let yearsCopy = years
    Task { [counts] in
      await counts.loadCounts(forYears: yearsCopy, preferredYear: preferredYear)
    }
  }

  private func loadYears() {
    let yearCounts = (try? photoLibraryManager.availableYearsWithCounts()) ?? []
    years = yearCounts.map(\.year)
    for (year, count) in yearCounts {
      assetCountsByYear[year] = count
    }
  }

  private func monthTotals(for year: Int) -> [Int: Int] {
    var map: [Int: Int] = [:]
    for month in 1...12 {
      map[month] = counts.assetCountsByYearMonth["\(year)-\(month)"] ?? 0
    }
    return map
  }

  private func adjustedMonths(for year: Int) -> [Int: Int?] {
    var map: [Int: Int?] = [:]
    for month in 1...12 {
      map[month] = counts.adjustedCountsByYearMonth["\(year)-\(month)"]
    }
    return map
  }
}
