import AppKit
import Photos
import SwiftUI

/// Asset-grid pane for a single (year, month). `LibraryRootView` passes the export
/// settings as plain values and supplies the Export Month action as a closure.
/// This keeps the grid's rendering inputs independent of the parent's other dependencies.
///
/// Equatable layout inputs filter fresh action closures from the parent. Selection and
/// record status belong to child tiles, while the header owns aggregate status reads.
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
  /// Binding-only callers retain selection equality; the shared owner lets the window omit that read.
  private let selectionOwner: AssetSelectionModel?
  private let selectedAssetId: String?
  @Binding var selectedAsset: AssetDescriptor?

  init(
    year: Int,
    month: Int,
    versionSelection: ExportVersionSelection,
    livePhotosPaired: Bool,
    onExportMonth: @escaping () -> Void,
    selectedAsset: Binding<AssetDescriptor?>,
    photoLibraryService: any PhotoLibraryService,
    assetSelection: AssetSelectionModel? = nil
  ) {
    self.year = year
    self.month = month
    self.versionSelection = versionSelection
    self.livePhotosPaired = livePhotosPaired
    self.onExportMonth = onExportMonth
    self._selectedAsset = selectedAsset
    self.selectionOwner = assetSelection
    self.selectedAssetId = assetSelection == nil ? selectedAsset.wrappedValue?.id : nil
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
      let _ = bodyCounter?.record("month-grid-body")
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
        TimelineGridSummary(
          assets: viewModel.assets, hasCompleteSnapshot: viewModel.hasCompleteSnapshot,
          versionSelection: versionSelection, livePhotosPaired: livePhotosPaired
        )
        .equatable()
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
            TimelineAssetTile(
              asset: asset, versionSelection: versionSelection, livePhotosPaired: livePhotosPaired,
              selectedAsset: $selectedAsset, onSelect: { viewModel.select(assetId: asset.id) })
          }
        }
        .padding(.top, 4)
      }
    }
    .padding(.horizontal)
    .overlay(overlayViews)
    .task(id: "\(year)-\(month)") {
      let query = PhotoLibraryQuery(scope: .timeline(year: year, month: month))
      let source = photoLibraryManager.libraryRefresh.sourceRevision(for: query)
      await viewModel.loadAssets(
        for: .timeline(year: year, month: month),
        isCurrent: {
          photoLibraryManager.libraryRefresh.sourceRevision(for: query) == source
        })
    }
    .onAppear {
      photoLibraryManager.beginObservingQuery(
        PhotoLibraryQuery(scope: .timeline(year: year, month: month)))
    }
    .onChange(of: PhotoLibraryQuery(scope: .timeline(year: year, month: month))) { old, new in
      photoLibraryManager.endObservingQuery(old)
      photoLibraryManager.beginObservingQuery(new)
    }
    .onDisappear {
      photoLibraryManager.endObservingQuery(
        PhotoLibraryQuery(scope: .timeline(year: year, month: month)))
      viewModel.deactivate()
    }
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
    // Refresh affected queries in place, retaining visible assets and selection while loading.
    .onChange(
      of: photoLibraryManager.libraryRefresh.queryRefresh(
        for: PhotoLibraryQuery(scope: .timeline(year: year, month: month)))
    ) { old, new in
      guard old.query == new.query else { return }
      Task {
        let query = PhotoLibraryQuery(scope: .timeline(year: year, month: month))
        let source = photoLibraryManager.libraryRefresh.sourceRevision(for: query)
        await viewModel.refresh(
          for: .timeline(year: year, month: month),
          isCurrent: {
            photoLibraryManager.libraryRefresh.sourceRevision(for: query) == source
          })
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

  /// Action closures and selection bindings are consumed by children, independently of layout.
  nonisolated static func == (lhs: MonthContentView, rhs: MonthContentView) -> Bool {
    lhs.year == rhs.year
      && lhs.month == rhs.month
      && lhs.versionSelection == rhs.versionSelection
      && lhs.livePhotosPaired == rhs.livePhotosPaired
      && lhs.selectionOwner === rhs.selectionOwner
      && lhs.selectedAssetId == rhs.selectedAssetId
  }
}
