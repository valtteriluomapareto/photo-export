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

  @Binding var selection: LibrarySelection?

  @State private var years: [Int] = []
  @State private var expandedYears: Set<Int> = []
  @State private var assetCountsByYear: [Int: Int] = [:]
  @StateObject private var counts: TimelineSidebarCounts

  init(selection: Binding<LibrarySelection?>, photoLibraryService: any PhotoLibraryService) {
    self._selection = selection
    _counts = StateObject(
      wrappedValue: TimelineSidebarCounts(service: photoLibraryService))
  }

  var body: some View {
    List(selection: yearMonthSelection) {
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
  }

  // MARK: - Selection bridging

  /// `List(selection:)` always wants the same value type as its tags. We bridge
  /// `Binding<LibrarySelection?>` so that timeline-tagged rows can drive the unified
  /// selection state without losing the section's last-selected month when the user
  /// flips the segmented control to Collections and back.
  private var yearMonthSelection: Binding<LibrarySelection?> {
    Binding(
      get: { selection },
      set: { newValue in
        if let newValue, case .timelineMonth = newValue {
          selection = newValue
        }
      }
    )
  }

  // MARK: - Helpers

  private func handleAppear() {
    guard photoLibraryManager.isAuthorized else { return }
    loadYears()
    var preferredYear: Int?
    if case .timelineMonth(let year, _) = selection {
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
