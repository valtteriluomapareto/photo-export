import AppKit
import Photos

@testable import Photo_Export

/// A `PhotoLibraryService` that records the name of every requirement it is asked for and
/// returns empty results. For checking that code makes no library calls at all, such as a view
/// model's init, which `@State` repeats on every view init.
@MainActor
final class RecordingPhotoLibraryService: PhotoLibraryService {
  private let recorded = LockedBox<[String]>([])
  /// Every call so far, in order.
  var calls: [String] { recorded.value }

  private nonisolated func record(_ name: String) {
    recorded.mutate { $0.append(name) }
  }

  var isAuthorized: Bool {
    record("isAuthorized")
    return true
  }
  var authorizationStatus: PHAuthorizationStatus {
    record("authorizationStatus")
    return .authorized
  }

  func requestAuthorization() async -> Bool {
    record("requestAuthorization")
    return true
  }
  func fetchAssets(year: Int, month: Int?, mediaType: PHAssetMediaType?) async throws
    -> [AssetDescriptor]
  {
    record("fetchAssets(year:month:mediaType:)")
    return []
  }
  func fetchAssetDescriptor(for assetId: String) -> AssetDescriptor? {
    record("fetchAssetDescriptor(for:)")
    return nil
  }
  func countAssets(year: Int, month: Int) throws -> Int {
    record("countAssets(year:month:)")
    return 0
  }
  func countAssets(year: Int) throws -> Int {
    record("countAssets(year:)")
    return 0
  }
  func countAdjustedAssets(year: Int, month: Int) async throws -> Int {
    record("countAdjustedAssets(year:month:)")
    return 0
  }
  func countAdjustedAssets(year: Int) async throws -> Int {
    record("countAdjustedAssets(year:)")
    return 0
  }
  nonisolated func loadYearsWithCounts() async throws -> [PhotoLibraryYearCount] {
    record("loadYearsWithCounts()")
    return []
  }

  nonisolated func loadCollectionTree() async throws -> [PhotoCollectionDescriptor] {
    record("loadCollectionTree()")
    return []
  }

  func availableYears() throws -> [Int] {
    record("availableYears()")
    return []
  }
  func availableYearsWithCounts() throws -> [(year: Int, count: Int)] {
    record("availableYearsWithCounts()")
    return []
  }
  func fetchCollectionTree() throws -> [PhotoCollectionDescriptor] {
    record("fetchCollectionTree()")
    return []
  }
  func fetchAssets(in scope: PhotoFetchScope, mediaType: PHAssetMediaType?) async throws
    -> [AssetDescriptor]
  {
    record("fetchAssets(in:mediaType:)")
    return []
  }
  nonisolated func fetchAssetsProgressive(
    in scope: PhotoFetchScope, mediaType: PHAssetMediaType?, batchSize: Int
  ) -> AsyncThrowingStream<[AssetDescriptor], any Error> {
    record("fetchAssetsProgressive(in:mediaType:batchSize:)")
    return AsyncThrowingStream { $0.finish() }
  }
  nonisolated func countAssets(in scope: PhotoFetchScope) async throws -> Int {
    record("countAssets(in:)")
    return 0
  }
  nonisolated func countAdjustedAssets(in scope: PhotoFetchScope) async throws -> Int {
    record("countAdjustedAssets(in:)")
    return 0
  }
  nonisolated func cachedCountAssets(in scope: PhotoFetchScope) async throws -> Int {
    record("cachedCountAssets(in:)")
    return 0
  }
  nonisolated func cachedCountAdjustedAssets(in scope: PhotoFetchScope) async throws -> Int {
    record("cachedCountAdjustedAssets(in:)")
    return 0
  }
  func startCachingThumbnails(for assets: [AssetDescriptor]) {
    record("startCachingThumbnails(for:)")
  }
  func stopCachingThumbnails(for assets: [AssetDescriptor]) {
    record("stopCachingThumbnails(for:)")
  }
  func loadThumbnail(for assetId: String, allowNetwork: Bool) async -> NSImage? {
    record("loadThumbnail(for:allowNetwork:)")
    return nil
  }
  func loadThumbnailHighQuality(
    for assetId: String, pixelSize: CGSize?, allowNetwork: Bool
  ) async -> NSImage? {
    record("loadThumbnailHighQuality(for:pixelSize:allowNetwork:)")
    return nil
  }
  func decodedThumbnail(
    for assetId: String, quantizedSize: CGSize, deliveryMode: ThumbnailDeliveryMode
  ) async -> CGImage? {
    record("decodedThumbnail(for:quantizedSize:deliveryMode:)")
    return nil
  }
  func cachedDecodedThumbnail(
    for assetId: String, quantizedSize: CGSize, deliveryMode: ThumbnailDeliveryMode
  ) -> CGImage? {
    record("cachedDecodedThumbnail(for:quantizedSize:deliveryMode:)")
    return nil
  }
  func requestPreview(
    for assetId: String, pixelSize: CGSize,
    onDegraded: @escaping @MainActor @Sendable (NSImage) -> Void
  ) async throws -> NSImage {
    record("requestPreview(for:pixelSize:onDegraded:)")
    return NSImage(size: pixelSize)
  }

  func requestFullImage(for assetId: String) async throws -> NSImage {
    record("requestFullImage(for:)")
    return NSImage()
  }
  func resources(for assetId: String) -> [ResourceDescriptor] {
    record("resources(for:)")
    return []
  }
  func assetDetails(for assetId: String) -> AssetDetails? {
    record("assetDetails(for:)")
    return nil
  }
}
