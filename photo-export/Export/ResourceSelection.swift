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
  /// Four outcomes:
  /// - `.resource` — a static `PHAssetResource` is available (e.g. the
  ///   `.fullSizePhoto` companion for an edited photo, or the rare case
  ///   where Photos has materialised a `.fullSizeVideo` resource).
  /// - `.render` — the asset is video and has adjustments but no static
  ///   edited resource. Bytes must be produced via `MediaRenderer` because
  ///   PhotoKit does not pre-render edited videos as static resources.
  /// - `.convertHEIC` — the HEIC→JPEG conversion toggle is on (issue #47)
  ///   and the asset has a HEIC/HEIF byte source. Bytes are synthesized
  ///   locally via `ImageConverter`.
  /// - `.none` — no edited-side bytes are available for this asset.
  ///
  /// `descriptor.hasAdjustments` is the gate for the render path: an
  /// unedited video should never reach the render branch.
  ///
  /// `convertHEICToJPEG` selects between the `.resource` and `.convertHEIC`
  /// paths when both are eligible (i.e. an edited HEIC where the edited
  /// resource is itself HEIC). The conversion path takes precedence so the
  /// user's "give me JPEG output" intent wins over Photos's served bytes.
  static func selectEditedProducer(
    from resources: [ResourceDescriptor],
    mediaType: PHAssetMediaType,
    descriptor: AssetDescriptor,
    convertHEICToJPEG: Bool = false
  ) -> EditedProducer {
    switch mediaType {
    case .image:
      let editedResource = resources.first(where: { $0.type == .fullSizePhoto })
      // HEIC→JPEG synthesis path (issue #47). Three sub-cases for an image:
      //
      //   1. Edited resource exists AND it's HEIC → convert the edit. Happens
      //      when Photos served HEIC for an adjusted asset (rare; most edits
      //      are rendered to JPEG by Photos.app itself).
      //   2. Unedited HEIC original, no edited resource → convert the original.
      //      The common case: an unedited iPhone HEIC capture. The
      //      `!hasAdjustments` gate is load-bearing — without it, the rare
      //      "asset has adjustments but Photos hasn't materialized the
      //      `.fullSizePhoto` yet" state (mid-edit, out-of-sync iCloud) would
      //      silently treat the original HEIC as the edit and ship the user's
      //      pre-edit bytes as if they were the edited version. That state is
      //      a recoverable failure today (the pipeline records
      //      `editedResourceUnavailableMessage` and retries later); leave it
      //      alone so the user doesn't lose edits to the conversion path.
      //   3. Edited resource exists AND it's already JPEG → fall through to
      //      the existing `.resource(.fullSizePhoto)` path. Photos already
      //      did the conversion for us; synthesizing again from the HEIC
      //      original would just write a worse JPEG.
      if convertHEICToJPEG {
        if let editedHEIC = editedResource, isHEICResource(editedHEIC) {
          return .convertHEIC(
            ConvertHEICRequest(
              assetId: descriptor.id,
              sourceResource: editedHEIC,
              originalFilename: jpegFilename(replacingExtensionOf: editedHEIC.originalFilename)
            ))
        }
        if editedResource == nil, !descriptor.hasAdjustments,
          let originalHEIC = resources.first(where: {
            $0.type == .photo && isHEICResource($0)
          })
        {
          return .convertHEIC(
            ConvertHEICRequest(
              assetId: descriptor.id,
              sourceResource: originalHEIC,
              originalFilename: jpegFilename(replacingExtensionOf: originalHEIC.originalFilename)
            ))
        }
        // Fall through: non-HEIC originals + non-HEIC edits already produce
        // JPEG via PhotoKit; no synthesis needed. The "adjusted but no edited
        // resource yet" state also falls through to the existing
        // editedResourceUnavailable recovery, per case 2's gate above.
      }
      if let resource = editedResource {
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

  /// Filename-extension match for HEIC / HEIF byte sources. Resource-level
  /// detection (extension-based) is independent of the asset-level UTI on
  /// `AssetDescriptor.isHEICOriginal`; both predicates accept the same
  /// `.heic` / `.heif` aliases so they agree in practice, but the inputs
  /// differ (filename here, UTI there). Same extension list `BackupScanner`
  /// recognizes as image originals.
  static func isHEICResource(_ resource: ResourceDescriptor) -> Bool {
    let ext = (resource.originalFilename as NSString).pathExtension.lowercased()
    return ext == "heic" || ext == "heif"
  }

  /// Renames a `<stem>.HEIC` (or `.heif`) filename to `<stem>.JPG`. The
  /// uppercase `.JPG` matches Apple's convention for the Photos-rendered
  /// edited JPEG filename — keeping the synthesized JPEG's filename shape
  /// indistinguishable from the natural Photos-rendered case is what makes
  /// the existing `_orig` companion machinery in `ExportFilenamePolicy`
  /// "just work" with no further changes.
  static func jpegFilename(replacingExtensionOf filename: String) -> String {
    let stem = (filename as NSString).deletingPathExtension
    return "\(stem).JPG"
  }
}
