import Foundation
import Photos

/// Owns serial, utility-priority metadata reads; all framework objects remain inside a leaf.
final class ProductionPhotoKitReader: PhotoKitReading {
  let thumbnailReader: (any ThumbnailReading)?
  private let io: any DestinationIOExecuting
  private let lookup: @Sendable (String, Bool) -> PhotoKitAssetSnapshot?

  init(
    io: any DestinationIOExecuting = DestinationIO(
      queue: DispatchQueue(label: "photo-export.photokit-reader", qos: .utility)),
    thumbnailBackend: any PhotoKitThumbnailBackend = ProductionThumbnailBackend(),
    lookup: @escaping @Sendable (String, Bool) -> PhotoKitAssetSnapshot? =
      { id, livePhotosPaired in lookupAsset(id: id, livePhotosPaired: livePhotosPaired) }
  ) {
    self.thumbnailReader = ProductionThumbnailReader(backend: thumbnailBackend)
    self.io = io
    self.lookup = lookup
  }

  func readAsset(id: String, livePhotosPaired: Bool) async -> PhotoKitAssetSnapshot? {
    await io.run { [lookup] in
      autoreleasepool { lookup(id, livePhotosPaired) }
    }
  }

  static func resourceDescriptor(
    type: PHAssetResourceType, filename: String, uniformTypeIdentifier: String, sizeValue: Any?
  ) -> ResourceDescriptor {
    ResourceDescriptor(
      type: type, originalFilename: filename, fileSize: positiveFileSize(sizeValue),
      uniformTypeIdentifier: uniformTypeIdentifier)
  }

  /// Keeps the existing optional metadata proof without downloading the resource's bytes.
  private static func positiveFileSize(_ value: Any?) -> Int64? {
    guard let size = value as? Int64, size > 0 else { return nil }
    return size
  }

  private static func lookupAsset(id: String, livePhotosPaired: Bool) -> PhotoKitAssetSnapshot? {
    let result = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
    guard let asset = result.firstObject else { return nil }
    let resources = PHAssetResource.assetResources(for: asset).map { resource in
      resourceDescriptor(
        type: resource.type, filename: resource.originalFilename,
        uniformTypeIdentifier: resource.uniformTypeIdentifier,
        sizeValue: resource.value(forKey: "fileSize"))
    }
    let descriptor = AssetDescriptor(
      id: asset.localIdentifier, creationDate: asset.creationDate, mediaType: asset.mediaType,
      pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight, duration: asset.duration,
      hasAdjustments: asset.hasAdjustments,
      isLivePhoto: asset.mediaSubtypes.contains(.photoLive))
    return PhotoKitAssetSnapshot.mapping(
      descriptor, resources: resources, livePhotosPaired: livePhotosPaired)
  }
}
