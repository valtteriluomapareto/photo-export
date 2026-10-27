import CoreGraphics
import Foundation

/// Keeps synthetic libraries behind their injected service, including identifiers with no image.
@MainActor
struct ServiceThumbnailReader: ThumbnailReading {
  let service: any PhotoLibraryService

  func resolveAssets(ids: [String]) async -> [ThumbnailAsset] {
    ids.compactMap { id -> ThumbnailAsset? in
      if let asset = service.fetchAssetDescriptor(for: id) { return .synthetic(asset) }
      // Legacy synthetic decoders can provide an image by identifier without a catalog row.
      return .synthetic(
        AssetDescriptor(
          id: id, creationDate: nil, mediaType: .image, pixelWidth: 0, pixelHeight: 0,
          duration: 0, hasAdjustments: false))
    }
  }

  func image(for asset: ThumbnailAsset, spec: ThumbnailRequestSpec) async -> CGImage? {
    // This seam already returns decoded pixels; retain their identity for synthetic consumers.
    await service.decodedThumbnail(
      for: asset.descriptor.id, quantizedSize: spec.size, deliveryMode: spec.delivery)
  }

  func preheat(start: [ThumbnailAsset], stop: [ThumbnailAsset]) async {
    if !stop.isEmpty { service.stopCachingThumbnails(for: stop.map(\.descriptor)) }
    if !start.isEmpty { service.startCachingThumbnails(for: start.map(\.descriptor)) }
  }

  func coverAssets(in scope: PhotoFetchScope, limit: Int) async throws -> [ThumbnailAsset] {
    let assets = try await service.fetchAssets(in: scope, mediaType: nil)
    return assets.prefix(max(0, min(limit, 4))).map(ThumbnailAsset.synthetic)
  }
}

struct UnavailableThumbnailReader: ThumbnailReading {
  func resolveAssets(ids: [String]) async -> [ThumbnailAsset] { [] }
  func image(for asset: ThumbnailAsset, spec: ThumbnailRequestSpec) async -> CGImage? { nil }
  func preheat(start: [ThumbnailAsset], stop: [ThumbnailAsset]) async {}
  func coverAssets(in scope: PhotoFetchScope, limit: Int) async throws -> [ThumbnailAsset] { [] }
}
