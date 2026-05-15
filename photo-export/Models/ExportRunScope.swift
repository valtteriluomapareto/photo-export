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
