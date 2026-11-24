import Foundation

/// Value-only toolbar selection and availability rules; the view owns real actions.
enum ManualToolbarAction: Equatable {
  case timelineAll
  case timelineSelection(TimelineSelectionBuckets)
  case userCollections
  case collectionsSelection(Set<LibrarySelection>)
  case sharedAlbum(String)
}

struct ManualToolbarPresentation {
  let section: LibrarySection
  let selectionSet: Set<LibrarySelection>
  let focusedSelection: LibrarySelection?
  let versionSelection: ExportVersionSelection
  let availability: ManualExportAvailability
  let destinationHelp: String
  let isImporting: Bool
  let hasActiveExportWork: Bool
  let activeRunSource: ExportRunSource?

  var action: ManualToolbarAction {
    switch section {
    case .timeline:
      let items = selectionSet.filter(\.isTimeline)
      return items.count >= 2 ? .timelineSelection(.normalize(items)) : .timelineAll
    case .collections:
      let items = selectionSet.filter(\.isCollection)
      if items.count >= 2 { return .collectionsSelection(items) }
      if case .sharedAlbum(let id) = focusedSelection { return .sharedAlbum(id) }
      return .userCollections
    }
  }

  var label: String {
    switch action {
    case .timelineAll: return "Export All"
    case .timelineSelection(let buckets):
      return "Export \(buckets.count) \(buckets.count == 1 ? "Item" : "Items")"
    case .userCollections: return "Export All Albums"
    case .collectionsSelection(let items): return "Export \(items.count) Items"
    case .sharedAlbum: return "Export Shared Album"
    }
  }

  /// Stays enabled while Auto Export runs, so a click can show the confirmation that replaces
  /// that run. Manual work, import, or unavailable destination/history disables it.
  /// See docs/reference/auto-export-behavior.md#run-ownership-and-presentation.
  var isEnabled: Bool {
    availability.canStart && !isImporting
      && !(hasActiveExportWork && activeRunSource != .autoSync)
  }

  var help: String {
    if let unavailable = availability.unavailableHelp(
      destinationHelp: destinationHelp)
    {
      return unavailable
    }
    let multiCount: Int = {
      switch section {
      case .timeline: return selectionSet.filter(\.isTimeline).count
      case .collections: return selectionSet.filter(\.isCollection).count
      }
    }()
    if multiCount >= 2 {
      switch section {
      case .timeline:
        return
          "Export every photo across the selected years and months. Years cover their months — selecting a year and a month inside it exports the whole year."
      case .collections:
        return
          "Export every photo in the selected collections. Selected folders are expanded to their nested albums; Favorites and shared albums are included if selected."
      }
    }
    // Shared album single-select keeps its per-item dispatch (and label).
    if case .sharedAlbum = focusedSelection {
      // The "Include originals" toggle is a no-op for shared albums; surface that
      // here so the version-selection state doesn't read as a contradiction.
      return
        "Export every photo in this shared album. iCloud only provides downscaled "
        + "JPEGs for shared photos; Include originals is ignored."
    }
    switch (section, versionSelection) {
    case (.timeline, .edited):
      return
        "Export every photo in the timeline (year/month) view, in the version "
        + "Photos shows. Use the in-pane Export Month or Export Year button "
        + "for a smaller scope."
    case (.timeline, .editedWithOriginals):
      return
        "Export every photo in the timeline (year/month) view, plus a _orig "
        + "companion for any photo edited in Photos. Use the in-pane Export "
        + "Month or Export Year button for a smaller scope."
    case (.collections, .edited):
      return
        "Export Favorites and every user album (including albums nested in "
        + "folders), in the version Photos shows. Shared albums are excluded "
        + "— use the Export Shared Album button on their pane."
    case (.collections, .editedWithOriginals):
      return
        "Export Favorites and every user album (including albums nested in "
        + "folders), plus a _orig companion for any photo edited in Photos. "
        + "Shared albums are excluded — use the Export Shared Album button "
        + "on their pane."
    }
  }

}
