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
