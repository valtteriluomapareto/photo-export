import AppKit
import Photos

@testable import Photo_Export

final class FakeThumbnailBackend: PhotoKitThumbnailBackend, @unchecked Sendable {
  struct Options: Equatable {
    let size: CGSize
    let mode: PHImageContentMode
    let delivery: PHImageRequestOptionsDeliveryMode
    let resize: PHImageRequestOptionsResizeMode
    let network: Bool
  }
  struct Call {
    let action: String
    let options: Options
    let onMain: Bool
  }
  struct Query {
    let limit: Int
    let hasPredicate: Bool
    let sortKeys: [String]
    let onMain: Bool
  }
  let resolveCalls = LockedBox<[[String]]>([])
  let resolveOverride = LockedBox<(@Sendable ([String]) -> [ThumbnailAsset])?>(nil)
  let calls = LockedBox<[Call]>([])
  let queries = LockedBox<[Query]>([])
  private let assets: [AssetDescriptor]
  private let image: CGImage

  init(assets: [AssetDescriptor]) {
    self.assets = assets
    let context = CGContext(
      data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    image = context.makeImage()!
  }

  func resolveAssets(ids: [String]) -> [ThumbnailAsset] {
    resolveCalls.mutate { $0.append(ids) }
    if let override = resolveOverride.value { return override(ids) }
    return assets.filter { ids.contains($0.id) }.map(ThumbnailAsset.synthetic)
  }

  func coverAssets(in scope: PhotoFetchScope, options: PHFetchOptions) -> [ThumbnailAsset] {
    queries.mutate {
      $0.append(
        Query(
          limit: options.fetchLimit, hasPredicate: options.predicate != nil,
          sortKeys: options.sortDescriptors?.compactMap(\.key) ?? [], onMain: Thread.isMainThread))
    }
    return assets.map(ThumbnailAsset.synthetic)
  }

  func request(
    asset: ThumbnailAsset, size: CGSize, mode: PHImageContentMode,
    options: PHImageRequestOptions,
    completion: @escaping @Sendable (ThumbnailImageSource?) -> Void
  ) -> PHImageRequestID {
    record("request", size: size, mode: mode, options: options)
    completion(ThumbnailImageSource(image))
    return 1
  }

  func cancel(_ id: PHImageRequestID) {}

  func startCaching(
    assets: [ThumbnailAsset], size: CGSize, mode: PHImageContentMode,
    options: PHImageRequestOptions
  ) { record("start", size: size, mode: mode, options: options) }

  func stopCaching(
    assets: [ThumbnailAsset], size: CGSize, mode: PHImageContentMode,
    options: PHImageRequestOptions
  ) { record("stop", size: size, mode: mode, options: options) }

  private func record(
    _ action: String, size: CGSize, mode: PHImageContentMode, options: PHImageRequestOptions
  ) {
    calls.mutate {
      $0.append(
        Call(
          action: action,
          options: Options(
            size: size, mode: mode, delivery: options.deliveryMode, resize: options.resizeMode,
            network: options.isNetworkAccessAllowed), onMain: Thread.isMainThread))
    }
  }
}
