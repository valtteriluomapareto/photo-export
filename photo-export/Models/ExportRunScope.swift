import Foundation

/// Scope of a recorded export run. Auto Export schedules full-scope runs through the
/// `.autoExport` umbrella, and released versions recorded only those full scopes. The
/// targeted cases still decode; current runners reject targeted requests.
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
  /// `AutoSyncReducer.coveredScopes` reads this instead of restating the mapping.
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

/// Where a recorded `ExportRunContext` originated. Contexts come from `AutoSyncManager`;
/// no released version recorded `.manual`.
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
