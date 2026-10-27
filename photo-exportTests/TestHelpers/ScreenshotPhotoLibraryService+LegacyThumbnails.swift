import AppKit

@testable import Photo_Export

extension ScreenshotPhotoLibraryService {
  func startCachingThumbnails(for assets: [AssetDescriptor]) {}
  func stopCachingThumbnails(for assets: [AssetDescriptor]) {}

  func loadThumbnail(for assetId: String, allowNetwork: Bool) async -> NSImage? {
    legacyThumbnail(for: assetId, size: ThumbnailRequestSpec.gridSize, delivery: .fast)
  }

  func loadThumbnailHighQuality(
    for assetId: String, pixelSize: CGSize? = nil, allowNetwork: Bool
  ) async -> NSImage? {
    legacyThumbnail(
      for: assetId, size: pixelSize ?? CGSize(width: 1024, height: 1024), delivery: .highQuality)
  }

  private func legacyThumbnail(
    for assetId: String, size: CGSize, delivery: ThumbnailDeliveryMode
  ) -> NSImage? {
    cachedDecodedThumbnail(for: assetId, quantizedSize: size, deliveryMode: delivery)
      .map { NSImage(cgImage: $0, size: size) }
  }
}
