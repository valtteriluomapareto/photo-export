import Foundation

/// Refreshes one export job's metadata without sharing PhotoKit objects with its caller.
protocol PhotoKitReading: Sendable {
  func readAsset(id: String, livePhotosPaired: Bool) async -> PhotoKitAssetSnapshot?
}

struct PhotoKitAssetSnapshot: Sendable {
  let descriptor: AssetDescriptor
  let resources: [ResourceDescriptor]
  let resourceWriter: (any AssetResourceWriter)?

  init(
    descriptor: AssetDescriptor, resources: [ResourceDescriptor],
    resourceWriter: (any AssetResourceWriter)? = nil
  ) {
    self.descriptor = descriptor
    self.resources = resources
    self.resourceWriter = resourceWriter
  }

  static func mapping(
    _ asset: AssetDescriptor, resources: [ResourceDescriptor], livePhotosPaired: Bool,
    resourceWriter: (any AssetResourceWriter)? = nil
  ) -> Self {
    let original = ResourceSelection.selectOriginalResource(
      from: resources, mediaType: asset.mediaType)
    let live =
      asset.mediaType == .image
      && (asset.isLivePhoto
        || (livePhotosPaired
          && resources.contains { $0.type == .pairedVideo || $0.type == .fullSizePairedVideo }))
    return Self(
      descriptor: AssetDescriptor(
        id: asset.id, creationDate: asset.creationDate, mediaType: asset.mediaType,
        pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight, duration: asset.duration,
        hasAdjustments: asset.hasAdjustments, originalUTI: original?.uniformTypeIdentifier,
        isLivePhoto: live),
      resources: resources, resourceWriter: resourceWriter)
  }
}

/// Preserves source compatibility for callers that already supply a synthetic library service.
/// Shipping composition supplies its export reader explicitly.
@MainActor
struct PhotoLibraryServiceReader: PhotoKitReading {
  let service: any PhotoLibraryService

  func readAsset(id: String, livePhotosPaired: Bool) async -> PhotoKitAssetSnapshot? {
    guard let descriptor = service.fetchAssetDescriptor(for: id) else { return nil }
    return PhotoKitAssetSnapshot(descriptor: descriptor, resources: service.resources(for: id))
  }
}
