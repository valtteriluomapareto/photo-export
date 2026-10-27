import AppKit
import Photos

/// Abstracts access to the Photos library for testability.
/// PhotoLibraryManager conforms in production; tests inject a fake.
@MainActor
protocol PhotoLibraryService: AnyObject, Sendable {
  var isAuthorized: Bool { get }
  var authorizationStatus: PHAuthorizationStatus { get }

  func requestAuthorization() async -> Bool
  func fetchAssets(year: Int, month: Int?, mediaType: PHAssetMediaType?) async throws
    -> [AssetDescriptor]
  func fetchAssetDescriptor(for assetId: String) -> AssetDescriptor?
  func countAssets(year: Int, month: Int) throws -> Int
  func countAssets(year: Int) throws -> Int

  /// Number of assets in the given month whose `hasAdjustments` is `true`. Implementations are
  /// allowed to cache this; `PHAsset.hasAdjustments` cannot be expressed as a Photos fetch
  /// predicate, so this is typically an iteration over the month's assets.
  func countAdjustedAssets(year: Int, month: Int) async throws -> Int

  /// Number of assets in the given year whose `hasAdjustments` is `true`. Sum of the monthly
  /// counts.
  func countAdjustedAssets(year: Int) async throws -> Int

  func availableYears() throws -> [Int]
  func availableYearsWithCounts() throws -> [(year: Int, count: Int)]

  /// UI inventory scans return values without enumerating Photos on the main actor.
  nonisolated func loadYearsWithCounts() async throws -> [PhotoLibraryYearCount]
  nonisolated func loadCollectionTree() async throws -> [PhotoCollectionDescriptor]

  // MARK: - Collections

  /// Fetches the user's Photos collection tree: a synthetic Favorites entry first, then
  /// user-created top-level albums and folders (folders contain albums and other folders).
  /// PhotoKit types do not leak — only `PhotoCollectionDescriptor` is returned.
  ///
  /// Implementations must invalidate any cached tree on `PHPhotoLibraryChangeObserver`
  /// callbacks; the sidebar relies on the tree being current.
  func fetchCollectionTree() throws -> [PhotoCollectionDescriptor]

  /// Fetches assets in a `PhotoFetchScope`. Used by both the timeline grid and the
  /// collection grids; the existing `fetchAssets(year:month:mediaType:)` becomes a
  /// wrapper around the `.timeline` case.
  func fetchAssets(in scope: PhotoFetchScope, mediaType: PHAssetMediaType?) async throws
    -> [AssetDescriptor]

  /// Streams assets in batches for the given scope. Implementations may emit a
  /// single batch for small fetches and multiple batches for large ones; the
  /// union of all yielded batches equals what `fetchAssets(in:mediaType:)`
  /// would return. The stream finishes when enumeration is complete (or the
  /// caller's Task is cancelled). Throws the same errors `fetchAssets`
  /// would throw — typically `authorizationDenied` or a fetch failure.
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

  func requestFullImage(for assetId: String) async throws -> NSImage

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

  func fetchAssets(year: Int, month: Int?) async throws -> [AssetDescriptor] {
    try await fetchAssets(year: year, month: month, mediaType: nil)
  }
}
