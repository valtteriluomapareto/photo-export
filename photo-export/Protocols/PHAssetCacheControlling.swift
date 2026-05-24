import Foundation

/// Hook for dropping `PhotoLibraryManager`'s PHAsset-by-id cache between
/// bulk-export iterations. Exists as its own seam (rather than a method on
/// `PhotoLibraryService` or `PhotoLibraryChangeProviding`) because
/// cache-control is a behavior method, not a fetch or a change-observation
/// method. Mixing concerns at the protocol level would force
/// `FakePhotoLibraryService` / `FakePersistentChangeSource` to implement
/// unrelated stubs.
///
/// Why this seam exists: on a large library (80k+ assets, 200+ albums), the
/// AutoSync fan-out's per-iteration `fetchAssets` calls in
/// `ExportManager.runBulkEnqueueLoop` additively populate `phAssetCache`. The
/// cache only drops on `photoLibraryDidChange` — which can be hours away in
/// normal use. Without dropping between iterations, the cache accumulates
/// references to every PHAsset the bulk loop touched, and PhotoKit's lazy
/// working set behind each PHAsset pins additional memory. The sandboxed-app
/// high watermark is crossed; the process is terminated by an `EXC_RESOURCE`
/// corpse exception with no user-facing crash dialog (issue #112).
///
/// The drop sits inside `runBulkEnqueueLoop` (not at the AutoSync sub-scope
/// boundary as v1 implemented) because each scope's bulk loop iterates
/// internally — timeline across years, albums across 282 collections — and
/// the cache accumulates within a single scope iteration without an intra-
/// loop drop. Architect-lens review on the v1 implementation caught this.
///
/// `@MainActor`-isolated by protocol attribute so the existential carries
/// the isolation guarantee for the method body. Not marked `Sendable` —
/// existing `@MainActor` protocols in this codebase (e.g.
/// `AutoSyncCurrentRunStore`) follow the same convention; adding the
/// `Sendable` requirement would force `PhotoLibraryManager` to declare
/// `@unchecked Sendable` (it has lots of MainActor-isolated mutable state,
/// which Swift can't auto-verify as `Sendable` even though MainActor
/// serializes the access). If a future caller needs to capture the
/// existential into a non-MainActor context (e.g. when the deferred Fix B
/// off-main enumeration PR lands), revisit then.
///
/// Production conformance: `PhotoLibraryManager`. Test conformance:
/// `RecordingPHAssetCacheControl` for invocation-count assertions,
/// `NoOpPHAssetCacheControl` for tests that don't care.
@MainActor
protocol PHAssetCacheControlling: AnyObject {
  /// Drops the PHAsset-by-id cache. Distinct from `PhotoLibraryManager.invalidateCache()`
  /// which also bumps `libraryRevision` and clears the collection tree —
  /// that triggers SwiftUI re-fetches in sidebar/grid views, which is wrong
  /// to do mid-export. `forgetPHAssetCache` is the narrow operation: just
  /// drop the dict, leave UI-facing state alone.
  func forgetPHAssetCache()
}

/// No-op default for test sites that construct an `ExportManager` and don't
/// care about cache-drop behaviour. The real production implementation is
/// `PhotoLibraryManager`.
///
/// `nonisolated init()` so the type can be constructed as a default-argument
/// value on `ExportManager.init`'s `phAssetCacheControl:` parameter from any
/// isolation context. The class itself stays `@MainActor`-isolated to satisfy
/// the protocol's `@MainActor` constraint; only the synthesized `init` needs
/// the wider availability.
@MainActor
final class NoOpPHAssetCacheControl: PHAssetCacheControlling {
  nonisolated init() {}
  func forgetPHAssetCache() {}
}
