import Foundation

/// Hook for dropping `PhotoLibraryManager`'s PHAsset-by-id cache between
/// AutoSync sub-scopes. Exists as its own seam (rather than a method on
/// `PhotoLibraryChangeProviding`) because cache-control is a behavior method,
/// not a change-observation method, and mixing concerns at the protocol level
/// would force `FakePersistentChangeSource` to implement an unrelated stub.
///
/// Why this seam exists: on a large library (80k+ assets, 200+ albums), the
/// AutoSync fan-out's per-scope `fetchAssets` calls additively populate
/// `phAssetCache` without ever clearing between scopes. The cache only drops
/// on `photoLibraryDidChange` — which can be hours away in normal use.
/// Without dropping between scopes, the cache accumulates references to
/// every PHAsset the fan-out touched, and PhotoKit's lazy working set behind
/// each PHAsset pins additional memory. The sandboxed-app high watermark is
/// crossed; the process is terminated by an `EXC_RESOURCE` corpse exception
/// with no user-facing crash dialog (issue #112).
///
/// Production conformance: `PhotoLibraryManager`. Test conformance: a fake
/// that records the call so `AutoSyncManagerTests` can prove the fan-out
/// drains the cache at the right boundaries.
@MainActor
protocol PHAssetCacheControlling: AnyObject {
  /// Drops the PHAsset-by-id cache. Distinct from `PhotoLibraryManager.invalidateCache()`
  /// which also bumps `libraryRevision` and clears the collection tree — that
  /// triggers SwiftUI re-fetches in sidebar/grid views, which is wrong to do
  /// mid-AutoSync. `forgetPHAssetCache` is the narrow operation: just drop the
  /// dict, leave UI-facing state alone.
  func forgetPHAssetCache()
}
