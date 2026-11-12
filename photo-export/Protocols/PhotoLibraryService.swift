import AppKit
import Photos

/// Abstracts access to the Photos library for testability.
/// PhotoLibraryManager conforms in production; tests inject a fake.
@MainActor
protocol PhotoLibraryService: AnyObject, Sendable {
  var isAuthorized: Bool { get }
  var authorizationStatus: PHAuthorizationStatus { get }

  func requestAuthorization() async -> Bool
  func fetchAssetDescriptor(for assetId: String) -> AssetDescriptor?

  func availableYears() throws -> [Int]
  func availableYearsWithCounts() throws -> [(year: Int, count: Int)]

  /// UI inventory scans return values without enumerating Photos on the main actor.
  nonisolated func loadYearsWithCounts() async throws -> [PhotoLibraryYearCount]
  /// A synthetic Favorites entry first, then user albums and folders, then shared albums.
  /// A cached tree must not outlive a library change.
  nonisolated func loadCollectionTree() async throws -> [PhotoCollectionDescriptor]

  // MARK: - Collections

  /// Streams a scope's assets in batches. `PhotoLibraryManager` limits each batch to
  /// `batchSize` and yields assets by creation date, oldest first. Screenshot mode may emit
  /// its entire curated scope as one batch. The stream
  /// finishes when enumeration completes, and also, silently, when the caller's task is
  /// cancelled, so a caller collecting a whole scope checks cancellation afterwards. Throws
  /// `authorizationDenied` without Photos access.
  nonisolated func fetchAssetsProgressive(
    in scope: PhotoFetchScope, mediaType: PHAssetMediaType?, batchSize: Int
  ) -> AsyncThrowingStream<[AssetDescriptor], any Error>

  /// Uncached asset count for a scope; every call re-fetches. The cached counterpart
  /// coalesces concurrent reads through `CollectionCountCache`.
  /// Declared `nonisolated async` so implementations can build the fetch off the
  /// main actor; counting many albums on launch would otherwise block the UI.
  nonisolated func countAssets(in scope: PhotoFetchScope) async throws -> Int

  /// Number of assets in a fetch scope whose `hasAdjustments` is `true`. `nonisolated`
  /// for the same reason as `countAssets(in:)`.
  nonisolated func countAdjustedAssets(in scope: PhotoFetchScope) async throws -> Int

  // MARK: - Cached counts

  /// Cached version of `countAssets(in:)`. The same scope returns a cached value until
  /// the next `PHPhotoLibraryChangeObserver` callback invalidates the cache. Concurrent
  /// callers for the same scope share one in-flight fetch.
  nonisolated func cachedCountAssets(in scope: PhotoFetchScope) async throws -> Int

  /// Cached version of `countAdjustedAssets(in:)`.
  nonisolated func cachedCountAdjustedAssets(in scope: PhotoFetchScope) async throws -> Int

  var thumbnailReader: any ThumbnailReading { get }

  func resolveThumbnailAssets(ids: [String]) async -> [ThumbnailAsset]
  func preheatThumbnailAssets(start: [ThumbnailAsset], stop: [ThumbnailAsset]) async
  func thumbnailContentRevision(for assetId: String) -> Int
  func coverAssets(in scope: PhotoFetchScope, limit: Int) async throws -> [AssetDescriptor]

  // MARK: - Decoded thumbnail cache

  /// Async load through the decoded-thumbnail cache. `quantizedSize` is
  /// pre-bucketed by the caller.
  func decodedThumbnail(
    for assetId: String, quantizedSize: CGSize, deliveryMode: ThumbnailDeliveryMode
  ) async -> CGImage?

  /// Synchronous cache probe; nil if absent or evicted.
  func cachedDecodedThumbnail(
    for assetId: String, quantizedSize: CGSize, deliveryMode: ThumbnailDeliveryMode
  ) -> CGImage?

  /// Bounded detail preview. A degraded image may arrive before the final result.
  func requestPreview(
    for assetId: String, pixelSize: CGSize,
    onDegraded: @escaping @MainActor @Sendable (NSImage) -> Void
  ) async throws -> NSImage

  func resources(for assetId: String) -> [ResourceDescriptor]
  func assetDetails(for assetId: String) -> AssetDetails?
}

extension PhotoLibraryService {
  func resolveThumbnailAssets(ids: [String]) async -> [ThumbnailAsset] {
    await thumbnailReader.resolveAssets(ids: ids)
  }

  func preheatThumbnailAssets(start: [ThumbnailAsset], stop: [ThumbnailAsset]) async {
    await thumbnailReader.preheat(start: start, stop: stop)
  }

  func thumbnailContentRevision(for assetId: String) -> Int { 0 }

  func coverAssets(in scope: PhotoFetchScope, limit: Int) async throws -> [AssetDescriptor] {
    try await thumbnailReader.coverThumbnails(in: scope, limit: limit).map(\.descriptor)
  }
}
