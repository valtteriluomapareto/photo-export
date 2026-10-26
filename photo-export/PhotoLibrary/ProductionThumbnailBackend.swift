import Photos

/// All mutable manager state is confined to the owning reader's serial executor.
final class ProductionThumbnailBackend: PhotoKitThumbnailBackend, @unchecked Sendable {
  private lazy var manager = PHCachingImageManager()

  func resolveAssets(ids: [String]) -> [ThumbnailAsset] {
    let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
    var handles: [String: ThumbnailAsset] = [:]
    result.enumerateObjects { asset, _, _ in
      handles[asset.localIdentifier] = Self.handle(asset)
    }
    return ids.compactMap { handles[$0] }
  }

  func coverAssets(in scope: PhotoFetchScope, options: PHFetchOptions) -> [ThumbnailAsset] {
    let result: PHFetchResult<PHAsset>
    switch scope {
    case .timeline, .favorites:
      result = PHAsset.fetchAssets(with: options)
    case .album(let id), .sharedAlbum(let id):
      guard let collection = PhotoLibraryManager.fetchAssetCollection(localIdentifier: id)
      else { return [] }
      result = PHAsset.fetchAssets(in: collection, options: options)
    }
    return (0..<min(result.count, options.fetchLimit)).map { Self.handle(result.object(at: $0)) }
  }

  private static func handle(_ asset: PHAsset) -> ThumbnailAsset {
    let descriptor = AssetDescriptor(
      id: asset.localIdentifier, creationDate: asset.creationDate, mediaType: asset.mediaType,
      pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight, duration: asset.duration,
      hasAdjustments: asset.hasAdjustments, isLivePhoto: asset.mediaSubtypes.contains(.photoLive))
    return ThumbnailAsset(descriptor: descriptor, photoKitAsset: asset)
  }

  func request(
    asset: ThumbnailAsset, size: CGSize, mode: PHImageContentMode,
    options: PHImageRequestOptions,
    completion: @escaping @Sendable (ThumbnailImageSource?) -> Void
  ) -> PHImageRequestID {
    guard let photo = asset.photoKitAsset else {
      completion(nil)
      return PHInvalidImageRequestID
    }
    return manager.requestImage(for: photo, targetSize: size, contentMode: mode, options: options) {
      image, info in
      if options.deliveryMode == .highQualityFormat,
        (info?[PHImageResultIsDegradedKey] as? Bool) == true
      {
        return
      }
      // The callback retains the source until Photos physically finishes the request.
      withExtendedLifetime(asset) { completion(image.map(ThumbnailImageSource.init)) }
    }
  }

  func cancel(_ id: PHImageRequestID) { manager.cancelImageRequest(id) }

  func startCaching(
    assets: [ThumbnailAsset], size: CGSize, mode: PHImageContentMode,
    options: PHImageRequestOptions
  ) {
    manager.startCachingImages(
      for: assets.compactMap(\.photoKitAsset), targetSize: size, contentMode: mode, options: options
    )
  }

  func stopCaching(
    assets: [ThumbnailAsset], size: CGSize, mode: PHImageContentMode,
    options: PHImageRequestOptions
  ) {
    manager.stopCachingImages(
      for: assets.compactMap(\.photoKitAsset), targetSize: size, contentMode: mode, options: options
    )
  }
}
