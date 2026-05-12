import Foundation

/// App-owned descriptor for a Photos collection (Favorites, an album, or a folder).
/// Replaces `PHAssetCollection` / `PHCollectionList` at all non-framework boundaries —
/// `PhotoLibraryManager` is the only place those PhotoKit types appear in production.
///
/// Three kinds:
/// - `.favorites`: synthetic. There is no underlying `PHAssetCollection`; the contents are
///   resolved via a `favorite == YES` predicate. `localIdentifier` is `nil`.
/// - `.album`: a user-created album. `localIdentifier` is the underlying
///   `PHAssetCollection.localIdentifier`.
/// - `.folder`: a user-created folder (a `PHCollectionList`). Folders are not directly
///   exportable; they only exist to group children. `localIdentifier` is the underlying
///   `PHCollectionList.localIdentifier` and is used solely for tree identity.
struct PhotoCollectionDescriptor: Identifiable, Hashable, Sendable {
  enum Kind: String, Codable, Hashable, Sendable {
    case favorites
    case album
    case folder
  }

  /// Stable identifier used as the SwiftUI `Identifiable` key. For `.album` and `.folder`
  /// kinds this is the `localIdentifier` (with a kind prefix to disambiguate the synthetic
  /// favorites root); for `.favorites` it is the constant `"favorites"` token.
  let id: String

  /// `PHAssetCollection.localIdentifier` for `.album`, `PHCollectionList.localIdentifier`
  /// for `.folder`. `nil` for `.favorites` (synthetic).
  let localIdentifier: String?

  /// Display title as shown in Photos. Unsanitized — `ExportPathPolicy` sanitizes it
  /// when constructing on-disk paths.
  let title: String

  let kind: Kind

  /// Display hierarchy from the root down to (but not including) this collection's title.
  /// Empty for top-level collections. Unsanitized — sanitization happens in
  /// `ExportPathPolicy`. Used by the placement-id format's `displayPathHash8` segment so a
  /// rename of an album within its folder produces a fresh placement id.
  let pathComponents: [String]

  /// Children of a `.folder`. Empty for `.album` and `.favorites`.
  let children: [PhotoCollectionDescriptor]
}

extension PhotoCollectionDescriptor {
  /// Recursively collects `localIdentifier` for every `.album` in the tree, walking
  /// through `.folder` nodes. `.favorites` is excluded by design — the batch
  /// "Export All Albums" action covers user albums only.
  static func albumLocalIds(in tree: [PhotoCollectionDescriptor]) -> [String] {
    var ids: [String] = []
    for descriptor in tree {
      switch descriptor.kind {
      case .album:
        if let id = descriptor.localIdentifier { ids.append(id) }
      case .folder:
        ids.append(contentsOf: albumLocalIds(in: descriptor.children))
      case .favorites:
        continue
      }
    }
    return ids
  }

  /// Album local ids in this descriptor's subtree, recursively. Returns an empty array
  /// for `.album` and `.favorites` descriptors. Used by `ExportManager.startExportFolder`
  /// to bound the per-album enqueue loop to a single folder's contents.
  static func albumLocalIds(under descriptor: PhotoCollectionDescriptor) -> [String] {
    albumLocalIds(in: descriptor.children)
  }

  /// Locate a `.folder` descriptor anywhere in `tree` by its `localIdentifier`. Returns
  /// `nil` if no such folder exists (e.g. the user deleted it in Photos between
  /// selection and click). Static so it can run inside detached Tasks without
  /// capturing surrounding `self`.
  static func findFolder(id: String, in tree: [PhotoCollectionDescriptor])
    -> PhotoCollectionDescriptor?
  {
    for descriptor in tree {
      if descriptor.kind == .folder, descriptor.localIdentifier == id {
        return descriptor
      }
      if let found = findFolder(id: id, in: descriptor.children) { return found }
    }
    return nil
  }

  /// Resolves a set of selected child `descriptor.id`s under a parent folder into the
  /// deduplicated list of album local ids to export. Selected album tiles contribute
  /// their own id; selected subfolder tiles expand to every descendant album
  /// (mirroring `startExportFolder`'s recursion). `.favorites` is skipped. Order
  /// follows the parent's children order so tests get predictable output.
  ///
  /// Pure helper extracted from `FolderContentView` so the multi-select expansion
  /// logic is reachable from tests without instantiating a SwiftUI view.
  static func selectedAlbumIds(
    in folder: PhotoCollectionDescriptor, selecting selectedChildIds: Set<String>
  ) -> [String] {
    guard !selectedChildIds.isEmpty else { return [] }
    var ids: [String] = []
    var seen = Set<String>()
    for child in folder.children where selectedChildIds.contains(child.id) {
      switch child.kind {
      case .album:
        if let id = child.localIdentifier, seen.insert(id).inserted {
          ids.append(id)
        }
      case .folder:
        for id in albumLocalIds(under: child) where seen.insert(id).inserted {
          ids.append(id)
        }
      case .favorites:
        continue
      }
    }
    return ids
  }

  /// Computes the result of Shift-clicking `target` while `current` is the active
  /// selection and `anchor` is the prior anchor. Range follows the parent folder's
  /// `children` order. When `anchor` is `nil` or either id is missing from the
  /// children, Shift-click establishes a fresh single-element selection of `target`
  /// (matching Finder behaviour where a Shift-click without an anchor seeds one).
  /// Otherwise the result is `current ∪ order[anchor…target]` — existing Cmd-selected
  /// tiles outside the range are preserved.
  ///
  /// Pure helper extracted from `FolderContentView.extendSelection` so the
  /// range-expansion math is unit-testable without view state.
  static func extendedSelection(
    from anchor: String?, to target: String, current: Set<String>,
    in folder: PhotoCollectionDescriptor
  ) -> (ids: Set<String>, anchor: String) {
    let order = folder.children.map(\.id)
    guard let anchor,
      let anchorIdx = order.firstIndex(of: anchor),
      let targetIdx = order.firstIndex(of: target)
    else {
      return (ids: [target], anchor: target)
    }
    let lo = min(anchorIdx, targetIdx)
    let hi = max(anchorIdx, targetIdx)
    return (ids: current.union(order[lo...hi]), anchor: anchor)
  }
}
