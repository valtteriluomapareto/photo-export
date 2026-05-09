import SwiftUI

/// Content pane shown when the user selects a folder in the Collections sidebar.
/// Renders a Photos.app-style album-tile grid for the folder's direct children
/// (subfolders + albums) and a primary "Export Folder" action that walks the entire
/// subtree. Folders are not their own placement — each descendant album exports to
/// its own existing album placement, so the on-disk layout matches what the user
/// gets from per-album exports today.
struct FolderContentView: View {
  @EnvironmentObject private var photoLibraryManager: PhotoLibraryManager
  @EnvironmentObject private var collectionExportRecordStore: CollectionExportRecordStore
  @EnvironmentObject private var exportManager: ExportManager
  @EnvironmentObject private var exportDestinationManager: ExportDestinationManager

  let folderId: String
  let title: String
  @Binding var selection: LibrarySelection?
  @Binding var selectedAsset: AssetDescriptor?

  private let photoLibraryService: any PhotoLibraryService

  init(
    folderId: String,
    title: String,
    selection: Binding<LibrarySelection?>,
    selectedAsset: Binding<AssetDescriptor?>,
    photoLibraryService: any PhotoLibraryService
  ) {
    self.folderId = folderId
    self.title = title
    self._selection = selection
    self._selectedAsset = selectedAsset
    self.photoLibraryService = photoLibraryService
  }

  @State private var folder: PhotoCollectionDescriptor?
  /// Photo counts keyed by descriptor id (album id or subfolder id). Subfolder values
  /// are recursive sums of all descendant albums.
  @State private var countsByDescriptorId: [String: Int] = [:]
  @State private var isLoadingCounts: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(.title2)
        .fontWeight(.semibold)
        .padding(.top, 8)

      HStack(alignment: .center, spacing: 12) {
        summaryView
        Spacer()
        Button(exportButtonTitle) {
          exportManager.startExportFolder(folderId: folderId)
        }
        .buttonStyle(.bordered)
        .disabled(!canExport)
        .help(exportButtonHelp)
      }

      contentBody
    }
    .padding(.horizontal)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .task(id: folderId + "|\(photoLibraryManager.libraryRevision)") {
      folder = findFolder(folderId: folderId)
      await loadCounts()
    }
  }

  // MARK: - Body branches

  @ViewBuilder
  private var contentBody: some View {
    if let folder, !folder.children.isEmpty {
      tileGrid(folder: folder)
    } else if folder != nil {
      emptyState
    } else {
      ProgressView("Loading…").controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func tileGrid(folder: PhotoCollectionDescriptor) -> some View {
    ScrollView {
      let columns = [
        GridItem(
          .adaptive(minimum: FolderTileView.tileSide, maximum: FolderTileView.tileSide + 16),
          spacing: 16, alignment: .top)
      ]
      LazyVGrid(columns: columns, spacing: 20) {
        ForEach(folder.children, id: \.id) { child in
          Button {
            navigate(to: child)
          } label: {
            FolderTileView(
              descriptor: child,
              photoCount: countsByDescriptorId[child.id],
              albumCount: child.kind == .folder
                ? PhotoCollectionDescriptor.albumLocalIds(under: child).count
                : 0,
              isFullyExported: child.kind == .album && isAlbumFullyExported(child),
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

  private var emptyState: some View {
    VStack {
      Spacer()
      Text("This folder is empty")
        .foregroundColor(.secondary)
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Summary header

  private var summaryView: some View {
    let albumIds = folder.map(PhotoCollectionDescriptor.albumLocalIds(under:)) ?? []
    let albumCount = albumIds.count
    let exported = exportedPhotoCount(albumIds: albumIds)
    let total = totalPhotoCount(albumIds: albumIds)

    return HStack(spacing: 8) {
      Image(systemName: summaryIconName(exported: exported, total: total))
        .foregroundColor(summaryColor(exported: exported, total: total))
      Text(summaryText(albumCount: albumCount, exported: exported, total: total))
        .font(.subheadline)
        .foregroundColor(.secondary)
    }
  }

  private func summaryIconName(exported: Int, total: Int) -> String {
    if total > 0, exported >= total { return "checkmark.circle.fill" }
    if exported > 0 { return "circle.lefthalf.filled" }
    return "circle"
  }

  private func summaryColor(exported: Int, total: Int) -> Color {
    if total > 0, exported >= total { return .green }
    if exported > 0 { return .orange }
    return .secondary
  }

  private func summaryText(albumCount: Int, exported: Int, total: Int) -> String {
    let albumPart = albumCount == 1 ? "1 album" : "\(albumCount) albums"
    if isLoadingCounts && total == 0 {
      return "\(albumPart) · counting photos…"
    }
    return "\(albumPart) · \(exported)/\(total) exported"
  }

  // MARK: - Export button state

  private var canExport: Bool {
    guard exportDestinationManager.canExportNow else { return false }
    guard exportManager.canExportCollection else { return false }
    guard !exportManager.hasActiveExportWork else { return false }
    if let folder, PhotoCollectionDescriptor.albumLocalIds(under: folder).isEmpty {
      return false
    }
    return true
  }

  private var exportButtonTitle: String {
    guard let folder else { return "Export Folder" }
    let count = PhotoCollectionDescriptor.albumLocalIds(under: folder).count
    if count == 0 { return "Export Folder" }
    return count == 1 ? "Export 1 Album" : "Export \(count) Albums"
  }

  private var exportButtonHelp: String {
    if !exportDestinationManager.canExportNow {
      return "Select a writable export folder first"
    }
    if !exportManager.canExportCollection {
      return "Collections store is not ready"
    }
    if let folder, PhotoCollectionDescriptor.albumLocalIds(under: folder).isEmpty {
      return "This folder has no albums to export"
    }
    return "Export every photo in every album under this folder that isn't already exported."
  }

  // MARK: - Aggregate export status

  /// Exported photos summed across every descendant album's placement, clamped per
  /// album to its live asset count. The clamp mirrors `CollectionSidebarBadge.state`:
  /// when assets have been deleted from an album after a previous export ran, the
  /// stored record count can exceed the live count, and an unclamped sum would
  /// render as "5012/4812 exported".
  private func exportedPhotoCount(albumIds: [String]) -> Int {
    var total = 0
    let albumPlacements = collectionExportRecordStore.placements(matching: .album)
    for id in albumIds {
      guard let placement = albumPlacements.first(where: {
        $0.collectionLocalIdentifier == id
      }) else { continue }
      let recorded = collectionExportRecordStore.summary(for: placement).exportedCount
      let live = countsByDescriptorId["album:\(id)"] ?? recorded
      total += min(recorded, live)
    }
    return total
  }

  private func totalPhotoCount(albumIds: [String]) -> Int {
    albumIds.reduce(0) { $0 + (countsByDescriptorId[descriptorIdForAlbum($1)] ?? 0) }
  }

  /// The id key under which an album's count is stored in `countsByDescriptorId`. Album
  /// descriptors use `.album:<localIdentifier>` as their `id`; we re-derive the same
  /// shape so the lookup matches what `loadCounts` writes.
  private func descriptorIdForAlbum(_ albumId: String) -> String {
    "album:\(albumId)"
  }

  private func isAlbumFullyExported(_ descriptor: PhotoCollectionDescriptor) -> Bool {
    guard descriptor.kind == .album,
      let albumId = descriptor.localIdentifier,
      let live = countsByDescriptorId[descriptor.id], live > 0,
      let placement = collectionExportRecordStore.placements(matching: .album)
        .first(where: { $0.collectionLocalIdentifier == albumId })
    else { return false }
    let exported = collectionExportRecordStore.summary(for: placement).exportedCount
    return exported >= live
  }

  // MARK: - Navigation

  private func navigate(to child: PhotoCollectionDescriptor) {
    switch child.kind {
    case .album:
      selection = .album(collectionId: child.localIdentifier ?? "")
    case .folder:
      selection = .folder(collectionId: child.localIdentifier ?? "")
    case .favorites:
      break
    }
    selectedAsset = nil
  }

  // MARK: - Tree + counts

  private func findFolder(folderId: String) -> PhotoCollectionDescriptor? {
    let tree = (try? photoLibraryManager.fetchCollectionTree()) ?? []
    return search(folderId: folderId, in: tree)
  }

  private func search(folderId: String, in tree: [PhotoCollectionDescriptor])
    -> PhotoCollectionDescriptor?
  {
    for descriptor in tree {
      if descriptor.kind == .folder, descriptor.localIdentifier == folderId {
        return descriptor
      }
      if let found = search(folderId: folderId, in: descriptor.children) {
        return found
      }
    }
    return nil
  }

  /// Loads photo counts for every descendant album and rolls them up into per-subfolder
  /// totals. Each lookup goes through `cachedCountAssets`, which dedups concurrent
  /// identical fetches inside `CollectionCountCache`, so re-running this on revision
  /// bumps is cheap on the second pass.
  private func loadCounts() async {
    guard let folder else { return }
    isLoadingCounts = true
    defer { isLoadingCounts = false }
    countsByDescriptorId = await collectCounts(in: folder.children)
  }

  /// Walks the subtree under each child, fetching album counts and rolling them up. The
  /// count for an `.album` descriptor is its own asset count; the count for a `.folder`
  /// descriptor is the sum of every album in its subtree. Errors per-album are silently
  /// skipped so a single inaccessible album doesn't blank the whole header.
  private func collectCounts(in descriptors: [PhotoCollectionDescriptor]) async
    -> [String: Int]
  {
    var counts: [String: Int] = [:]
    for descriptor in descriptors {
      switch descriptor.kind {
      case .album:
        if let id = descriptor.localIdentifier {
          let n = (try? await photoLibraryManager.cachedCountAssets(
            in: .album(collectionId: id))) ?? 0
          counts[descriptor.id] = n
        }
      case .folder:
        let childCounts = await collectCounts(in: descriptor.children)
        for (key, value) in childCounts { counts[key] = value }
        let total = PhotoCollectionDescriptor.albumLocalIds(under: descriptor)
          .compactMap { counts["album:\($0)"] }
          .reduce(0, +)
        counts[descriptor.id] = total
      case .favorites:
        continue
      }
    }
    return counts
  }
}
