import AppKit
import Photos
import SwiftUI

/// Asset-grid content view for a single collection selection (Favorites or one album).
/// Shares `MonthViewModel`'s scope-based loader; mirrors `MonthContentView`'s layout but
/// reads export status from `CollectionExportRecordStore` and starts collection-aware
/// exports.
/// Receives only rendering settings/actions from the manager-owning parent. As in
/// MonthContentView, `.equatable()` at every call site filters fresh action closures
/// on unrelated queue publications. Record/library/destination observations stay live.
struct CollectionContentView: View, Equatable {
  @EnvironmentObject private var photoLibraryManager: PhotoLibraryManager
  @EnvironmentObject private var collectionExportRecordStore: CollectionExportRecordStore
  @EnvironmentObject private var exportDestinationManager: ExportDestinationManager
  #if DEBUG
    @Environment(\.bodyInvalidationCounter) private var bodyCounter
  #endif

  @StateObject private var viewModel: MonthViewModel

  let selection: LibrarySelection
  let title: String
  let versionSelection: ExportVersionSelection
  let livePhotosPaired: Bool
  let onExportCollection: () -> Void
  // Capture the value at construction: comparing two live Binding getters would
  // read the same current value after a parent selection mutation.
  private let selectedAssetId: String?
  @Binding var selectedAsset: AssetDescriptor?

  init(
    selection: LibrarySelection,
    title: String,
    versionSelection: ExportVersionSelection,
    livePhotosPaired: Bool,
    onExportCollection: @escaping () -> Void,
    selectedAsset: Binding<AssetDescriptor?>,
    photoLibraryService: any PhotoLibraryService
  ) {
    self.selection = selection
    self.title = title
    self.versionSelection = versionSelection
    self.livePhotosPaired = livePhotosPaired
    self.onExportCollection = onExportCollection
    self.selectedAssetId = selectedAsset.wrappedValue?.id
    self._selectedAsset = selectedAsset
    _viewModel = StateObject(
      wrappedValue: MonthViewModel(photoLibraryService: photoLibraryService))
  }

  var body: some View {
    let placement = currentPlacement
    #if DEBUG
      // Required as a declaration inside the ViewBuilder.
      // swiftlint:disable:next redundant_discardable_let
      let _ = recordRenderingInputs()
    #endif
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(.title2)
        .fontWeight(.semibold)
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.top, 8)

      if showsReducedQualityBanner {
        sharedAlbumBanner
      }

      HStack {
        exportSummaryView(placement: placement)
        Spacer()
        AutoSyncAwareExportButton(exportButtonTitle) {
          onExportCollection()
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
              isSelected: asset.id == selectedAsset?.id,
              isExported: isExported(asset: asset, placement: placement)
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
    }
    .onDisappear { viewModel.deactivate() }
    .onReceive(viewModel.selectionUpdates) { _ in
      // The model emits after an owned commit. Derive from the live binding
      // and write synchronously, so no queued pane can undo newer navigation.
      guard
        let update = viewModel.selectionUpdate(
          for: scope, preferredAssetId: selectedAsset?.id)
      else { return }
      if selectedAsset != update.asset { selectedAsset = update.asset }
      if viewModel.selectedAssetId != update.asset?.id {
        viewModel.select(assetId: update.asset?.id)
      }
    }
    // Same iCloud-sync / Photos.app-edit refresh path as `MonthContentView`. The
    // earlier note about `libraryRevision` blanking this grid no longer applies — the
    // view model's `refresh(for:)` updates `assets` in place rather than clearing
    // first, so adding the observer here is now safe.
    .onChange(of: photoLibraryManager.libraryRevision) { _, _ in
      Task {
        await viewModel.refresh(for: scope)
        #if DEBUG
          bodyCounter?.record("grid-refresh-finished")
        #endif
      }
    }
    .measureBodyInvalidations("CollectionContentView")
  }

  #if DEBUG
    private func recordRenderingInputs() {
      bodyCounter?.record("collectionBody")
      bodyCounter?.record("scope:\(scopeTaskId)")
      bodyCounter?.recordAction("collectionExport", action: onExportCollection)
      bodyCounter?.record("selected:\(selectedAsset?.id ?? "")")
      bodyCounter?.record("title:\(title)")
      bodyCounter?.record("banner:\(showsReducedQualityBanner)")
      bodyCounter?.record("canExport:\(canExport)")
    }
  #endif

  // MARK: - Scope plumbing

  private var scope: PhotoFetchScope {
    switch selection {
    case .timelineMonth(let year, let month):
      return .timeline(year: year, month: month)
    case .timelineYear(let year):
      // Unreachable: `LibraryRootView` routes year selections to `YearContentView`.
      // `.timeline(year: month: nil)` is the closest equivalent if it ever lands here.
      return .timeline(year: year, month: nil)
    case .favorites: return .favorites
    case .album(let id): return .album(collectionId: id)
    case .sharedAlbum(let id): return .sharedAlbum(collectionId: id)
    case .folder:
      // Unreachable: `LibraryRootView` routes folder selections to `FolderContentView`.
      // Returning `.favorites` is a safe default that never gets observed.
      return .favorites
    }
  }

  /// True when the user is viewing an iCloud shared album. Used for the placement
  /// lookup and the export button label/route.
  private var isSharedAlbum: Bool {
    if case .sharedAlbum = selection { return true }
    return false
  }

  /// The reduced-fidelity banner shows only when the user has "Include originals"
  /// on AND the current scope is a shared album — that's when the toggle's promise
  /// (a `_orig` companion for edited photos) breaks down, so the warning is
  /// actionable. With "Include originals" off, the per-asset behaviour for shared
  /// albums (one downscaled JPEG written) is indistinguishable from non-edited
  /// owned-library assets, so the banner would be noise. Users who want the full
  /// caveat in writing still get it from the website's Features page.
  private var showsReducedQualityBanner: Bool {
    isSharedAlbum && versionSelection == .editedWithOriginals
  }

  /// Caution-style banner shown above the export controls when the user has
  /// "Include originals" on AND is viewing a shared album. Visual treatment
  /// (yellow triangle glyph, warm tinted background, semibold title leading with
  /// the consequence) matches how Photos / Mail / System Settings surface
  /// "this option doesn't apply here" caveats — readers should see a caution at
  /// a glance, not a tip.
  ///
  /// Layout constraints stay explicit (`frame(maxWidth: .infinity, alignment:
  /// .leading)`) and no `fixedSize(...)` / `Spacer` / `firstTextBaseline` chain
  /// is used, because a prior version of this view triggered a window-chrome
  /// collapse cascade on macOS via that combination.
  @ViewBuilder
  private var sharedAlbumBanner: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.yellow)
        .padding(.top, 2)
      VStack(alignment: .leading, spacing: 2) {
        Text("Shared albums export at reduced quality")
          .font(.subheadline)
          .fontWeight(.semibold)
        Text(
          "iCloud only serves shared photos as downscaled JPEGs, so Include "
            + "originals is ignored here. Photo Export saves the best version "
            + "Apple provides."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .background(Color.yellow.opacity(0.12))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(Color.yellow.opacity(0.35), lineWidth: 0.5)
    )
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  /// Re-runs the asset-load `.task` whenever the user picks a different scope. The
  /// `libraryRevision` counter is intentionally **not** included here: any
  /// `photoLibraryDidChange` (favoriting a single photo elsewhere, adding to an
  /// unrelated album) would otherwise blank the entire grid through the `assets = []`
  /// path inside `MonthViewModel.loadAssets(for:)` while a fresh fetch loads. The
  /// sidebar's count refresh and tree refresh still observe `libraryRevision`, while
  /// the grid refreshes its assets in place through the separate observer above.
  private var scopeTaskId: String { scopeKey }

  private var scopeKey: String {
    switch selection {
    case .timelineMonth(let year, let month): return "timeline:\(year)-\(month)"
    case .timelineYear(let year): return "timeline:\(year)"  // Unreachable; see `scope`.
    case .favorites: return "favorites"
    case .album(let id): return "album:\(id)"
    case .sharedAlbum(let id): return "shared-album:\(id)"
    case .folder(let id): return "folder:\(id)"  // Unreachable; see `scope`.
    }
  }

  // MARK: - Placement lookup

  /// Persisted placement for this selection, if any. Nil before the first export run
  /// against a freshly-discovered album. The summary header treats nil as
  /// "no records yet" so the count shows `0/N`.
  private var currentPlacement: ExportPlacement? {
    let tree: [PhotoCollectionDescriptor]
    if selection == .favorites {
      tree = []
    } else {
      guard let current = try? photoLibraryManager.fetchCollectionTree() else { return nil }
      tree = current
    }
    return collectionExportRecordStore.currentPlacement(for: selection, collections: tree)
  }

  private func isExported(asset: AssetDescriptor, placement: ExportPlacement?) -> Bool {
    guard let placement else { return false }
    return collectionExportRecordStore.isExported(
      asset: asset, placement: placement, selection: versionSelection,
      livePhotosPaired: livePhotosPaired)
  }

  // MARK: - Header summary

  private func exportSummaryView(placement: ExportPlacement?) -> some View {
    let summary = makeSummary(placement: placement)
    #if DEBUG
      bodyCounter?.record("summary:\(summary.exportedCount)/\(summary.totalCount)")
      bodyCounter?.recordText(
        ["\(summary.exportedCount)/\(summary.totalCount)"], for: "collection-summary")
    #endif
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

  private func makeSummary(placement: ExportPlacement?) -> MonthStatusSummary {
    if let placement {
      #if DEBUG
        bodyCounter?.record("summaryScan")
      #endif
      return collectionExportRecordStore.monthSummary(
        assets: viewModel.assets, placement: placement,
        selection: versionSelection,
        livePhotosPaired: livePhotosPaired)
    }
    return MonthStatusSummary(
      year: 0, month: 0, exportedCount: 0,
      totalCount: viewModel.assets.count, status: .notExported)
  }

  // MARK: - Export button

  private var canExport: Bool {
    exportDestinationManager.canExportNow && collectionExportRecordStore.state == .ready
  }

  private var exportButtonTitle: String {
    switch selection {
    case .favorites: return "Export Favorites"
    case .album: return "Export Album"
    case .sharedAlbum: return "Export Shared Album"
    case .timelineMonth: return "Export Month"
    case .timelineYear: return "Export Year"  // Unreachable; see `scope`.
    case .folder: return "Export Folder"  // Unreachable; see `scope`.
    }
  }

  private var exportButtonHelp: String {
    if !exportDestinationManager.canExportNow {
      return "Select a writable export folder first"
    }
    if collectionExportRecordStore.state != .ready {
      return "Collections store is not ready"
    }
    return "Export every photo in this collection that isn't already exported."
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

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.selection == rhs.selection
      && lhs.title == rhs.title
      && lhs.versionSelection == rhs.versionSelection
      && lhs.livePhotosPaired == rhs.livePhotosPaired
      && lhs.selectedAssetId == rhs.selectedAssetId
  }

}
