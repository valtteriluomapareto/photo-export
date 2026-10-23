import AppKit
import Photos
import SwiftUI

/// Asset-grid pane for a single (year, month). `LibraryRootView` passes the export
/// settings as plain values and supplies the Export Month action as a closure.
/// This keeps the grid's rendering inputs independent of the parent's other dependencies.
///
/// **Equatable + `.equatable()` at the call site** is load-bearing. When another
/// dependency rebuilds `LibraryRootView`, it constructs a new `MonthContentView`
/// with a fresh `onExportMonth` closure.
/// Without the explicit `Equatable` conformance below, SwiftUI's struct-diff would
/// see the new closure as a "changed" property and re-evaluate this body anyway.
/// The conformance compares only the value fields that actually affect rendering
/// (`year`, `month`, `versionSelection`, `livePhotosPaired`, the bound asset id);
/// the closure and the binding wrapper are excluded so SwiftUI short-circuits the
/// LazyVGrid re-evaluation when those rendering inputs are unchanged.
struct MonthContentView: View, Equatable {
  @Environment(PhotoLibraryManager.self) private var photoLibraryManager
  @Environment(ExportRecordStore.self) private var exportRecordStore
  @EnvironmentObject private var exportDestinationManager: ExportDestinationManager

  #if DEBUG
    @Environment(\.bodyInvalidationCounter) private var bodyCounter
  #endif

  @State private var viewModel: MonthViewModel

  let year: Int
  let month: Int
  /// Active version selection (`.edited` vs `.editedWithOriginals`). Passed in by the
  /// parent so this view doesn't have to subscribe to `ExportManager`. Changes rarely
  /// (the user toggles "Include Originals") — the parent's body re-render fan-in is
  /// fine.
  let versionSelection: ExportVersionSelection
  /// Live Photo paired-export toggle snapshot. Same rationale as
  /// `versionSelection`: passed in by the parent so the month grid doesn't subscribe to
  /// `ExportManager` directly. Drives the asset-complete check on the header summary so
  /// a Live Photo whose paired video is pending isn't reported as complete.
  let livePhotosPaired: Bool
  /// Closure that triggers the "Export Month" action. Owned by the parent so we can
  /// avoid touching `ExportManager` here.
  let onExportMonth: () -> Void
  private let selectedAssetId: String?
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
    self.selectedAssetId = selectedAsset.wrappedValue?.id
    self._selectedAsset = selectedAsset
    _viewModel = State(wrappedValue: MonthViewModel(photoLibraryService: photoLibraryService))
  }

  var body: some View {
    let availability = ManualExportAvailability(
      destinationCanExport: exportDestinationManager.canExportNow,
      history: exportRecordStore.state)
    let exportHelp =
      availability.unavailableHelp(
        destinationHelp: exportDestinationManager.exportUnavailableHelp)
      ?? "Export unexported assets for this month"
    #if DEBUG
      // swiftlint:disable:next redundant_discardable_let
      let _ = bodyCounter?.recordText([exportHelp], for: "month-export-help")
    #endif
    #if DEBUG
      // swiftlint:disable:next redundant_discardable_let
      let _ = bodyCounter?.record("selected:\(selectedAsset?.id ?? "")")
      // swiftlint:disable:next redundant_discardable_let
      let _ = bodyCounter?.recordText([String(viewModel.assets.count)], for: "grid-assets")
    #endif
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
        .disabled(!availability.canStart)
        .help(exportHelp)
      }

      // Grid of thumbnails
      ScrollView {
        let columns = [
          GridItem(.adaptive(minimum: 100, maximum: 160), spacing: 10, alignment: .top)
        ]
        LazyVGrid(columns: columns, spacing: 10) {
          ForEach(viewModel.assets) { asset in
            #if DEBUG
              // swiftlint:disable:next redundant_discardable_let
              let _ = bodyCounter?.record("asset-tile-body:\(asset.id)")
            #endif
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
    }
    .onDisappear { viewModel.deactivate() }
    .onReceive(viewModel.selectionUpdates) { _ in
      // The model emits after an owned commit. Derive from the live binding
      // and write synchronously, so no queued pane can undo newer navigation.
      guard
        let update = viewModel.selectionUpdate(
          for: .timeline(year: year, month: month), preferredAssetId: selectedAsset?.id)
      else { return }
      if selectedAsset != update.asset { selectedAsset = update.asset }
      if viewModel.selectedAssetId != update.asset?.id {
        viewModel.select(assetId: update.asset?.id)
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
      Task {
        await viewModel.refresh(for: .timeline(year: year, month: month))
        #if DEBUG
          bodyCounter?.record("grid-refresh-finished")
        #endif
      }
    }
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
    // Until the history is loaded its in-memory records are empty, so counts would read 0.
    let isLoadingHistory = exportRecordStore.state == .loading
    #if DEBUG
      bodyCounter?.record("summaryScan")
    #endif
    let summary = exportRecordStore.monthSummary(
      assets: viewModel.assets, selection: versionSelection,
      livePhotosPaired: livePhotosPaired)
    let exportedCount = summary.status == .notExported ? 0 : summary.exportedCount
    let text =
      isLoadingHistory
      ? ManualExportAvailability.loadingHistoryText
      : "\(exportedCount)/\(summary.totalCount) exported"
    #if DEBUG
      bodyCounter?.recordText([text], for: "month-summary")
    #endif
    return HStack(spacing: 8) {
      if isLoadingHistory {
        Label(text, systemImage: "clock")
          .foregroundColor(.secondary)
      } else {
        switch summary.status {
        case .complete:
          // `seal.fill` is Apple vocabulary for verification, not generic task completion;
          // `circle.fill` is the right glyph and matches the rest of the app.
          Label(text, systemImage: "checkmark.circle.fill")
            .foregroundColor(.green)
        case .partial:
          // `arrow.triangle.2.circlepath` reads as "syncing / refreshing"; for a static
          // partial state use the half-filled circle so the glyph means "in between".
          Label(text, systemImage: "circle.lefthalf.filled")
            .foregroundColor(.orange)
        case .notExported:
          Label(text, systemImage: "circle")
            .foregroundColor(.secondary)
        }
      }
      Spacer()
    }
    .font(.subheadline)
  }

  // MARK: - Equatable

  /// Compares only the value fields that affect rendering. Skips:
  /// - `onExportMonth` — a freshly-allocated closure per parent render that's
  ///   semantically identical (always `exportManager.startExportMonth(year:month:)`).
  /// - `selectedAsset` wrapper itself — compare the construction-time asset id so a
  ///   new `Binding<AssetDescriptor?>` instance per render doesn't defeat the diff.
  /// - `photoLibraryService` — injected once at init; identity is stable per
  ///   `LibraryRootView` lifetime.
  static func == (lhs: MonthContentView, rhs: MonthContentView) -> Bool {
    lhs.year == rhs.year
      && lhs.month == rhs.month
      && lhs.versionSelection == rhs.versionSelection
      && lhs.livePhotosPaired == rhs.livePhotosPaired
      && lhs.selectedAssetId == rhs.selectedAssetId
  }
}
