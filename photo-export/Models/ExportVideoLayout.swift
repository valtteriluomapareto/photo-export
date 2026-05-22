import Foundation

/// User-facing choice for where video files land relative to their placement folder.
///
/// `.flat` is the historical (pre-issue-#38) layout — every variant of every asset
/// lands directly in the placement folder. `.subfolder` routes standalone-video
/// assets (`PHAssetMediaType.video`) into a `videos/` subfolder inside the
/// placement; image assets, including Live Photos and their paired motion file,
/// stay at the bare placement path so the still + motion pair isn't split across
/// directories.
///
/// Enum-shaped rather than a `Bool` so the deferred multi-layout picker
/// (`videos/YYYY/MM`, `YYYY/VIDEOS/MM`, etc.) can add cases later without
/// renaming the UserDefaults key.
enum ExportVideoLayout: String, Codable, Sendable, CaseIterable {
  /// Today's layout. Photos and videos share each placement folder.
  case flat
  /// Standalone-video assets go into a `videos/` subfolder inside the placement.
  /// Live Photo paired motion stays with its still — see
  /// `ExportPlacementPathPolicy.subfolder(for:layout:)`.
  case subfolder
}
