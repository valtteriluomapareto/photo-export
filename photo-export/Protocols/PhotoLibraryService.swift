import AppKit
import Photos

/// Abstracts access to the Photos library for testability.
/// PhotoLibraryManager conforms in production; tests inject a fake.
@MainActor
protocol PhotoLibraryService: AnyObject {
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

  // MARK: - Collections (Phase 2)

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

  /// Number of assets in a fetch scope. Phase 2 keeps these uncached — every call
  /// re-fetches. Phase 3 introduces a `CollectionCountCache` actor.
  ///
  /// Declared `nonisolated async` so implementations can build the `PHFetchResult` off
  /// the main actor (counting many albums on launch otherwise blocks the UI). The plan
  /// permits a `@MainActor`-bound fallback if measurement shows `Task.detached` is
  /// incompatible with PhotoKit threading; current implementations are detached.
  nonisolated func countAssets(in scope: PhotoFetchScope) async throws -> Int

  /// Number of assets in a fetch scope whose `hasAdjustments` is `true`. `nonisolated`
  /// for the same reason as `countAssets(in:)`.
  nonisolated func countAdjustedAssets(in scope: PhotoFetchScope) async throws -> Int

  // MARK: - Cached counts (Phase 3)

  /// Cached version of `countAssets(in:)`. The same scope returns a cached value until
  /// the next `PHPhotoLibraryChangeObserver` callback invalidates the cache. Concurrent
  /// callers for the same scope share one in-flight fetch.
  nonisolated func cachedCountAssets(in scope: PhotoFetchScope) async throws -> Int

  /// Cached version of `countAdjustedAssets(in:)`.
  nonisolated func cachedCountAdjustedAssets(in scope: PhotoFetchScope) async throws -> Int

  func startCachingThumbnails(for assets: [AssetDescriptor])
  func stopCachingThumbnails(for assets: [AssetDescriptor])
  func loadThumbnail(for assetId: String, allowNetwork: Bool) async -> NSImage?
  /// `pixelSize`, when supplied, replaces the default 200×200 px target. Tile
  /// views in particular need ~360×360 px on Retina (180pt × 2x scale) for
  /// the single-cover case to read sharply; the default leaves them blurry.
  func loadThumbnailHighQuality(
    for assetId: String, pixelSize: CGSize?, allowNetwork: Bool
  ) async -> NSImage?

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

  func requestFullImage(for assetId: String) async throws -> NSImage

  func resources(for assetId: String) -> [ResourceDescriptor]
  func assetDetails(for assetId: String) -> AssetDetails?
}

extension PhotoLibraryService {
  func fetchAssets(year: Int, month: Int?) async throws -> [AssetDescriptor] {
    try await fetchAssets(year: year, month: month, mediaType: nil)
  }
}
