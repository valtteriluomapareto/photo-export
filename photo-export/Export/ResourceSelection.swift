import Foundation
import Photos

/// Variant-aware resource selection used by both the export pipeline and the
/// backup scanner so both sides agree on what constitutes an original-side
/// resource vs an edited-side resource.
enum ResourceSelection {
  /// True when `type` identifies original (pre-edit) bytes for this media kind.
  /// Kept intentionally narrow: only the canonical original cases count.
  static func isOriginalResource(type: PHAssetResourceType, mediaType: PHAssetMediaType) -> Bool {
    switch mediaType {
    case .image:
      return type == .photo || type == .alternatePhoto
    case .video:
      return type == .video
    default:
      return type == .photo || type == .video
    }
  }

  /// True when `type` identifies the current edited/rendered bytes for this
  /// media kind.
  static func isEditedResource(type: PHAssetResourceType, mediaType: PHAssetMediaType) -> Bool {
    switch mediaType {
    case .image:
      return type == .fullSizePhoto
    case .video:
      return type == .fullSizeVideo
    default:
      return type == .fullSizePhoto || type == .fullSizeVideo
    }
  }

  /// Selects the resource to write for an original export.
  ///
  /// Preserves the pipeline's existing preference order: canonical original
  /// first, fall back to `alternatePhoto`, then last-resort any resource so a
  /// broken asset still gets a chance to export. Edited-side resource types
  /// are never returned by this function.
  static func selectOriginalResource(
    from resources: [ResourceDescriptor],
    mediaType: PHAssetMediaType
  ) -> ResourceDescriptor? {
    switch mediaType {
    case .image:
      if let photo = resources.first(where: { $0.type == .photo }) { return photo }
      if let alt = resources.first(where: { $0.type == .alternatePhoto }) { return alt }
    case .video:
      if let video = resources.first(where: { $0.type == .video }) { return video }
    default:
      if let photo = resources.first(where: { $0.type == .photo }) { return photo }
      if let video = resources.first(where: { $0.type == .video }) { return video }
      if let alt = resources.first(where: { $0.type == .alternatePhoto }) { return alt }
    }
    // Last-resort: some assets only expose edited-side resources. Matches
    // prior "primary resource" fallback so this does not regress.
    return resources.first
  }

  /// Picks the byte source for an edited variant.
  ///
  /// Three outcomes:
  /// - `.resource` — a static `PHAssetResource` is available (e.g. the
  ///   `.fullSizePhoto` companion for an edited photo, or the rare case
  ///   where Photos has materialised a `.fullSizeVideo` resource).
  /// - `.render` — the asset is video and has adjustments but no static
  ///   edited resource. Bytes must be produced via `MediaRenderer` because
  ///   PhotoKit does not pre-render edited videos as static resources.
  /// - `.none` — no edited-side bytes are available for this asset.
  ///
  /// `descriptor.hasAdjustments` is the gate for the render path: an
  /// unedited video should never reach the render branch.
  static func selectEditedProducer(
    from resources: [ResourceDescriptor],
    mediaType: PHAssetMediaType,
    descriptor: AssetDescriptor
  ) -> EditedProducer {
    switch mediaType {
    case .image:
      if let resource = resources.first(where: { $0.type == .fullSizePhoto }) {
        return .resource(resource)
      }
      return .none
    case .video:
      if let resource = resources.first(where: { $0.type == .fullSizeVideo }) {
        return .resource(resource)
      }
      if descriptor.hasAdjustments,
        let original = resources.first(where: { $0.type == .video })
      {
        return .render(
          MediaRenderRequest(
            assetId: descriptor.id,
            originalFilename: original.originalFilename,
            fileType: avFileType(forOriginalFilename: original.originalFilename),
            kind: .video
          )
        )
      }
      return .none
    default:
      if let resource = resources.first(where: {
        $0.type == .fullSizePhoto || $0.type == .fullSizeVideo
      }) {
        return .resource(resource)
      }
      return .none
    }
  }
}
