import Foundation
import Photos

/// Rules for deciding the on-disk subfolder (relative to the placement) where
/// an asset's variants should land, given the user's `videoLayout` setting.
///
/// Keying on `descriptor.mediaType == .video` (rather than "the file being
/// written is a video") means Live Photo paired motion stays with its still:
/// a Live Photo asset has `mediaType == .image`, so all of its variants —
/// including `.originalPairedVideo` / `.editedPairedVideo` — resolve to the
/// bare placement path and remain auto-pairable on disk. Only standalone
/// video assets (`mediaType == .video`) move to `videos/`.
///
/// Audio and `.unknown` fall through to `nil` — bare placement path regardless
/// of layout. The reusable filename allocator (`ExportDestinationResolver.
/// allocatePairedGroupStem`) is unaffected because image and paired-video
/// slots for the same asset always share one `destDir` under this rule.
enum ExportPlacementPathPolicy {
  /// The subfolder (relative to the placement) where every variant of an
  /// asset should land. Returns `nil` to mean "place directly in the
  /// placement folder."
  static func subfolder(
    for mediaType: PHAssetMediaType,
    layout: ExportVideoLayout
  ) -> String? {
    guard layout == .subfolder, mediaType == .video else { return nil }
    return "videos"
  }

  /// Full relative path used to construct `destDir` and the variant
  /// record's `relPath`. Always ends with `/`.
  static func relativePath(
    placement: ExportPlacement,
    subfolder: String?
  ) -> String {
    guard let subfolder, !subfolder.isEmpty else { return placement.relativePath }
    return placement.relativePath + subfolder + "/"
  }
}
