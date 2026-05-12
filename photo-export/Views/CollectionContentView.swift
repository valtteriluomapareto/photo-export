import AppKit
import Photos
import SwiftUI

/// Asset-grid content view for a single collection selection (Favorites or one album).
/// Shares `MonthViewModel`'s scope-based loader; mirrors `MonthContentView`'s layout but
/// reads export status from `CollectionExportRecordStore` and starts collection-aware
/// exports.
struct CollectionContentView: View {
  @EnvironmentObject private var photoLibraryManager: PhotoLibraryManager
  @EnvironmentObject private var collectionExportRecordStore: CollectionExportRecordStore
  @EnvironmentObject private var exportManager: ExportManager
  @EnvironmentObject private var exportDestinationManager: ExportDestinationManager

  @StateObject private var viewModel: MonthViewModel

  let selection: LibrarySelection
  let title: String
  @Binding var selectedAsset: AssetDescriptor?

  init(
    selection: LibrarySelection,
    title: String,
    selectedAsset: Binding<AssetDescriptor?>,
    photoLibraryService: any PhotoLibraryService
  ) {
    self.selection = selection
    self.title = title
    self._selectedAsset = selectedAsset
    _viewModel = StateObject(
      wrappedValue: MonthViewModel(photoLibraryService: photoLibraryService))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(.title2)
        .fontWeight(.semibold)
        .padding(.top, 8)

      HStack {
        exportSummaryView
        Spacer()
        Button(exportButtonTitle) {
          startExport()
        }
        .buttonStyle(.bordered)
        .disabled(!canExport)
        .help(exportButtonHelp)
      }

      ScrollView {
        let columns = [
          GridItem(.adaptive(minimum: 100, maximum: 160), spacing: 10, alignment: .top)
        ]
        LazyVGrid(columns: columns, spacing: 10) {
          ForEach(viewModel.assets) { asset in
            ThumbnailView(
              asset: asset,
              state: viewModel.thumbnailState(for: asset),
              isSelected: asset.id == selectedAsset?.id,
              isExported: isExported(asset: asset),
              onRetry: { viewModel.retryThumbnail(for: asset.id) }
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
    .task(id: scopeTaskId) {
      await viewModel.loadAssets(for: scope)
      if selectedAsset == nil,
        let id = viewModel.selectedAssetId,
        let initialAsset = viewModel.assets.first(where: { $0.id == id })
      {
        selectedAsset = initialAsset
      }
    }
    .onChange(of: exportManager.isRunning) { _, newValue in
      viewModel.setExportRunning(newValue)
    }
  }

  // MARK: - Scope plumbing

  private var scope: PhotoFetchScope {
    switch selection {
    case .timelineMonth(let year, let month):
      return .timeline(year: year, month: month)
    case .favorites: return .favorites
    case .album(let id): return .album(collectionId: id)
    case .folder:
      // Unreachable: `LibraryRootView` routes folder selections to `FolderContentView`.
      // Returning `.favorites` is a safe default that never gets observed.
      return .favorites
    }
  }

  /// Re-runs the asset-load `.task` whenever the user picks a different scope. The
  /// `libraryRevision` counter is intentionally **not** included here: any
  /// `photoLibraryDidChange` (favoriting a single photo elsewhere, adding to an
  /// unrelated album) would otherwise blank the entire grid through the `assets = []`
  /// path inside `MonthViewModel.loadAssets(for:)` while a fresh fetch loads. The
  /// sidebar's count refresh and tree refresh still observe `libraryRevision`; the user
  /// can re-select the album to force a grid refetch when they know the contents
  /// changed.
  private var scopeTaskId: String { scopeKey }

  private var scopeKey: String {
    switch selection {
    case .timelineMonth(let year, let month): return "timeline:\(year)-\(month)"
    case .favorites: return "favorites"
    case .album(let id): return "album:\(id)"
    case .folder(let id): return "folder:\(id)"  // Unreachable; see `scope`.
    }
  }

  // MARK: - Placement lookup

  /// Persisted placement for this selection, if any. Nil before the first export run
  /// against a freshly-discovered album. The summary header treats nil as
  /// "no records yet" so the count shows `0/N`.
  private var placement: ExportPlacement? {
    switch selection {
    case .favorites:
      return collectionExportRecordStore.placement(id: ExportPlacement.favorites().id)
    case .album(let id):
      return collectionExportRecordStore.placements(matching: .album)
        .first(where: { $0.collectionLocalIdentifier == id })
    case .timelineMonth, .folder:
      return nil
    }
  }

  private func isExported(asset: AssetDescriptor) -> Bool {
    guard let placement else { return false }
    return collectionExportRecordStore.isExported(
      asset: asset, placement: placement, selection: exportManager.versionSelection)
  }

  // MARK: - Header summary

  private var exportSummaryView: some View {
    let summary = makeSummary()
    return HStack(spacing: 8) {
      switch summary.status {
      case .complete:
        Label(
          "\(summary.exportedCount)/\(summary.totalCount) exported",
          systemImage: "checkmark.circle.fill"
        ).foregroundColor(.green)
      case .partial:
        Label(
          "\(summary.exportedCount)/\(summary.totalCount) exported",
          systemImage: "circle.lefthalf.filled"
        ).foregroundColor(.orange)
      case .notExported:
        Label("0/\(summary.totalCount) exported", systemImage: "circle")
          .foregroundColor(.secondary)
      }
      Spacer()
    }
    .font(.subheadline)
  }

  private func makeSummary() -> MonthStatusSummary {
    if let placement {
      return collectionExportRecordStore.monthSummary(
        assets: viewModel.assets, placement: placement,
        selection: exportManager.versionSelection)
    }
    return MonthStatusSummary(
      year: 0, month: 0, exportedCount: 0,
      totalCount: viewModel.assets.count, status: .notExported)
  }

  // MARK: - Export button

  private var canExport: Bool {
    exportDestinationManager.canExportNow && exportManager.canExportCollection
  }

  private var exportButtonTitle: String {
    switch selection {
    case .favorites: return "Export Favorites"
    case .album: return "Export Album"
    case .timelineMonth: return "Export Month"
    case .folder: return "Export Folder"  // Unreachable; see `scope`.
    }
  }

  private var exportButtonHelp: String {
    if !exportDestinationManager.canExportNow {
      return "Select a writable export folder first"
    }
    if !exportManager.canExportCollection {
      return "Collections store is not ready"
    }
    return "Export every photo in this collection that isn't already exported."
  }

  private func startExport() {
    switch selection {
    case .favorites:
      exportManager.startExportFavorites()
    case .album(let id):
      exportManager.startExportAlbum(collectionId: id)
    case .timelineMonth(let year, let month):
      exportManager.startExportMonth(year: year, month: month)
    case .folder:
      break  // Unreachable; see `scope`.
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
}
