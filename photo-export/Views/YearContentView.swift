import SwiftUI

/// Content pane shown when a year row is the focused selection. Mirrors
/// `MonthContentView`'s top-of-pane summary (title, header, primary action)
/// without an asset grid — pulling every photo in a year into a grid would
/// be expensive on large libraries and the user's intent is already
/// "act on the year", not "browse it". Drilling into a month gives the
/// month-level grid as today.
struct YearContentView: View {
  @EnvironmentObject private var photoLibraryManager: PhotoLibraryManager
  @EnvironmentObject private var exportRecordStore: ExportRecordStore
  @EnvironmentObject private var exportManager: ExportManager
  @EnvironmentObject private var exportDestinationManager: ExportDestinationManager

  let year: Int
  @Binding var selectedAsset: AssetDescriptor?

  private let photoLibraryService: any PhotoLibraryService

  init(
    year: Int,
    selectedAsset: Binding<AssetDescriptor?>,
    photoLibraryService: any PhotoLibraryService
  ) {
    self.year = year
    self._selectedAsset = selectedAsset
    self.photoLibraryService = photoLibraryService
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

      VStack(alignment: .leading, spacing: 8) {
        Text("Open a month to browse its photos.")
          .font(.callout)
          .foregroundStyle(.secondary)
        Text(
          "Tip: hold Cmd or Shift in the sidebar to add this year to a multi-export with other years and months."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      .padding(.top, 4)

      Spacer()
    }
    .padding(.horizontal)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .task(id: "\(year)|\(photoLibraryManager.libraryRevision)") {
      // Cheap one-shot count via the existing sync count API. Avoids the heavy
      // per-asset fetch that a grid view would require.
      totalCount = (try? photoLibraryManager.countAssets(year: year))
      selectedAsset = nil
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
}
