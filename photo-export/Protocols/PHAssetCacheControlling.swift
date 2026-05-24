import Foundation

/// Seam for dropping `PhotoLibraryManager`'s PHAsset-by-id cache between
/// bulk-export iterations. Kept off `PhotoLibraryService` so test fakes for
/// fetch/observe protocols don't carry unrelated stubs.
///
/// Without intra-loop drops, `ExportManager.runBulkEnqueueLoop`'s timeline
/// or 282-album sweep accumulates every touched PHAsset and PhotoKit's
/// lazy working set behind them; large libraries cross the sandboxed-app
/// high watermark and get killed by `EXC_RESOURCE` (issue #112).
@MainActor
protocol PHAssetCacheControlling: AnyObject {
  /// Drops the PHAsset-by-id cache. Distinct from
  /// `PhotoLibraryManager.invalidateCache()` (which also bumps
  /// `libraryRevision` and clears the collection tree, triggering SwiftUI
  /// re-fetches that are wrong to do mid-export).
  func forgetPHAssetCache()
}

/// No-op default for `ExportManager` tests that don't care about cache
/// drops. `nonisolated init` lets it serve as a default-argument value
/// from any isolation context.
@MainActor
final class NoOpPHAssetCacheControl: PHAssetCacheControlling {
  nonisolated init() {}
  func forgetPHAssetCache() {}
}
