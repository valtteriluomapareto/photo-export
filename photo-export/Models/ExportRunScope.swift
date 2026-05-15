import Foundation

/// Scope of a single export run. Manual runs use the timeline/favorites/all-albums "full" cases;
/// Auto Export runs use either targeted asset-id cases or the umbrella `.autoExport` case where
/// the selected scopes are evaluated as a unit.
enum ExportRunScope: Equatable, Codable, Sendable {
  case timelineFullLibrary
  case timelineAssets(Set<String>)
  case favoritesFull
  case favoritesAssets(Set<String>)
  case allAlbumsFull
  case allAlbumsAssets(Set<String>)
  case allSharedAlbumsFull
  case allSharedAlbumsAssets(Set<String>)
  case autoExport(AutoExportScopeSelection)

  /// The `AutoExportLibraryScope` whose dirty flag a completed run of this scope
  /// clears, or `nil` when the run doesn't represent a full-scope reconciliation
  /// (targeted-asset runs and the `.autoExport` umbrella — that one's handled
  /// separately by `AutoSyncReducer` because it carries its own selection).
  ///
  /// Single source of truth paired with `AutoExportLibraryScope.fullRunScope`.
  /// `AutoSyncReducer.coveredScopes` and `manualFullExportCompleted` read this
  /// instead of restating the mapping.
  var clearableScope: AutoExportLibraryScope? {
    switch self {
    case .timelineFullLibrary: return .timeline
    case .favoritesFull: return .favorites
    case .allAlbumsFull: return .albums
    case .allSharedAlbumsFull: return .sharedAlbums
    case .timelineAssets, .favoritesAssets, .allAlbumsAssets,
      .allSharedAlbumsAssets, .autoExport:
      return nil
    }
  }
}

/// Where an `ExportRunContext` originated. Manual runs come from user-visible controls; auto-sync
/// runs come from `AutoSyncManager`.
enum ExportRunSource: String, Codable, Equatable, Sendable {
  case manual
  case autoSync
}

/// How the run is presented in the UI. User-visible runs may reset toolbar progress and show
/// empty-run banners; background runs must not.
enum ExportRunVisibility: String, Codable, Equatable, Sendable {
  case userVisible
  case background
}

/// Terminal outcome of an export run.
enum ExportRunResult: String, Codable, Equatable, Sendable {
  case completed
  case failed
  case cancelled
  case interrupted
  case superseded
}

/// Why a run ended early. `nil` on a clean `.completed` result.
enum ExportCancelReason: String, Codable, Equatable, Sendable {
  case userCancelled
  case destinationUnavailable
  case supersededByManualRun
  case appTerminated
}
