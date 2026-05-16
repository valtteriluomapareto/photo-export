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

/// Sidebar for the Collections section: a synthetic Favorites entry followed by the
/// user's albums and folders. Selection is bridged out as a `LibrarySelection` so the
/// content area can observe it.
///
/// The tree is fetched lazily through `PhotoLibraryService.fetchCollectionTree()` and
/// re-fetched whenever `PhotoLibraryManager.libraryRevision` bumps. Per-collection
/// counts come from `cachedCountAssets(in:)` so concurrent sidebar reads share one
/// fetch and the cache is cleared on the same change observer.
struct CollectionsSidebarView: View {
  @EnvironmentObject private var photoLibraryManager: PhotoLibraryManager
  @EnvironmentObject private var collectionExportRecordStore: CollectionExportRecordStore
  @EnvironmentObject private var exportManager: ExportManager

  /// Multi-select state bound from `LibraryRootView`. Writes are filtered to
  /// collection-shaped values so the sidebar can never persist a stray timeline
  /// tag into the collection state.
  @Binding var selectionSet: Set<LibrarySelection>

  @State private var tree: [PhotoCollectionDescriptor] = []
  @State private var expandedFolders: Set<String> = []
  @State private var countsById: [String: Int] = [:]

  /// Persisted dismissal of the "Where are my shared albums?" hint. We can't read
  /// the Photos.app "Shared Albums" iCloud-sync toggle from a sandboxed app, so
  /// the hint is shown whenever the targeted shared-album fetch returns zero —
  /// which collapses two cases (the toggle is off, OR the user genuinely has no
  /// shared albums). The dismiss button stores the user's intent here so the
  /// hint doesn't return after they've decided they don't need it.
  @AppStorage("photoExport.collections.sharedAlbumsHintDismissed")
  private var sharedAlbumsHintDismissed: Bool = false

  var body: some View {
    List(selection: collectionSelection) {
      Section("Favorites") {
        CollectionRow(
          descriptor: favoritesDescriptor,
          count: countsById[favoritesDescriptor.id]
        )
        .tag(LibrarySelection.favorites)
        .task(id: photoLibraryManager.libraryRevision) {
          await loadCount(for: .favorites, descriptorId: favoritesDescriptor.id)
        }
      }

      if !userCollections.isEmpty {
        Section("Albums") {
          ForEach(userCollections, id: \.id) { node in
            descriptorRows(node, depth: 0)
          }
        }
      }

      // Always render the "Shared Albums" section header when there's anything
      // to show in it — either the actual shared albums, or the discovery hint
      // for users who don't have them surfaced yet. The header is what teaches
      // new users the feature exists; a hint floating without a header reads
      // as an orphan card. The section is hidden entirely only when both
      // branches go empty (no albums AND the hint has been dismissed). The
      // four-cell truth table is encoded in `SharedAlbumsSectionMode.resolve`
      // so it's unit-testable in isolation from SwiftUI.
      switch SharedAlbumsSectionMode.resolve(
        hasSharedAlbums: !sharedAlbums.isEmpty,
        hintDismissed: sharedAlbumsHintDismissed)
      {
      case .albums:
        Section("Shared Albums") {
          ForEach(sharedAlbums, id: \.id) { node in
            descriptorRows(node, depth: 0)
          }
        }
      case .hint:
        Section("Shared Albums") {
          sharedAlbumsHintRow
        }
      case .hidden:
        EmptyView()
      }
    }
    .navigationTitle("Photo Export")
    .task(id: photoLibraryManager.libraryRevision) {
      reloadTree()
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

  // MARK: - Tree rendering

  /// Recursive — must return `AnyView`. Without the type-erasure SwiftUI's opaque
  /// return type ends up referencing itself, which the compiler rejects.
  private func descriptorRows(_ descriptor: PhotoCollectionDescriptor, depth: Int)
    -> AnyView
  {
    switch descriptor.kind {
    case .album:
      let row = CollectionRow(
        descriptor: descriptor, count: countsById[descriptor.id], depth: depth
      )
      .tag(LibrarySelection.album(collectionId: descriptor.localIdentifier ?? ""))
      .task(id: descriptor.id + "|\(photoLibraryManager.libraryRevision)") {
        if let id = descriptor.localIdentifier {
          await loadCount(for: .album(collectionId: id), descriptorId: descriptor.id)
        }
      }
      return AnyView(row)
    case .sharedAlbum:
      let row = CollectionRow(
        descriptor: descriptor, count: countsById[descriptor.id], depth: depth
      )
      .tag(LibrarySelection.sharedAlbum(collectionId: descriptor.localIdentifier ?? ""))
      .task(id: descriptor.id + "|\(photoLibraryManager.libraryRevision)") {
        if let id = descriptor.localIdentifier {
          await loadCount(
            for: .sharedAlbum(collectionId: id), descriptorId: descriptor.id)
        }
      }
      return AnyView(row)
    case .folder:
      let group = DisclosureGroup(
        isExpanded: Binding(
          get: { expandedFolders.contains(descriptor.id) },
          set: { newValue in
            if newValue {
              expandedFolders.insert(descriptor.id)
            } else {
              expandedFolders.remove(descriptor.id)
            }
          }
        )
      ) {
        ForEach(descriptor.children, id: \.id) { child in
          descriptorRows(child, depth: depth + 1)
        }
      } label: {
        FolderRow(
          descriptor: descriptor, depth: depth,
          albumCount: folderAlbumCount(descriptor),
          photoCount: countsById[descriptor.id],
          isInMultiSelection: isFolderInMultiSelection(descriptor),
          multiSelectionCount: multiSelectionCount,
          runMultiExport: runCurrentCollectionsMultiSelectExport
        )
        .tag(LibrarySelection.folder(collectionId: descriptor.localIdentifier ?? ""))
        .task(id: descriptor.id + "|\(photoLibraryManager.libraryRevision)") {
          await loadFolderCount(descriptor: descriptor)
        }
      }
      return AnyView(group)
    case .favorites:
      // Favorites is rendered as its own section above; never appears in the user
      // collection list. This case is unreachable in practice.
      return AnyView(EmptyView())
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

  private func reloadTree() {
    do {
      tree = try photoLibraryManager.fetchCollectionTree()
    } catch {
      tree = []
    }
  }

  // MARK: - Multi-select context menu plumbing

  /// Number of collection-shaped items in the current selection. Drives the context-menu
  /// label: when ≥2, a right-clicked row that is part of the selection should advertise
  /// "Export N Items" instead of the row's own per-kind action so the toolbar and menu
  /// don't contradict each other (HIG: predictability).
  fileprivate var multiSelectionCount: Int {
    selectionSet.filter(\.isCollection).count
  }

  /// True iff the given folder descriptor is part of a multi-selection (≥2 items),
  /// itself included. Single-selection on this exact folder falls back to the
  /// per-row "Export Folder" action because that's the unambiguous case.
  fileprivate func isFolderInMultiSelection(_ descriptor: PhotoCollectionDescriptor) -> Bool {
    guard multiSelectionCount >= 2 else { return false }
    guard let id = descriptor.localIdentifier else { return false }
    return selectionSet.contains(.folder(collectionId: id))
  }

  /// Triggered from a folder row's context menu when the row is part of a multi-
  /// selection. Mirrors the toolbar's collections-branch dispatch: normalize the set
  /// (expanding folders, deduping, partitioning) and hand to `ExportManager`.
  fileprivate func runCurrentCollectionsMultiSelectExport() {
    let items = selectionSet.filter(\.isCollection)
    let buckets = CollectionsSelectionBuckets.normalize(items) { folderId in
      let currentTree = (try? photoLibraryManager.fetchCollectionTree()) ?? []
      guard
        let folder = PhotoCollectionDescriptor.findFolder(
          id: folderId, in: currentTree)
      else { return [] }
      return PhotoCollectionDescriptor.albumLocalIds(under: folder)
    }
    exportManager.startExportCollectionsSelection(buckets)
  }

  private func loadCount(for scope: PhotoFetchScope, descriptorId: String) async {
    do {
      let n = try await photoLibraryManager.cachedCountAssets(in: scope)
      await MainActor.run { countsById[descriptorId] = n }
    } catch {
      // Leave the count as-is on error; the row will render without a count badge.
    }
  }

  /// Recursively sums photo counts for every album descended from `descriptor`. Each
  /// album lookup hits `cachedCountAssets`, which deduplicates concurrent identical
  /// fetches inside `CollectionCountCache`, so re-rendering the sidebar after expand
  /// or revision bump is cheap on the second pass.
  private func loadFolderCount(descriptor: PhotoCollectionDescriptor) async {
    let albumIds = PhotoCollectionDescriptor.albumLocalIds(in: descriptor.children)
    var total = 0
    for id in albumIds {
      do {
        total += try await photoLibraryManager.cachedCountAssets(
          in: .album(collectionId: id))
      } catch {
        // Skip unreachable albums; the badge will render the partial sum we have.
      }
    }
    await MainActor.run { countsById[descriptor.id] = total }
  }

  /// Number of `.album` descriptors in this folder's subtree. Pure tree walk — no async.
  private func folderAlbumCount(_ descriptor: PhotoCollectionDescriptor) -> Int {
    PhotoCollectionDescriptor.albumLocalIds(in: descriptor.children).count
  }
}

// MARK: - Rows

private struct CollectionRow: View {
  @EnvironmentObject private var collectionExportRecordStore: CollectionExportRecordStore
  @EnvironmentObject private var exportManager: ExportManager

  let descriptor: PhotoCollectionDescriptor
  let count: Int?
  var depth: Int = 0

  var body: some View {
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
      switch CollectionSidebarBadge.state(
        liveCount: count, exportedRecords: summary.exportedCount)
      {
      case .complete:
        Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.caption)
      case .partial(let exported, let total):
        Text("\(exported)/\(total)").foregroundColor(.orange).font(.caption)
      case .notStarted(let total):
        Text("\(total)").foregroundColor(.secondary).font(.caption)
      }
    } else if let count {
      Text("\(count)").foregroundColor(.secondary).font(.caption)
    }
  }

  /// Looks up the persisted placement for this descriptor (if any) so the sidebar can
  /// show partial-export progress before the user starts a new run. Favorites resolves
  /// to the canonical placement id; albums match on `collectionLocalIdentifier`.
  private func matchingPlacement() -> ExportPlacement? {
    switch descriptor.kind {
    case .favorites:
      return collectionExportRecordStore.placement(id: ExportPlacement.favorites().id)
    case .album:
      guard let id = descriptor.localIdentifier else { return nil }
      return collectionExportRecordStore.placements(matching: .album)
        .first(where: { $0.collectionLocalIdentifier == id })
    case .sharedAlbum:
      guard let id = descriptor.localIdentifier else { return nil }
      return collectionExportRecordStore.placements(matching: .sharedAlbum)
        .first(where: { $0.collectionLocalIdentifier == id })
    case .folder:
      return nil
    }
  }

  private var tooltip: String {
    if let count {
      return "\(descriptor.title): \(count) photos"
    }
    return descriptor.title
  }
}

private struct FolderRow: View {
  @EnvironmentObject private var exportManager: ExportManager
  @EnvironmentObject private var exportDestinationManager: ExportDestinationManager
  @EnvironmentObject private var collectionExportRecordStore: CollectionExportRecordStore

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

  var body: some View {
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
        .disabled(
          !exportDestinationManager.canExportNow
            || exportManager.hasActiveExportWork
            || !exportManager.canExportCollection
        )
      } else {
        Button("Export Folder") {
          if let id = descriptor.localIdentifier {
            exportManager.startExportFolder(folderId: id)
          }
        }
        .disabled(
          descriptor.localIdentifier == nil
            || albumCount == 0
            || !exportDestinationManager.canExportNow
            || exportManager.hasActiveExportWork
            || !exportManager.canExportCollection
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
      switch CollectionSidebarBadge.state(
        liveCount: photoCount,
        exportedRecords: aggregateExportedCount()
      ) {
      case .complete:
        Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.caption)
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
    let placements = collectionExportRecordStore.placements(matching: .album)
    var sum = 0
    for id in albumIds {
      if let p = placements.first(where: { $0.collectionLocalIdentifier == id }) {
        sum += collectionExportRecordStore.summary(for: p).exportedCount
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
