import SwiftUI

/// Content pane shown when a year row is the focused selection. Renders a Photos.app-style
/// month-tile grid (12 months, 4-up cover thumbnails per tile) so the year overview reads
/// the same as the Collections folder overview. Clicking a tile navigates into the
/// matching `MonthContentView`; the primary action stays "Export Year".
///
/// Per-month counts come from `TimelineSidebarCounts`, reused here so a tile's "fully
/// exported" badge agrees with the sidebar's `YearRow` / `MonthRow` badges without us
/// having to re-derive the formula.
struct YearContentView: View {
  @EnvironmentObject private var photoLibraryManager: PhotoLibraryManager
  @EnvironmentObject private var exportRecordStore: ExportRecordStore
  @EnvironmentObject private var exportManager: ExportManager
  @EnvironmentObject private var exportDestinationManager: ExportDestinationManager

  let year: Int
  @Binding var selection: LibrarySelection?
  @Binding var selectedAsset: AssetDescriptor?

  private let photoLibraryService: any PhotoLibraryService
  @StateObject private var counts: TimelineSidebarCounts

  init(
    year: Int,
    selection: Binding<LibrarySelection?>,
    selectedAsset: Binding<AssetDescriptor?>,
    photoLibraryService: any PhotoLibraryService
  ) {
    self.year = year
    self._selection = selection
    self._selectedAsset = selectedAsset
    self.photoLibraryService = photoLibraryService
    _counts = StateObject(
      wrappedValue: TimelineSidebarCounts(service: photoLibraryService))
  }

  @State private var totalCount: Int?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(String(year))
        .font(.title2)
        .fontWeight(.semibold)
        .padding(.top, 8)

      HStack {
        summaryView
        Spacer()
        Button("Export Year") {
          exportManager.startExportYear(year: year)
        }
        .buttonStyle(.bordered)
        .disabled(!exportDestinationManager.canExportNow)
        .help(
          exportDestinationManager.canExportNow
            ? "Export every photo in this year"
            : "Select a writable export folder first"
        )
      }

      monthGrid

      Spacer(minLength: 0)
    }
    .padding(.horizontal)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .task(id: "\(year)|\(photoLibraryManager.libraryRevision)") {
      totalCount = (try? photoLibraryManager.countAssets(year: year))
      selectedAsset = nil
      await counts.loadCounts(forYears: [year])
    }
  }

  private var summaryView: some View {
    HStack(spacing: 8) {
      Image(systemName: "calendar")
        .foregroundStyle(.secondary)
      if let totalCount {
        Text(totalCount == 1 ? "1 photo" : "\(totalCount) photos")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      } else {
        Text("Counting…")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: - Month grid

  @ViewBuilder
  private var monthGrid: some View {
    let months = counts.monthsWithAssets(for: year)
    if months.isEmpty {
      // Either counts haven't landed yet or this year has no photos. The
      // sidebar can only reach `YearContentView` for years that
      // `availableYearsWithCounts()` returned, so the steady-state branch is
      // "loading" rather than "empty year".
      VStack {
        Spacer()
        ProgressView().controlSize(.small)
        Spacer()
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ScrollView {
        let columns = [
          GridItem(
            .adaptive(minimum: MonthTileView.tileSide, maximum: MonthTileView.tileSide + 16),
            spacing: 16, alignment: .top)
        ]
        LazyVGrid(columns: columns, spacing: 20) {
          ForEach(months, id: \.self) { month in
            Button {
              navigate(toMonth: month)
            } label: {
              MonthTileView(
                year: year,
                month: month,
                photoCount: counts.assetCountsByYearMonth["\(year)-\(month)"],
                isFullyExported: isMonthFullyExported(month: month),
                photoLibraryService: photoLibraryService
              )
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.top, 4)
        .padding(.bottom, 16)
      }
    }
  }

  // MARK: - Export status

  /// Mirrors the sidebar's records-only formula via
  /// `ExportRecordStore.sidebarSummary(...)`. Returns `false` while the adjusted count
  /// for the month is still loading so a tile doesn't briefly flash a checkmark before
  /// the data lands.
  private func isMonthFullyExported(month: Int) -> Bool {
    let key = "\(year)-\(month)"
    let total = counts.assetCountsByYearMonth[key] ?? 0
    guard total > 0 else { return false }
    let adjusted = counts.adjustedCountsByYearMonth[key]
    guard
      let summary = exportRecordStore.sidebarSummary(
        year: year, month: month, totalCount: total, adjustedCount: adjusted,
        selection: exportManager.versionSelection)
    else { return false }
    return summary.exportedCount >= total
  }

  // MARK: - Navigation

  private func navigate(toMonth month: Int) {
    selection = .timelineMonth(year: year, month: month)
    selectedAsset = nil
  }
}
