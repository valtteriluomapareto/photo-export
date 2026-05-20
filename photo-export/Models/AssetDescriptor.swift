import Foundation
import Photos

/// App-owned value type that replaces PHAsset at all non-framework boundaries.
/// Produced by PhotoLibraryManager, consumed by views, view models, and the export pipeline.
struct AssetDescriptor: Identifiable, Sendable, Equatable {
  let id: String
  let creationDate: Date?
  let mediaType: PHAssetMediaType
  let pixelWidth: Int
  let pixelHeight: Int
  let duration: TimeInterval
  /// Whether Photos has edits on this asset. Used to decide whether an edited
  /// export is even applicable for the asset.
  let hasAdjustments: Bool
  /// Uniform Type Identifier of the asset's original byte source (`"public.heic"`,
  /// `"public.jpeg"`, `"public.png"`, etc.). `nil` when PhotoKit doesn't expose
  /// it for this asset (rare — defensively nil-checked since the underlying API
  /// is undocumented and could regress on a future macOS).
  ///
  /// Used by the HEIC→JPEG conversion feature (issue #47) to decide whether an
  /// asset's exports should include a synthesized JPEG `.edited` variant. Treat
  /// `nil` as "not HEIC" — the default conversion-off behavior matches.
  let originalUTI: String?
  /// True when the asset is a Live Photo (`PHAssetMediaSubtype.photoLive`). Drives the
  /// paired-video export path: an additional `.mov` resource is selected and written
  /// alongside the still image.
  let isLivePhoto: Bool

  init(
    id: String,
    creationDate: Date?,
    mediaType: PHAssetMediaType,
    pixelWidth: Int,
    pixelHeight: Int,
    duration: TimeInterval,
    hasAdjustments: Bool,
    originalUTI: String? = nil,
    isLivePhoto: Bool = false
  ) {
    self.id = id
    self.creationDate = creationDate
    self.mediaType = mediaType
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
    self.duration = duration
    self.hasAdjustments = hasAdjustments
    self.originalUTI = originalUTI
    self.isLivePhoto = isLivePhoto
  }

  /// True when the asset's original byte source is HEIC or HEIF. Drives the
  /// HEIC→JPEG conversion feature's "should we synthesize a JPEG `.edited`
  /// variant?" decision.
  ///
  /// Matches `public.heif` alongside `public.heic` because some iPhone captures
  /// (depth-effect, multi-image sequences) come back from PhotoKit as the HEIF
  /// container UTI rather than the more common HEIC one. `BackupScanner` already
  /// treats both extensions as the same format family, and `CIContext` reads
  /// both transparently, so the conversion path doesn't care which container
  /// we got. Tolerant of unknown UTI — returns false rather than mis-firing.
  var isHEICOriginal: Bool {
    guard let originalUTI else { return false }
    let normalized = originalUTI.lowercased()
    return normalized == "public.heic" || normalized == "public.heif"
  }
}

/// App-owned value type that replaces PHAssetResource in the export path.
struct ResourceDescriptor: Sendable, Equatable {
  let type: PHAssetResourceType
  let originalFilename: String
  /// Bytes on disk for the resource as reported by PhotoKit. Nil when PhotoKit
  /// declines to report (the underlying KVC property is undocumented and may be
  /// missing on some assets) or when this descriptor is built by a test fake
  /// that doesn't model size. The `BackupScanner` matcher uses this as a
  /// last-resort discriminator for burst photos that share metadata but
  /// produce different compressed sizes.
  let fileSize: Int64?

  init(
    type: PHAssetResourceType,
    originalFilename: String,
    fileSize: Int64? = nil
  ) {
    self.type = type
    self.originalFilename = originalFilename
    self.fileSize = fileSize
  }
}
