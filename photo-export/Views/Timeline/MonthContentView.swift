import AppKit
import Photos
import SwiftUI

/// Asset-grid pane for a single (year, month). Intentionally does *not* hold
/// `ExportManager` as `@EnvironmentObject` — that would subscribe the body (and
/// therefore the `LazyVGrid` re-evaluation) to every `ExportManager.objectWillChange`
/// emission, of which there are several per job during a run (sink'd `queueCount`,
/// activeRunContext transitions, etc.). Instead the parent (`LibraryRootView`)
/// reads the few fields we need from its own subscription and passes them in as
/// plain values, plus a closure for the Export Month action.
///
/// **Equatable + `.equatable()` at the call site** is load-bearing. `LibraryRootView`
/// still subscribes to `ExportManager` (it reads other fields), so its `body`
/// re-evaluates on every manager emission and constructs a *new* `MonthContentView`
/// value each time — the `onExportMonth` closure is a fresh allocation per render.
/// Without the explicit `Equatable` conformance below, SwiftUI's struct-diff would
/// see the new closure as a "changed" property and re-evaluate this body anyway.
/// The conformance compares only the value fields that actually affect rendering
/// (`year`, `month`, `versionSelection`, `livePhotosPaired`, the bound asset id);
/// the closure and the binding wrapper are excluded so SwiftUI short-circuits the
/// LazyVGrid re-evaluation when those rendering inputs are unchanged.
struct MonthContentView: View, Equatable {
  @EnvironmentObject private var photoLibraryManager: PhotoLibraryManager
  @EnvironmentObject private var exportRecordStore: ExportRecordStore
  @EnvironmentObject private var exportDestinationManager: ExportDestinationManager

  @StateObject private var viewModel: MonthViewModel

  let year: Int
  let month: Int
  /// Active version selection (`.edited` vs `.editedWithOriginals`). Passed in by the
  /// parent so this view doesn't have to subscribe to `ExportManager`. Changes rarely
  /// (the user toggles "Include Originals") — the parent's body re-render fan-in is
  /// fine.
  let versionSelection: ExportVersionSelection
  /// Live Photo paired-export toggle snapshot (issue #49). Same rationale as
  /// `versionSelection`: passed in by the parent so the month grid doesn't subscribe to
  /// `ExportManager` directly. Drives the asset-complete check on the header summary so
  /// a Live Photo whose paired video is pending isn't reported as complete.
  let livePhotosPaired: Bool
  /// Closure that triggers the "Export Month" action. Owned by the parent so we can
  /// avoid touching `ExportManager` here.
  let onExportMonth: () -> Void
  @Binding var selectedAsset: AssetDescriptor?

  init(
    year: Int,
    month: Int,
    versionSelection: ExportVersionSelection,
    livePhotosPaired: Bool,
    onExportMonth: @escaping () -> Void,
    selectedAsset: Binding<AssetDescriptor?>,
    photoLibraryService: any PhotoLibraryService
  ) {
    self.year = year
    self.month = month
    self.versionSelection = versionSelection
    self.livePhotosPaired = livePhotosPaired
    self.onExportMonth = onExportMonth
    self._selectedAsset = selectedAsset
    _viewModel = StateObject(
      wrappedValue: MonthViewModel(photoLibraryService: photoLibraryService))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      // Header with Month and Year
      Text("\(MonthFormatting.name(for: month)) \(String(year))")
        .font(.title2)
        .fontWeight(.semibold)
        .padding(.top, 8)

      // Export summary with action
      HStack {
        exportSummaryView
        Spacer()
        AutoSyncAwareExportButton("Export Month") {
          onExportMonth()
        }
        .buttonStyle(.bordered)
        .disabled(!exportDestinationManager.canExportNow)
        .help(
          exportDestinationManager.canExportNow
            ? "Export unexported assets for this month"
            : "Select a writable export folder first"
        )
      }

      // Grid of thumbnails
      ScrollView {
        let columns = [
          GridItem(.adaptive(minimum: 100, maximum: 160), spacing: 10, alignment: .top)
        ]
        LazyVGrid(columns: columns, spacing: 10) {
          ForEach(viewModel.assets) { asset in
            ThumbnailView(
              asset: asset,
              isSelected: asset.id == selectedAsset?.id,
              isExported: exportRecordStore.isExported(
                asset: asset, selection: versionSelection,
                livePhotosPaired: livePhotosPaired)
            )
            .frame(width: 120, height: 120)
            .onTapGesture {
              selectedAsset = asset
              viewModel.select(assetId: asset.id)
            }
          }
        }
        .padding(.top, 4)
      }
    }
    .padding(.horizontal)
    .overlay(overlayViews)
    .task(id: "\(year)-\(month)") {
      await viewModel.loadAssets(forYear: year, month: month)
      if selectedAsset == nil,
        let id = viewModel.selectedAssetId,
        let initialAsset = viewModel.assets.first(where: { $0.id == id })
      {
        selectedAsset = initialAsset
      }
    }
    // Photos library mutations (most commonly iCloud sync landing newly synced assets,
    // but also user edits in Photos.app) bump `libraryRevision`. Route them through the
    // view model's in-place refresh so newly added assets appear without blanking the
    // grid the user is currently looking at. The earlier "just observe `libraryRevision`
    // in `.task(id:)`" approach blanked the grid on every unrelated edit; the refresh
    // path re-fetches and diff-updates `assets` so still-present items keep their
    // thumbnails.
    .onChange(of: photoLibraryManager.libraryRevision) { _, _ in
      Task { await viewModel.refresh(for: .timeline(year: year, month: month)) }
    }
    .measureBodyInvalidations("MonthContentView")
  }

  private var overlayViews: some View {
    Group {
      if viewModel.isLoading && viewModel.assets.isEmpty {
        ProgressView("Loading assets…")
          .padding(12)
          .background(Color(.windowBackgroundColor).opacity(0.85))
          .cornerRadius(8)
      }
      if let message = viewModel.errorMessage {
        Text("Error: \(message)")
          .foregroundColor(.red)
          .padding(12)
          .background(Color(.windowBackgroundColor).opacity(0.85))
          .cornerRadius(8)
      }
    }
  }

  private var exportSummaryView: some View {
    let summary = exportRecordStore.monthSummary(
      assets: viewModel.assets, selection: versionSelection,
      livePhotosPaired: livePhotosPaired)
    return HStack(spacing: 8) {
      switch summary.status {
      case .complete:
        // `seal.fill` is Apple vocabulary for verification, not generic task completion;
        // `circle.fill` is the right glyph and matches the rest of the app.
        Label(
          "\(summary.exportedCount)/\(summary.totalCount) exported",
          systemImage: "checkmark.circle.fill"
        )
        .foregroundColor(.green)
      case .partial:
        // `arrow.triangle.2.circlepath` reads as "syncing / refreshing"; for a static
        // partial state use the half-filled circle so the glyph means "in between".
        Label(
          "\(summary.exportedCount)/\(summary.totalCount) exported",
          systemImage: "circle.lefthalf.filled"
        )
        .foregroundColor(.orange)
      case .notExported:
        Label(
          "0/\(summary.totalCount) exported", systemImage: "circle"
        )
        .foregroundColor(.secondary)
      }
      Spacer()
    }
    .font(.subheadline)
  }

  // MARK: - Equatable

  /// Compares only the value fields that affect rendering. Skips:
  /// - `onExportMonth` — a freshly-allocated closure per parent render that's
  ///   semantically identical (always `exportManager.startExportMonth(year:month:)`).
  /// - `selectedAsset` wrapper itself — compare the bound asset id directly so a
  ///   new `Binding<AssetDescriptor?>` instance per render doesn't defeat the diff.
  /// - `photoLibraryService` — injected once at init; identity is stable per
  ///   `LibraryRootView` lifetime.
  static func == (lhs: MonthContentView, rhs: MonthContentView) -> Bool {
    lhs.year == rhs.year
      && lhs.month == rhs.month
      && lhs.versionSelection == rhs.versionSelection
      && lhs.livePhotosPaired == rhs.livePhotosPaired
      && lhs.selectedAsset?.id == rhs.selectedAsset?.id
  }
}
