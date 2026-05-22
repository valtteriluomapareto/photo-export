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

  /// Builds the canonical on-disk `relativePath` for a collection-kind placement.
  /// Used by `ExportPlacementResolver` when constructing fresh placements and by
  /// `BackupCollectionPlacementMatcher` when computing the on-disk path to look
  /// up against existing placements. Without this single source of truth,
  /// matcher/resolver drift in path emission would silently break import's
  /// existing-placement reuse (every album would flip to `.fresh` or orphan).
  ///
  /// Inputs are expected pre-sanitized (the resolver sanitizes album titles via
  /// `ExportPathPolicy.sanitizeComponent` before constructing the path; the
  /// scanner reads literal on-disk folder names, which are sanitized at write
  /// time). `.timeline` and `.favorites` have fixed paths and do not flow
  /// through this helper — they use `ExportPlacement.timeline(...)` and
  /// `ExportPlacement.favorites()` directly. Issue #106.
  static func collectionLeafRelativePath(
    kind: ExportPlacement.Kind,
    parentPathComponents: [String],
    leafName: String
  ) -> String {
    switch kind {
    case .album:
      var path = "Collections/Albums/"
      if !parentPathComponents.isEmpty {
        path += parentPathComponents.joined(separator: "/") + "/"
      }
      return path + leafName + "/"
    case .sharedAlbum:
      return "Collections/Shared Albums/\(leafName)/"
    case .timeline, .favorites:
      preconditionFailure(
        "collectionLeafRelativePath does not apply to .\(kind); use ExportPlacement.\(kind)(...) directly"
      )
    }
  }
}
