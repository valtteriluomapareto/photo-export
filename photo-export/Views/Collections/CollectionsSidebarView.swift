import Photos
import SwiftUI

/// Pure helper for the per-collection progress badge in `CollectionsSidebarView`.
///
/// Compares the store's `exportedCount` (records that have at least one done
/// variant) against the live album count. Trusting `summary.status` from the
/// store would be a bug: that field treats "all stored records are done" as
/// `.complete`, which is wrong whenever the album has more assets than there
/// are records (the most common case — every partial export, every newly
/// added asset). The visible grid header solves this with
/// `monthSummary(assets:placement:selection:)`; the sidebar can't iterate
/// the asset list, so it falls back to comparing exported-record-count
/// against the live count.
enum CollectionSidebarBadge {
  enum State: Equatable {
    case complete
    case partial(exported: Int, total: Int)
    case notStarted(total: Int)
  }

  static func state(liveCount: Int, exportedRecords: Int) -> State {
    precondition(liveCount > 0, "Caller must guard count > 0 before computing badge state")
    // Clamp on the way out so an album whose assets were removed after a
    // larger past export doesn't render `1000/941` partial — there's
    // nothing left to do for those stale records.
    let exported = min(exportedRecords, liveCount)
    if exported >= liveCount { return .complete }
    if exported > 0 { return .partial(exported: exported, total: liveCount) }
    return .notStarted(total: liveCount)
  }
}

/// Rendering decision for the "Shared Albums" sidebar section. Extracted from
/// the view so the four-cell truth table — (`hasSharedAlbums`, `hintDismissed`)
/// → which subview, if any — is unit-testable without instantiating SwiftUI.
///
/// The rule: render the actual albums when there are any; render the discovery
/// hint when the section is empty but the user hasn't dismissed the explainer
/// yet; hide the section entirely once they've dismissed it for an empty list.
enum SharedAlbumsSectionMode: Equatable {
  case albums
  case hint
  case hidden

  static func resolve(hasSharedAlbums: Bool, hintDismissed: Bool) -> Self {
    if hasSharedAlbums { return .albums }
    if !hintDismissed { return .hint }
    return .hidden
  }
}

/// The "Shared Albums" section shown when the shared-album fetch returned nothing: the
/// discovery hint, or nothing once the user dismissed it.
///
/// It owns the `@AppStorage` flag so `CollectionsSidebarView` holds none. SwiftUI re-runs
/// the body of a view with an `@AppStorage` property whenever its parent rebuilds it, and
/// `LibraryRootView` rebuilds the sidebar on every export-queue publication.
private struct SharedAlbumsHintSection: View {
  /// Persisted dismissal of the "Where are my shared albums?" hint. We can't read
  /// the Photos.app "Shared Albums" iCloud-sync toggle from a sandboxed app, so
  /// the hint is shown whenever the targeted shared-album fetch returns zero —
  /// which collapses two cases (the toggle is off, OR the user genuinely has no
  /// shared albums). The dismiss button stores the user's intent here so the
  /// hint doesn't return after they've decided they don't need it.
  @AppStorage("photoExport.collections.sharedAlbumsHintDismissed")
  private var sharedAlbumsHintDismissed: Bool = false

  var body: some View {
    if SharedAlbumsSectionMode.resolve(
      hasSharedAlbums: false, hintDismissed: sharedAlbumsHintDismissed) == .hint
    {
      Section("Shared Albums") {
        sharedAlbumsHintRow
      }
    }
  }

  /// Soft hint shown when zero shared albums were returned. We can't tell the user
  /// "your toggle is off" because PhotoKit returns the same zero-result regardless
  /// of whether the toggle is off or the user simply has no shared albums. The
  /// language asks them to check rather than telling them something is wrong, and
  /// "Don't show again" lets users with no shared albums opt out for good.
  ///
  /// The "Open Photos" button drops the user inside Photos.app so they don't have
  /// to hunt for it; the relevant setting is at Photos → Settings → iCloud →
  /// Shared Albums.
  private var sharedAlbumsHintRow: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Image(systemName: "person.2.crop.square.stack")
          .foregroundStyle(.secondary)
        Text("Shared albums missing?")
          .font(.callout)
          .fontWeight(.semibold)
      }
      Text(
        "If you have iCloud shared albums, enable Photos → Settings → iCloud → \"Shared Albums\" so Photos syncs them down."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      HStack {
        Button("Open Photos") {
          NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Photos.app"))
        }
        .controlSize(.small)
        Spacer()
        Button("Don't show again") {
          sharedAlbumsHintDismissed = true
        }
        .controlSize(.small)
      }
    }
    .padding(.vertical, 4)
  }
}

/// Sidebar for the Collections section: a synthetic Favorites entry followed by the
/// user's albums and folders. Selection is bridged out as a `LibrarySelection` so the
/// content area can observe it.
///
/// Tree scans run asynchronously after a coalesced library refresh. Counts land as one
/// coherent batch so the recursive row tree does not rebuild for each arriving album.
struct CollectionsSidebarView: View {
  @Environment(PhotoLibraryManager.self) private var photoLibraryManager

  #if DEBUG
    @Environment(\.bodyInvalidationCounter) private var bodyCounter
  #endif

  /// Multi-select state bound from `LibraryRootView`. Writes are filtered to
  /// collection-shaped values so the sidebar can never persist a stray timeline
  /// tag into the collection state.
  @Binding var selectionSet: Set<LibrarySelection>

  /// Used only by the multi-select export action. A plain reference rather than an
  /// environment object, so queue and progress publications don't re-run this body.
  let exportManager: ExportManager

  @State private var tree: [PhotoCollectionDescriptor] = []
  @State private var expandedFolders: Set<String> = []
  @State private var countsById: [String: Int] = [:]

  var body: some View {
    #if DEBUG
      // swiftlint:disable:next redundant_discardable_let
      let _ = bodyCounter?.record("collections-sidebar")
    #endif
    List(selection: collectionSelection) {
      Section("Favorites") {
        CollectionRow(
          descriptor: favoritesDescriptor,
          count: countsById[favoritesDescriptor.id]
        )
        .tag(LibrarySelection.favorites)

      }

      if !userCollections.isEmpty {
        Section("Albums") {
          ForEach(userCollections, id: \.id) { node in
            CollectionTreeNode(
              descriptor: node, depth: 0, counts: countsById,
              expandedFolders: $expandedFolders, selectedItems: selectionSet,
              multiSelectionCount: multiSelectionCount,
              runMultiExport: runCurrentCollectionsMultiSelectExport)
          }
        }
      }

      // Always render the "Shared Albums" section header when there's anything
      // to show in it — either the actual shared albums, or the discovery hint
      // for users who don't have them surfaced yet. The header is what teaches
      // new users the feature exists; a hint floating without a header reads
      // as an orphan card. The section is hidden entirely only when both
      // branches go empty (no albums AND the hint has been dismissed). Albums
      // present always show the list; with none, `SharedAlbumsHintSection`
      // resolves the hint half of `SharedAlbumsSectionMode.resolve` and owns the
      // persisted dismissal, so its `@AppStorage` doesn't re-run this body.
      if !sharedAlbums.isEmpty {
        Section("Shared Albums") {
          ForEach(sharedAlbums, id: \.id) { node in
            CollectionTreeNode(
              descriptor: node, depth: 0, counts: countsById,
              expandedFolders: $expandedFolders, selectedItems: selectionSet,
              multiSelectionCount: multiSelectionCount,
              runMultiExport: runCurrentCollectionsMultiSelectExport)
          }
        }
      } else {
        SharedAlbumsHintSection()
      }
    }
    .navigationTitle("Photo Export")
    .task(id: photoLibraryManager.libraryRefresh.revision) {
      let source = photoLibraryManager.libraryRevision
      await photoLibraryManager.libraryRefresh.loadTree()
      guard !Task.isCancelled, source == photoLibraryManager.libraryRevision else { return }
      let freshTree = photoLibraryManager.libraryRefresh.tree ?? []
      if tree != freshTree { tree = freshTree }
      await loadCountBatch(source: source)
    }
  }

  /// Icon glyph + tint per descriptor kind. Shared albums use the system "person.2"
  /// glyph to telegraph their multi-owner nature (matching Photos.app's sidebar).
  fileprivate static func iconName(for kind: PhotoCollectionDescriptor.Kind) -> String {
    switch kind {
    case .favorites: return "heart.fill"
    case .sharedAlbum: return "person.2.crop.square.stack"
    case .album, .folder: return "rectangle.stack"
    }
  }

  // MARK: - Selection plumbing

  /// `List(selection:)` accepts a `Set` of the row tag type for multi-select. This
  /// binding filters writes to collection-shaped values so a stray timeline tag
  /// (impossible in steady state, but conceivable during a section-flip transition)
  /// never lands in the collections state. Setting the visible set to empty is
  /// allowed — matches macOS conventions for empty-area clicks.
  private var collectionSelection: Binding<Set<LibrarySelection>> {
    Binding(
      get: { selectionSet.filter(\.isCollection) },
      set: { newValue in
        let filtered = newValue.filter(\.isCollection)
        let preserved = selectionSet.filter { !$0.isCollection }
        selectionSet = filtered.union(preserved)
      }
    )
  }

  // MARK: - Tree fetch

  private var favoritesDescriptor: PhotoCollectionDescriptor {
    tree.first(where: { $0.kind == .favorites })
      ?? PhotoCollectionDescriptor(
        id: "favorites", localIdentifier: nil, title: "Favorites", kind: .favorites,
        pathComponents: [], children: [])
  }

  /// Top-level user albums and folders. Shared albums are partitioned into their own
  /// section below; Favorites is rendered as its own header at the top.
  private var userCollections: [PhotoCollectionDescriptor] {
    tree.filter { $0.kind == .album || $0.kind == .folder }
  }

  /// Top-level shared albums (iCloud-shared). PhotoKit doesn't nest them, so this is a
  /// flat list. `PhotoLibraryManager.fetchCollectionTree` partitions them out so they
  /// always appear here even though PhotoKit's traversal interleaves them with user
  /// albums.
  private var sharedAlbums: [PhotoCollectionDescriptor] {
    tree.filter { $0.kind == .sharedAlbum }
  }

  // MARK: - Multi-select context menu plumbing

  /// Number of collection-shaped items in the current selection. Drives the context-menu
  /// label: when ≥2, a right-clicked row that is part of the selection should advertise
  /// "Export N Items" instead of the row's own per-kind action so the toolbar and menu
  /// don't contradict each other (HIG: predictability).
  fileprivate var multiSelectionCount: Int {
    selectionSet.filter(\.isCollection).count
  }

  /// Triggered from a folder row's context menu when the row is part of a multi-
  /// selection. Mirrors the toolbar's collections-branch dispatch: normalize the set
  /// (expanding folders, deduping, partitioning) and hand to `ExportManager`.
  fileprivate func runCurrentCollectionsMultiSelectExport() {
    let items = selectionSet.filter(\.isCollection)
    let buckets = CollectionsSelectionBuckets.normalize(items) { folderId in
      let currentTree = photoLibraryManager.libraryRefresh.tree ?? []
      guard
        let folder = PhotoCollectionDescriptor.findFolder(
          id: folderId, in: currentTree)
      else { return [] }
      return PhotoCollectionDescriptor.albumLocalIds(under: folder)
    }
    exportManager.startExportCollectionsSelection(buckets)
  }

  private func loadCountBatch(source: Int) async {
    var requests: [(String, PhotoFetchScope)] = [(favoritesDescriptor.id, .favorites)]
    func append(_ nodes: [PhotoCollectionDescriptor]) {
      for node in nodes {
        switch node.kind {
        case .album:
          if let id = node.localIdentifier { requests.append((node.id, .album(collectionId: id))) }
        case .sharedAlbum:
          if let id = node.localIdentifier {
            requests.append((node.id, .sharedAlbum(collectionId: id)))
          }
        case .folder: append(node.children)
        case .favorites: break
        }
      }
    }
    append(tree)
    let service = photoLibraryManager
    let loaded = await withTaskGroup(of: (String, Int?).self) { group in
      var iterator = requests.makeIterator()
      // Bound concurrent PhotoKit count requests even for a very wide album tree.
      for _ in 0..<8 {
        if let request = iterator.next() {
          group.addTask { (request.0, try? await service.cachedCountAssets(in: request.1)) }
        }
      }
      var values: [String: Int] = [:]
      for await (id, value) in group {
        #if DEBUG
          bodyCounter?.record("collection-count-result")
        #endif
        if let value { values[id] = value }
        if let request = iterator.next(), !Task.isCancelled {
          group.addTask { (request.0, try? await service.cachedCountAssets(in: request.1)) }
        }
      }
      return values
    }
    guard !Task.isCancelled, source == photoLibraryManager.libraryRevision else {
      #if DEBUG
        bodyCounter?.record("sidebar-folder-count-superseded")
      #endif
      return
    }
    var fresh: [String: Int] = [:]
    for (id, _) in requests { fresh[id] = loaded[id] ?? countsById[id] }
    func rollUp(_ nodes: [PhotoCollectionDescriptor]) {
      for node in nodes where node.kind == .folder {
        rollUp(node.children)
        fresh[node.id] = PhotoCollectionDescriptor.albumLocalIds(under: node)
          .reduce(0) { $0 + (fresh["album:\($1)"] ?? 0) }
      }
    }
    rollUp(tree)
    if countsById != fresh { countsById = fresh }
  }

}

/// Nominal recursion keeps the row identity and avoids rebuilding a type-erased tree.
private struct CollectionTreeNode: View {
  let descriptor: PhotoCollectionDescriptor
  let depth: Int
  let counts: [String: Int]
  @Binding var expandedFolders: Set<String>
  let selectedItems: Set<LibrarySelection>
  let multiSelectionCount: Int
  let runMultiExport: () -> Void

  @ViewBuilder var body: some View {
    switch descriptor.kind {
    case .album:
      CollectionRow(descriptor: descriptor, count: counts[descriptor.id], depth: depth)
        .tag(LibrarySelection.album(collectionId: descriptor.localIdentifier ?? ""))
    case .sharedAlbum:
      CollectionRow(descriptor: descriptor, count: counts[descriptor.id], depth: depth)
        .tag(LibrarySelection.sharedAlbum(collectionId: descriptor.localIdentifier ?? ""))
    case .folder:
      DisclosureGroup(
        isExpanded: Binding(
          get: { expandedFolders.contains(descriptor.id) },
          set: { expanded in
            if expanded {
              expandedFolders.insert(descriptor.id)
            } else {
              expandedFolders.remove(descriptor.id)
            }
          })
      ) {
        ForEach(descriptor.children) { child in
          CollectionTreeNode(
            descriptor: child, depth: depth + 1, counts: counts,
            expandedFolders: $expandedFolders, selectedItems: selectedItems,
            multiSelectionCount: multiSelectionCount, runMultiExport: runMultiExport)
        }
      } label: {
        FolderRow(
          descriptor: descriptor, depth: depth,
          albumCount: PhotoCollectionDescriptor.albumLocalIds(in: descriptor.children).count,
          photoCount: counts[descriptor.id],
          isInMultiSelection: multiSelectionCount >= 2
            && selectedItems.contains(.folder(collectionId: descriptor.localIdentifier ?? "")),
          multiSelectionCount: multiSelectionCount, runMultiExport: runMultiExport
        )
        .tag(LibrarySelection.folder(collectionId: descriptor.localIdentifier ?? ""))
      }
    case .favorites: EmptyView()
    }
  }
}

// MARK: - Rows

private struct CollectionRow: View {
  #if DEBUG
    @Environment(\.bodyInvalidationCounter) private var bodyCounter
  #endif
  @Environment(CollectionExportRecordStore.self) private var collectionExportRecordStore

  let descriptor: PhotoCollectionDescriptor
  let count: Int?
  var depth: Int = 0

  var body: some View {
    #if DEBUG
      // swiftlint:disable:next redundant_discardable_let
      let _ = bodyCounter?.record("collection-row-body:\(descriptor.id)")
    #endif
    HStack(spacing: 8) {
      if depth > 0 {
        // Indent nested albums under folders so the hierarchy reads at a glance.
        Color.clear.frame(width: CGFloat(depth) * 8, height: 1)
      }
      Image(systemName: CollectionsSidebarView.iconName(for: descriptor.kind))
        .foregroundColor(descriptor.kind == .favorites ? .pink : .secondary)
      Text(descriptor.title.isEmpty ? "Untitled" : descriptor.title)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer()
      countBadge
    }
    .help(tooltip)
  }

  @ViewBuilder
  private var countBadge: some View {
    if let count, count > 0, let placement = matchingPlacement() {
      let summary = collectionExportRecordStore.summary(for: placement)
      // Note: this still treats "any variant done" as "asset exported",
      // so it does not catch the case where a user exported with Include
      // originals off and later toggled it on. Surfacing that gap
      // requires the asset list + version selection in the sidebar;
      // tracked as a separate follow-up.
      let state = CollectionSidebarBadge.state(
        liveCount: count, exportedRecords: summary.exportedCount)
      #if DEBUG
        // swiftlint:disable:next redundant_discardable_let
        let _ = bodyCounter?.recordText(
          [String(describing: state)], for: "collection-sidebar:\(descriptor.id)")
      #endif
      switch state {
      case .complete:
        Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.caption)
          .accessibilityLabel("Fully exported")
      case .partial(let exported, let total):
        Text("\(exported)/\(total)").foregroundColor(.orange).font(.caption)
      case .notStarted(let total):
        Text("\(total)").foregroundColor(.secondary).font(.caption)
      }
    } else if let count {
      #if DEBUG
        // swiftlint:disable:next redundant_discardable_let
        let _ = bodyCounter?.recordText(
          ["count:\(count)"], for: "collection-sidebar:\(descriptor.id)")
      #endif
      Text("\(count)").foregroundColor(.secondary).font(.caption)
    }
  }

  /// Read the current descriptor/path slot; historical renamed/moved paths
  /// remain intact but do not describe the next export target.
  private func matchingPlacement() -> ExportPlacement? {
    let selection: LibrarySelection
    switch descriptor.kind {
    case .favorites: selection = .favorites
    case .album:
      guard let id = descriptor.localIdentifier else { return nil }
      selection = .album(collectionId: id)
    case .sharedAlbum:
      guard let id = descriptor.localIdentifier else { return nil }
      selection = .sharedAlbum(collectionId: id)
    case .folder: return nil
    }
    return collectionExportRecordStore.currentPlacement(for: selection, collections: [descriptor])
  }

  private var tooltip: String {
    if let count {
      return "\(descriptor.title): \(count) photos"
    }
    return descriptor.title
  }
}

private struct FolderRow: View {
  #if DEBUG
    @Environment(\.bodyInvalidationCounter) private var bodyCounter
  #endif
  @Environment(ExportManager.self) private var exportManager
  @EnvironmentObject private var exportDestinationManager: ExportDestinationManager
  @Environment(CollectionExportRecordStore.self) private var collectionExportRecordStore

  let descriptor: PhotoCollectionDescriptor
  let depth: Int
  let albumCount: Int
  let photoCount: Int?
  /// True when this row is part of a ≥2-item selection. The context menu flips to
  /// the multi-selection action so right-click doesn't contradict the toolbar.
  let isInMultiSelection: Bool
  let multiSelectionCount: Int
  /// Closure that runs the current Collections multi-select export. Owned by
  /// `CollectionsSidebarView` so it can reach the live `selectionSet` + tree.
  let runMultiExport: () -> Void

  private var exportAvailability: ManualExportAvailability {
    ManualExportAvailability(
      destinationCanExport: exportDestinationManager.canExportNow,
      history: collectionExportRecordStore.state)
  }

  var body: some View {
    #if DEBUG
      // swiftlint:disable:next redundant_discardable_let
      let _ = bodyCounter?.record("folder-row-body:\(descriptor.id)")
    #endif
    HStack(spacing: 8) {
      if depth > 0 {
        Color.clear.frame(width: CGFloat(depth) * 8, height: 1)
      }
      Image(systemName: "folder").foregroundColor(.secondary)
      Text(descriptor.title.isEmpty ? "Untitled folder" : descriptor.title)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer()
      countBadge
    }
    .help(tooltip)
    .contextMenu {
      if isInMultiSelection {
        // Finder-style: right-click on a row in the multi-selection acts on the
        // whole selection. The toolbar already advertises this action; the menu
        // matches so the two surfaces never contradict.
        Button("Export \(multiSelectionCount) Items") {
          runMultiExport()
        }
        .disabled(!exportAvailability.canStart || exportManager.hasActiveExportWork)
      } else {
        Button("Export Folder") {
          if let id = descriptor.localIdentifier {
            exportManager.startExportFolder(folderId: id)
          }
        }
        .disabled(
          descriptor.localIdentifier == nil
            || albumCount == 0
            || !exportAvailability.canStart
            || exportManager.hasActiveExportWork
        )
      }
    }
  }

  /// Mirrors `CollectionRow.countBadge` but aggregates across every descendant album so
  /// a folder summarises its subtree's export progress at a glance. Falls back to a
  /// plain count text when no live total is available yet (counts load asynchronously).
  @ViewBuilder
  private var countBadge: some View {
    if let photoCount, photoCount > 0, albumCount > 0 {
      let state = CollectionSidebarBadge.state(
        liveCount: photoCount, exportedRecords: aggregateExportedCount())
      #if DEBUG
        // swiftlint:disable:next redundant_discardable_let
        let _ = bodyCounter?.recordText(
          [String(describing: state)], for: "folder-sidebar:\(descriptor.id)")
      #endif
      switch state {
      case .complete:
        Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.caption)
          .accessibilityLabel("Fully exported")
      case .partial(let exported, let total):
        Text("\(exported)/\(total)").foregroundColor(.orange).font(.caption)
      case .notStarted(let total):
        Text("\(total)").foregroundColor(.secondary).font(.caption)
      }
    } else if let photoCount {
      Text("\(photoCount)").foregroundColor(.secondary).font(.caption)
    }
  }

  /// Sum of `summary.exportedCount` across every descendant album's placement. Not
  /// per-album-clamped — the higher-level `CollectionSidebarBadge.state` clamps the
  /// final sum against the folder's live total, which catches the
  /// "stale-records-after-deletion" case at the aggregate level.
  private func aggregateExportedCount() -> Int {
    let albumIds = PhotoCollectionDescriptor.albumLocalIds(in: descriptor.children)
    var sum = 0
    for id in albumIds {
      if let placement = collectionExportRecordStore.currentPlacement(
        for: .album(collectionId: id), collections: [descriptor])
      {
        sum += collectionExportRecordStore.summary(for: placement).exportedCount
      }
    }
    return sum
  }

  private var tooltip: String {
    let title = descriptor.title.isEmpty ? "Untitled folder" : descriptor.title
    let albums = albumCount == 1 ? "1 album" : "\(albumCount) albums"
    if let photoCount {
      let photos = photoCount == 1 ? "1 photo" : "\(photoCount) photos"
      return "\(title): \(albums) · \(photos)"
    }
    return "\(title): \(albums)"
  }
}
