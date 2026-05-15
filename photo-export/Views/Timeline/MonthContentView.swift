import AppKit
import Photos
import SwiftUI

struct MonthContentView: View {
  @EnvironmentObject private var photoLibraryManager: PhotoLibraryManager
  @EnvironmentObject private var exportRecordStore: ExportRecordStore
  @EnvironmentObject private var exportManager: ExportManager
  @EnvironmentObject private var exportDestinationManager: ExportDestinationManager

  @StateObject private var viewModel: MonthViewModel

  let year: Int
  let month: Int
  @Binding var selectedAsset: AssetDescriptor?

  init(
    year: Int, month: Int, selectedAsset: Binding<AssetDescriptor?>,
    photoLibraryService: any PhotoLibraryService
  ) {
    self.year = year
    self.month = month
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
        Button("Export Month") {
          exportManager.startExportMonth(year: year, month: month)
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
              state: viewModel.thumbnailState(for: asset),
              isSelected: asset.id == selectedAsset?.id,
              isExported: exportRecordStore.isExported(
                asset: asset, selection: exportManager.versionSelection),
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
    .task(id: "\(year)-\(month)") {
      await viewModel.loadAssets(forYear: year, month: month)
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
      assets: viewModel.assets, selection: exportManager.versionSelection)
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

}
