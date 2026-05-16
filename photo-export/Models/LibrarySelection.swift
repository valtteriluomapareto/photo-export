import Foundation

/// Top-level UI section. Phase 4 adds a `[ Timeline | Collections ]` segmented control;
/// before then the app is timeline-only and `LibrarySection.timeline` is the only value
/// reachable.
enum LibrarySection: String, Codable, Sendable {
  case timeline
  case collections
}

/// What the user has currently selected in the sidebar. Drives both the asset grid and the
/// export action label/destination. Distinct from `PhotoFetchScope` because the UI can hold
/// selections that aren't directly exportable (e.g. a "Favorites" header before any specific
/// album is picked); keeping them separate avoids implying every selection is an enqueue
/// trigger.
enum LibrarySelection: Hashable, Sendable {
  /// A whole year on the timeline. Selectable on the year row in `TimelineSidebarView`
  /// so multi-select can mix years and months in one export. A year that's also
  /// represented by individually-selected months always wins on dedup — see
  /// `TimelineSelectionBuckets.normalize`.
  case timelineYear(year: Int)
  case timelineMonth(year: Int, month: Int)
  case favorites
  case album(collectionId: String)
  /// User-created folder (a `PHCollectionList`). Folders are not directly exportable as a
  /// single placement — selecting one drives the folder content view, where the export
  /// action enqueues each descendant album to its own existing album placement.
  case folder(collectionId: String)
  /// iCloud shared album. Lives in its own sidebar section and exports under
  /// `Collections/Shared Albums/<Album>/` at reduced fidelity (Photos serves a single
  /// downscaled JPEG per asset).
  case sharedAlbum(collectionId: String)

  /// True for timeline-shaped values (`.timelineYear`, `.timelineMonth`). Used by the
  /// sidebar selection bindings to filter writes to the section-appropriate shape.
  var isTimeline: Bool {
    switch self {
    case .timelineYear, .timelineMonth: return true
    case .favorites, .album, .folder, .sharedAlbum: return false
    }
  }

  /// True for collection-shaped values (`.favorites`, `.album`, `.folder`, `.sharedAlbum`).
  var isCollection: Bool { !isTimeline }
}

/// Per-section state needed to restore a multi-select sidebar when the user flips the
/// `LibrarySection` segmented control. Holds both the highlighted set and which item
/// in the set drives the content pane.
struct PersistedSidebarSelection: Equatable {
  var items: Set<LibrarySelection> = []
  var focused: LibrarySelection?

  static let empty = PersistedSidebarSelection()
}

/// Pure decision logic for "what should `focusedSelection` become after the user
/// changed `selectionSet`?". Extracted from the view so the rules are unit-testable
/// without instantiating SwiftUI. Used by `LibraryRootView.applySelectionChange`.
enum SidebarFocusReducer {
  /// Returns the next focus given the diff between old and new selection sets and
  /// the current focus value. Rules, in order:
  ///
  /// 1. **Programmatic full replace** (old/new are disjoint, new is non-empty, the
  ///    caller pre-set `currentFocus` to a member of the new set): respect the
  ///    caller's pick. This is the path `restoreSelection(forSection:)` takes when
  ///    the user flips the section segmented control — without this branch the
  ///    handler would clobber the restored focus with an arbitrary `added.first`.
  /// 2. **Newly-added item present**: focus the added item. For Cmd-click the
  ///    added set has exactly one element. For Shift-extend / Cmd+A it can have
  ///    many; `.first` is non-deterministic but in-set, which is acceptable —
  ///    the user just intentionally expanded the selection.
  /// 3. **Focus was removed** (Cmd-click toggling off the focused item, or a
  ///    plain-click that swapped the set out from under the focus): pick any
  ///    remaining item from the new set.
  /// 4. **New set is empty**: focus becomes nil.
  /// 5. **Otherwise** (no-op diff, focus still valid): keep current focus.
  static func nextFocus(
    oldSet: Set<LibrarySelection>,
    newSet: Set<LibrarySelection>,
    currentFocus: LibrarySelection?
  ) -> LibrarySelection? {
    let added = newSet.subtracting(oldSet)
    let isProgrammaticReplace = oldSet.isDisjoint(with: newSet) && !newSet.isEmpty

    if isProgrammaticReplace, let focus = currentFocus, newSet.contains(focus) {
      return focus
    }
    if let newlyAdded = added.first {
      return newlyAdded
    }
    if let focus = currentFocus, !newSet.contains(focus) {
      return newSet.first
    }
    if newSet.isEmpty {
      return nil
    }
    return currentFocus
  }
}

/// Normalized timeline selection split into years + months. Months that fall inside a
/// selected year are dropped — exporting the year already covers them.
///
/// The dispatcher in `ExportManager.startExportTimelineSelection` and the toolbar's
/// label both read the normalized form so the visible count and the queued count
/// agree.
struct TimelineSelectionBuckets: Equatable {
  var years: [Int]
  var months: [TimelineMonth]

  struct TimelineMonth: Hashable, Sendable {
    let year: Int
    let month: Int
  }

  static func normalize(_ items: some Sequence<LibrarySelection>) -> TimelineSelectionBuckets {
    var yearSet = Set<Int>()
    var monthSet = Set<TimelineMonth>()
    for item in items {
      switch item {
      case .timelineYear(let y):
        yearSet.insert(y)
      case .timelineMonth(let y, let m):
        monthSet.insert(TimelineMonth(year: y, month: m))
      case .favorites, .album, .folder, .sharedAlbum:
        continue
      }
    }
    // Year supersedes any month in the same year. Documented behavior; see plan.
    let filteredMonths = monthSet.filter { !yearSet.contains($0.year) }
    return TimelineSelectionBuckets(
      years: yearSet.sorted(by: >),
      months: filteredMonths.sorted { lhs, rhs in
        if lhs.year != rhs.year { return lhs.year > rhs.year }
        return lhs.month > rhs.month
      }
    )
  }

  var isEmpty: Bool { years.isEmpty && months.isEmpty }
  var count: Int { years.count + months.count }
}

/// Normalized collections selection split into per-store dispatch buckets. `albumIds`
/// is the union of explicitly-selected `.album` items and the recursive album-id
/// expansion of any selected `.folder` items, deduplicated.
struct CollectionsSelectionBuckets: Equatable {
  var includesFavorites: Bool
  var albumIds: [String]
  var sharedAlbumIds: [String]

  static let empty = CollectionsSelectionBuckets(
    includesFavorites: false, albumIds: [], sharedAlbumIds: [])

  /// Splits the selection set into the three collection-store buckets. `expandFolder`
  /// returns the descendant `albumLocalIdentifier` list for a `.folder(collectionId:)`
  /// value; the caller is responsible for tree lookup so this stays a pure helper.
  static func normalize(
    _ items: some Sequence<LibrarySelection>,
    expandFolder: (String) -> [String]
  ) -> CollectionsSelectionBuckets {
    var includesFavorites = false
    var albumSeen = Set<String>()
    var albums: [String] = []
    var sharedSeen = Set<String>()
    var shareds: [String] = []
    for item in items {
      switch item {
      case .favorites:
        includesFavorites = true
      case .album(let id):
        if albumSeen.insert(id).inserted { albums.append(id) }
      case .folder(let id):
        for childId in expandFolder(id) where albumSeen.insert(childId).inserted {
          albums.append(childId)
        }
      case .sharedAlbum(let id):
        if sharedSeen.insert(id).inserted { shareds.append(id) }
      case .timelineYear, .timelineMonth:
        continue
      }
    }
    return CollectionsSelectionBuckets(
      includesFavorites: includesFavorites,
      albumIds: albums,
      sharedAlbumIds: shareds
    )
  }

  var isEmpty: Bool { !includesFavorites && albumIds.isEmpty && sharedAlbumIds.isEmpty }
  var count: Int {
    (includesFavorites ? 1 : 0) + albumIds.count + sharedAlbumIds.count
  }
}

/// Photos query scope. Both timeline (per-year, per-month, or all) and collection scopes
/// (favorites, single album, shared album) are expressed here so the same fetch and count
/// APIs can serve both surfaces.
enum PhotoFetchScope: Hashable, Sendable {
  /// `month == nil` means "the whole year"; `month != nil` means "this single month".
  case timeline(year: Int, month: Int?)
  case favorites
  case album(collectionId: String)
  /// iCloud shared album. The asset enumeration is the same `PHAsset.fetchAssets(in:)` as
  /// `.album`; the kind is split so downstream code (placement resolution, banner
  /// rendering, originals suppression) can branch on shared vs user albums.
  case sharedAlbum(collectionId: String)
}
