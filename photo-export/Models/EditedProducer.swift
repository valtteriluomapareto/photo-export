import AVFoundation
import Foundation

/// Names the byte source for an edited variant. Returned by
/// `ResourceSelection.selectEditedProducer` so `ExportManager` can switch on a
/// single value rather than carrying media-kind-specific booleans inline.
enum EditedProducer: Sendable, Equatable {
  case resource(ResourceDescriptor)
  case render(MediaRenderRequest)
  /// HEIC→JPEG conversion path (issue #47). Materializes the source HEIC/HEIF
  /// resource to disk, then re-encodes as JPEG. The synthesized JPEG counts as
  /// the asset's `.edited` variant; the original HEIC is preserved only when
  /// the user picks `.editedWithOriginals` (via the existing `.original`
  /// variant slot).
  case convertHEIC(ConvertHEICRequest)
  case none

  /// Filename whose extension drives the edited-variant on-disk filename.
  /// Same role for all byte sources, so call sites that only need the
  /// extension (e.g. paired-stem allocation, destination resolution) can
  /// read it without unwrapping the case.
  var originalFilename: String? {
    switch self {
    case .resource(let resource): return resource.originalFilename
    case .render(let request): return request.originalFilename
    case .convertHEIC(let request): return request.originalFilename
    case .none: return nil
    }
  }
}

/// Inputs for the HEIC→JPEG synthesis path. Constructed by
/// `ResourceSelection.selectEditedProducer` when the user has the HEIC→JPEG
/// conversion toggle on and the asset has a HEIC/HEIF byte source.
struct ConvertHEICRequest: Sendable, Equatable {
  /// The asset whose `.edited` variant we're synthesizing. Used by the
  /// production `AssetResourceWriter` to look up the asset on PhotoKit's side
  /// before materializing the source resource bytes.
  let assetId: String
  /// The HEIC/HEIF byte source to read. Either the asset's edited resource
  /// (`.fullSizePhoto`) when Photos served HEIC for an adjusted asset, or the
  /// asset's original resource (`.photo`) for the more common
  /// "unedited HEIC capture" case.
  let sourceResource: ResourceDescriptor
  /// JPEG filename for the synthesized edit — same stem as `sourceResource`,
  /// `.JPG` extension. Drives downstream destination resolution so the file
  /// lands at `<stem>.JPG` rather than `<stem>.HEIC`.
  let originalFilename: String
}

/// Everything a `MediaRenderer` needs to render an edited asset and resolve
/// the destination filename for it.
struct MediaRenderRequest: Sendable, Equatable {
  let assetId: String
  let originalFilename: String
  let fileType: AVFileType
  let kind: Kind

  enum Kind: Sendable { case video }
}
