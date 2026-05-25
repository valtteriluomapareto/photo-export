import Foundation
import os

/// Process-level `OSSignposter` channel for app-lifecycle and navigation
/// events.
///
/// Mirrors the pattern at
/// `PhotoLibraryPersistentChangeAdapter.signposter` — same `subsystem`,
/// different `category` — so the `os_signpost` channels stay discoverable
/// in Instruments under one app name.
///
/// What this records, and how to use it:
///
/// - `AppLaunch` interval: spans `PhotoExportApp.init` through the
///   `WindowGroup`'s first `.task` completion. Drops a measurable interval
///   for the smoothness work's "launch baseline" scenario in
///   `docs/project/plans/ui-smoothness-plan.md` Phase 0.
/// - `SelectionChanged` event: emitted by `LibraryRootView` whenever the
///   focused sidebar selection moves between sections (timeline year,
///   timeline month, favorites, album, shared album, folder). Useful for
///   correlating sidebar/grid invalidation bursts against the user gesture
///   that caused them.
///
/// Export-run intervals (`ExportRun`) live on
/// `ExportQueueCoordinator.signposter` so they bracket the actual
/// queue-coordinator state transitions, not a synthesized UI proxy.
@MainActor
enum AppDiagnostics {
  static let signposter = OSSignposter(
    subsystem: "com.valtteriluoma.photo-export",
    category: "AppLifecycle")

  private static var launchInterval: OSSignpostIntervalState?

  /// Open the launch interval. Idempotent: a second call before
  /// `endLaunch()` keeps the original begin timestamp.
  static func beginLaunch() {
    guard launchInterval == nil else { return }
    launchInterval = signposter.beginInterval("AppLaunch")
  }

  /// Close the launch interval. Idempotent: safe to call without a prior
  /// `beginLaunch`. Tests that mutate state during launch and want a clean
  /// signpost surface can call this directly.
  static func endLaunch() {
    if let state = launchInterval {
      signposter.endInterval("AppLaunch", state)
      launchInterval = nil
    }
  }

  /// Emit a one-shot event for a sidebar selection change. `kind` is the
  /// short tag describing the new selection's shape — `"month"`, `"year"`,
  /// `"favorites"`, `"album"`, `"sharedAlbum"`, `"folder"`, or `"none"`.
  static func selectionChanged(kind: String) {
    signposter.emitEvent("SelectionChanged", "kind=\(kind)")
  }
}
