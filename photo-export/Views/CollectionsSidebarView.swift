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

  @Binding var selection: LibrarySelection?

  @State private var tree: [PhotoCollectionDescriptor] = []
  @State private var expandedFolders: Set<String> = []
  @State private var countsById: [String: Int] = [:]

  var body: some View {
    List(selection: selectionBinding) {
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
    }
    .navigationTitle("Photo Export")
    .task(id: photoLibraryManager.libraryRevision) {
      reloadTree()
    }
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
          photoCount: countsById[descriptor.id]
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

  // MARK: - Selection plumbing

  /// `List(selection:)` accepts any `Hashable` tag, including `nil`. This binding
  /// mediates so that ad-hoc nil writes from List (e.g. clicks on empty section
  /// areas, or transitions during a section flip) don't clobber our last-known
  /// selection state.
  private var selectionBinding: Binding<LibrarySelection?> {
    Binding(
      get: { selection },
      set: { newValue in
        if let newValue {
          selection = newValue
        }
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

  private var userCollections: [PhotoCollectionDescriptor] {
    tree.filter { $0.kind != .favorites }
  }

  private func reloadTree() {
    do {
      tree = try photoLibraryManager.fetchCollectionTree()
    } catch {
      tree = []
    }
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
      Image(systemName: descriptor.kind == .favorites ? "heart.fill" : "rectangle.stack")
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
  let descriptor: PhotoCollectionDescriptor
  let depth: Int
  let albumCount: Int
  let photoCount: Int?

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
      if let photoCount, photoCount > 0 {
        Text("\(photoCount)")
          .foregroundColor(.secondary)
          .font(.caption)
      }
    }
    .help(tooltip)
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
