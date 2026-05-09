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
  case timelineMonth(year: Int, month: Int)
  case favorites
  case album(collectionId: String)
  /// User-created folder (a `PHCollectionList`). Folders are not directly exportable as a
  /// single placement — selecting one drives the folder content view, where the export
  /// action enqueues each descendant album to its own existing album placement.
  case folder(collectionId: String)
}

/// Photos query scope. Both timeline (per-year, per-month, or all) and collection scopes
/// (favorites, single album) are expressed here so the same fetch and count APIs can serve
/// both surfaces.
enum PhotoFetchScope: Hashable, Sendable {
  /// `month == nil` means "the whole year"; `month != nil` means "this single month".
  case timeline(year: Int, month: Int?)
  case favorites
  case album(collectionId: String)
}
