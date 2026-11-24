import Photos

/// Leaf PhotoKit operations invoked only through a serial utility executor.
protocol PhotoKitThumbnailBackend: Sendable {
  func resolveAssets(ids: [String]) -> [ThumbnailAsset]
  func coverAssets(in scope: PhotoFetchScope, options: PHFetchOptions) -> [ThumbnailAsset]
  func request(
    asset: ThumbnailAsset, size: CGSize, mode: PHImageContentMode,
    options: PHImageRequestOptions,
    completion: @escaping @Sendable (ThumbnailImageSource?) -> Void
  ) -> PHImageRequestID
  func cancel(_ id: PHImageRequestID)
  func startCaching(
    assets: [ThumbnailAsset], size: CGSize, mode: PHImageContentMode,
    options: PHImageRequestOptions)
  func stopCaching(
    assets: [ThumbnailAsset], size: CGSize, mode: PHImageContentMode,
    options: PHImageRequestOptions)
}
