import Foundation

/// Shares the curated library's value factories and never falls through to PhotoKit.
@MainActor
struct ScreenshotPhotoKitReader: PhotoKitReading {
  let service: ScreenshotPhotoLibraryService

  var thumbnailReader: (any ThumbnailReading)? {
    ServiceThumbnailReader(service: service, requireKnownAsset: true)
  }

  func readAsset(id: String, livePhotosPaired: Bool) async -> PhotoKitAssetSnapshot? {
    guard let descriptor = service.fetchAssetDescriptor(for: id) else { return nil }
    return PhotoKitAssetSnapshot(descriptor: descriptor, resources: service.resources(for: id))
  }
}
