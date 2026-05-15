import AppKit
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

  /// Multi-select state inside the tile grid. Holds child `descriptor.id` values
  /// (`"album:<localId>"` or `"folder:<localId>"`). Cmd-click toggles a single tile;
  /// Shift-click extends a range from the anchor; a plain click clears selection and
  /// navigates. Esc clears the selection without leaving the folder.
  @State private var selectedChildIds: Set<String> = []
  @State private var selectionAnchorId: String?

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
          startExport()
        }
        .buttonStyle(.bordered)
        .disabled(!canExport)
        .help(exportButtonHelp)
      }

      contentBody
    }
    .padding(.horizontal)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(keyboardShortcutsHost)
    .task(id: folderId + "|\(photoLibraryManager.libraryRevision)") {
      folder = findFolder(folderId: folderId)
      // Selection is per-folder; clear it whenever the visible folder changes so a
      // stale anchor from a previous folder doesn't drive Shift-extend in the new one.
      selectedChildIds.removeAll()
      selectionAnchorId = nil
      await loadCounts()
    }
  }

  /// Hosts Cmd+A and Esc as hidden `Button.keyboardShortcut` so SwiftUI's window-level
  /// shortcut dispatch picks them up. The prior `.onKeyPress` modifiers required the
  /// containing view to be focusable — without a `@FocusState` + `.focusable()` chain
  /// the modifiers never fired. Hidden buttons sidestep that: SwiftUI walks the view
  /// hierarchy looking for shortcut matches regardless of focus, and `.disabled()`
  /// gates Esc on the existence of a selection (so it doesn't preempt sheet dismissal).
  private var keyboardShortcutsHost: some View {
    Group {
      Button("Select All") { selectAllChildren() }
        .keyboardShortcut("a", modifiers: .command)
      Button("Clear Selection") { clearSelection() }
        .keyboardShortcut(.escape, modifiers: [])
        .disabled(selectedChildIds.isEmpty)
    }
    .hidden()
  }

  private func clearSelection() {
    selectedChildIds.removeAll()
    selectionAnchorId = nil
  }

  /// Cmd+A: extend the multi-selection to every child tile in the current folder.
  /// Matches Finder's select-all gesture inside a window. Preserves the existing
  /// anchor (if any) so a follow-up Shift-click extends/contracts from where the
  /// user was, not from index 0.
  private func selectAllChildren() {
    guard let folder, !folder.children.isEmpty else { return }
    selectedChildIds = Set(folder.children.map(\.id))
    if selectionAnchorId == nil {
      selectionAnchorId = folder.children.first?.id
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
            handleTap(on: child, in: folder)
          } label: {
            FolderTileView(
              descriptor: child,
              photoCount: countsByDescriptorId[child.id],
              albumCount: child.kind == .folder
                ? PhotoCollectionDescriptor.albumLocalIds(under: child).count
                : 0,
              isFullyExported: child.kind == .album && isAlbumFullyExported(child),
              isSelected: selectedChildIds.contains(child.id),
              photoLibraryService: photoLibraryService
            )
          }
          .buttonStyle(.plain)
          .contextMenu { contextMenuItems(for: child) }
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
    let albumIds =
      hasSelection
      ? selectedAlbumIds
      : (folder.map(PhotoCollectionDescriptor.albumLocalIds(under:)) ?? [])
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
    let albumPart: String
    if hasSelection {
      let tileCount = selectedChildIds.count
      let tilePart = tileCount == 1 ? "1 selected" : "\(tileCount) selected"
      albumPart = "\(tilePart) · \(albumCount == 1 ? "1 album" : "\(albumCount) albums")"
    } else {
      albumPart = albumCount == 1 ? "1 album" : "\(albumCount) albums"
    }
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
    if hasSelection {
      return !selectedAlbumIds.isEmpty
    }
    if let folder, PhotoCollectionDescriptor.albumLocalIds(under: folder).isEmpty {
      return false
    }
    return true
  }

  private var exportButtonTitle: String {
    let count: Int
    if hasSelection {
      count = selectedAlbumIds.count
    } else if let folder {
      count = PhotoCollectionDescriptor.albumLocalIds(under: folder).count
    } else {
      count = 0
    }
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
    if hasSelection {
      if selectedAlbumIds.isEmpty {
        return "Selected items contain no albums to export"
      }
      return "Export every photo in the selected albums that isn't already exported."
    }
    if let folder, PhotoCollectionDescriptor.albumLocalIds(under: folder).isEmpty {
      return "This folder has no albums to export"
    }
    return "Export every photo in every album under this folder that isn't already exported."
  }

  private func startExport() {
    if hasSelection {
      exportManager.startExportAlbums(collectionIds: selectedAlbumIds)
    } else {
      exportManager.startExportFolder(folderId: folderId)
    }
  }

  // MARK: - Context menu (right-click on a tile)

  /// Finder-style right-click semantics: if the user right-clicks a tile that's part
  /// of the active selection, the action targets the whole selection. If they
  /// right-click an unselected tile, that tile becomes the selection and the action
  /// targets it alone. Either way, the visible menu items match what would be
  /// exported by clicking the toolbar's primary action.
  @ViewBuilder
  private func contextMenuItems(for child: PhotoCollectionDescriptor) -> some View {
    let targetIds = contextMenuTargetIds(for: child)
    let albumIds = contextMenuAlbumIds(for: child)
    let label = contextMenuExportLabel(albumCount: albumIds.count, child: child)
    Button(label) {
      // Promote the right-clicked tile to the selection if it wasn't already
      // selected — matches Finder's "right-click selects then acts" behaviour.
      if !targetIds.isSubset(of: selectedChildIds) {
        selectedChildIds = targetIds
        selectionAnchorId = child.id
      }
      if albumIds.isEmpty {
        return
      }
      exportManager.startExportAlbums(collectionIds: albumIds)
    }
    .disabled(albumIds.isEmpty || !exportManager.canExportCollection)
  }

  /// The set of tile ids the right-click action should target. If the clicked tile is
  /// already in the active selection, the whole selection is the target; otherwise
  /// the action narrows to just the clicked tile.
  private func contextMenuTargetIds(for child: PhotoCollectionDescriptor) -> Set<String> {
    if selectedChildIds.contains(child.id) { return selectedChildIds }
    return [child.id]
  }

  /// Album local ids to export for the right-click target set. Delegates to
  /// `PhotoCollectionDescriptor.selectedAlbumIds(in:selecting:)` so subfolder
  /// expansion, dedup, and `.favorites` exclusion live in one place.
  private func contextMenuAlbumIds(for child: PhotoCollectionDescriptor) -> [String] {
    guard let folder else { return [] }
    return PhotoCollectionDescriptor.selectedAlbumIds(
      in: folder, selecting: contextMenuTargetIds(for: child))
  }

  private func contextMenuExportLabel(
    albumCount: Int, child: PhotoCollectionDescriptor
  ) -> String {
    if albumCount == 0 {
      return child.kind == .folder ? "Export Folder" : "Export Album"
    }
    return albumCount == 1 ? "Export 1 Album" : "Export \(albumCount) Albums"
  }

  // MARK: - Selection helpers

  private var hasSelection: Bool { !selectedChildIds.isEmpty }

  /// Album local ids covered by the current multi-selection. Selected album tiles
  /// contribute their own id; selected subfolder tiles contribute every descendant
  /// album id (mirroring `startExportFolder`'s recursion). Pure expansion lives on
  /// `PhotoCollectionDescriptor.selectedAlbumIds(in:selecting:)`.
  private var selectedAlbumIds: [String] {
    guard let folder else { return [] }
    return PhotoCollectionDescriptor.selectedAlbumIds(in: folder, selecting: selectedChildIds)
  }

  /// Click dispatch. Cmd toggles, Shift extends a range from the anchor, plain click
  /// clears any selection and navigates. Range extension uses the visible child order
  /// (the same order the grid renders) so a Shift-click feels predictable.
  ///
  /// Modifier state is read straight from `NSEvent.modifierFlags` at click time rather
  /// than tracked via a `flagsChanged` monitor. The monitor approach mis-reported `[]`
  /// when the user Cmd-Tab'd into the app and clicked before releasing Cmd — no
  /// `flagsChanged` event fires while the app is gaining key focus, so the first click
  /// would register as a plain navigate.
  private func handleTap(on child: PhotoCollectionDescriptor, in folder: PhotoCollectionDescriptor)
  {
    let modifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if modifiers.contains(.command) {
      toggleSelection(of: child)
    } else if modifiers.contains(.shift) {
      extendSelection(to: child, in: folder)
    } else {
      selectedChildIds.removeAll()
      selectionAnchorId = nil
      navigate(to: child)
    }
  }

  private func toggleSelection(of child: PhotoCollectionDescriptor) {
    if selectedChildIds.contains(child.id) {
      selectedChildIds.remove(child.id)
      if selectionAnchorId == child.id { selectionAnchorId = nil }
    } else {
      selectedChildIds.insert(child.id)
      selectionAnchorId = child.id
    }
  }

  private func extendSelection(
    to child: PhotoCollectionDescriptor, in folder: PhotoCollectionDescriptor
  ) {
    let result = PhotoCollectionDescriptor.extendedSelection(
      from: selectionAnchorId, to: child.id, current: selectedChildIds, in: folder)
    selectedChildIds = result.ids
    selectionAnchorId = result.anchor
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
      guard
        let placement = albumPlacements.first(where: {
          $0.collectionLocalIdentifier == id
        })
      else { continue }
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
    case .favorites, .sharedAlbum:
      // Folders only ever contain regular albums and sub-folders; favorites and
      // shared albums never nest, so these cases are unreachable from the tree but
      // remain exhaustive for the switch.
      break
    }
    selectedAsset = nil
  }

  // MARK: - Tree + counts

  private func findFolder(folderId: String) -> PhotoCollectionDescriptor? {
    let tree = (try? photoLibraryManager.fetchCollectionTree()) ?? []
    return PhotoCollectionDescriptor.findFolder(id: folderId, in: tree)
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
          let n =
            (try? await photoLibraryManager.cachedCountAssets(
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
      case .favorites, .sharedAlbum:
        continue
      }
    }
    return counts
  }
}
