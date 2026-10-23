import AppKit
import Foundation
import Photos

@testable import Photo_Export

@MainActor
final class FakePhotoLibraryService: PhotoLibraryService {
  var isAuthorized: Bool = true
  var authorizationStatus: PHAuthorizationStatus = .authorized

  var cachedCountOverride: (@MainActor (PhotoFetchScope, Bool) async throws -> Int)?

  // Canned data
  /// Timeline catalog grouped for fixture setup; queries filter creationDate across every bucket.
  var assetsByYearMonth: [String: [AssetDescriptor]] = [:]
  /// Canned favorites assets returned by `.favorites` scope fetches.
  var favoritesAssets: [AssetDescriptor] = []
  /// Canned per-album assets keyed by album localIdentifier.
  var assetsByAlbumLocalId: [String: [AssetDescriptor]] = [:]
  /// Canned per-shared-album assets keyed by shared-album localIdentifier. Stored
  /// separately from `assetsByAlbumLocalId` so a test fixture can give the same
  /// id different contents under the two scopes when needed; in practice most tests
  /// will only populate one or the other.
  var assetsBySharedAlbumLocalId: [String: [AssetDescriptor]] = [:]
  /// Canned collection tree returned by `fetchCollectionTree()`. Empty by default.
  var collectionTree: [PhotoCollectionDescriptor] = []
  var collectionTreeError: Error?
  /// Asset IDs that fetchAssetDescriptor should treat as missing, even if they
  /// are present in assetsByYearMonth. Simulates an asset being deleted from the
  /// Photos library after it was enqueued for export.
  var missingAssetIds: Set<String> = []
  var resourcesByAssetId: [String: [ResourceDescriptor]] = [:]
  var detailsByAssetId: [String: AssetDetails] = [:]
  var thumbnailsByAssetId: [String: NSImage] = [:]
  var hqThumbnailsByAssetId: [String: NSImage] = [:]
  var fullImagesByAssetId: [String: NSImage] = [:]
  var yearCounts: [(year: Int, count: Int)] = []
  /// Thrown by the year-listing calls. Production throws `authorizationDenied` there
  /// without Photos access, so access tests set both this and `isAuthorized`.
  var availableYearsError: Error?
  var availableYearsObserver: (@MainActor () -> Void)?

  // Call tracking
  var fetchAssetsCalls: [(year: Int, month: Int?, mediaType: PHAssetMediaType?)] = []
  var startCachingCalls: [[AssetDescriptor]] = []
  var stopCachingCalls: [[AssetDescriptor]] = []

  // Error injection
  var fetchAssetsError: Error?
  /// Per-album error injection. When `fetchAssets(in: .album(id))` is called and
  /// `id` is in this map, the fake throws the mapped error instead of returning the
  /// canned assets. Used to exercise partial-enqueue failure paths.
  var fetchAssetsErrorByAlbumId: [String: Error] = [:]
  /// Per-album release-on-demand checkpoint. When `fetchAssets(in: .album(id))` is
  /// called and `id` is in this map, the fake calls `await checkpoint.enter()`
  /// before any per-album error handling, so the gate signals "the enqueue
  /// loop reached this album fetch." Tests can `waitForEnter(count:)` to assert
  /// the loop is suspended on this album, take some action (pause, start another
  /// export), then `release(_:)` or `releaseAll()`.
  ///
  /// Harness teardown must call `await checkpoint.releaseAll()` so a suspended
  /// fetch task can't outlive the test.
  var fetchAssetsCheckpointByAlbumId: [String: AsyncCheckpoint] = [:]
  /// Per-year error injection. Mirrors `fetchAssetsErrorByAlbumId` but matches on
  /// the `year` argument of timeline fetches (regardless of whether `month` is set).
  /// Used to exercise the partial-enqueue failure path in
  /// `ExportManager.startExportTimelineSelection`.
  var fetchAssetsErrorByYear: [Int: Error] = [:]
  /// Per-year release-on-demand checkpoint. When `fetchAssets(year:month:)` is
  /// called and `year` is in this map, the fake calls `await checkpoint.enter()`
  /// before evaluating any error/data branches. Tests use this to pin the
  /// "enqueue loop suspended between years" window open while they exercise
  /// cancellation or pause.
  var fetchAssetsCheckpointByYear: [Int: AsyncCheckpoint] = [:]
  var requestFullImageError: Error?
  /// Deferred requests let preview tests control completion order and cancellation.
  var fullImageRequestOverride: (@MainActor (String) async throws -> NSImage)?

  private(set) var requestAuthorizationCalls = 0
  func requestAuthorization() async -> Bool {
    requestAuthorizationCalls += 1
    return isAuthorized
  }

  func fetchAssets(year: Int, month: Int?, mediaType: PHAssetMediaType?) async throws
    -> [AssetDescriptor]
  {
    fetchAssetsCalls.append((year, month, mediaType))
    if let checkpoint = fetchAssetsCheckpointByYear[year] {
      await checkpoint.enter()
    }
    if let error = fetchAssetsErrorByYear[year] { throw error }
    if let error = fetchAssetsError { throw error }

    return sortedAssets(timelineAssets(year: year, month: month), mediaType: mediaType)
  }

  private func timelineAssets(year: Int, month: Int?) -> [AssetDescriptor] {
    let calendar = Calendar.current
    guard let start = calendar.date(from: DateComponents(year: year, month: month ?? 1, day: 1)),
      let end = calendar.date(byAdding: month == nil ? .year : .month, value: 1, to: start)
    else { return [] }
    return assetsByYearMonth.values.flatMap { $0 }.filter {
      guard let date = $0.creationDate else { return false }
      return date >= start && date < end
    }
  }

  // Timeline predicates exclude nil dates; collections keep them before dated assets.
  // Equal dates have no secondary ordering, matching the production date-only sort.
  private func sortedAssets(_ assets: [AssetDescriptor], mediaType: PHAssetMediaType?)
    -> [AssetDescriptor]
  {
    assets.filter { mediaType == nil || $0.mediaType == mediaType }.sorted {
      switch ($0.creationDate, $1.creationDate) {
      case (let first?, let second?): return first < second
      case (nil, .some): return true
      default: return false
      }
    }
  }

  private func cannedAssets(in scope: PhotoFetchScope) -> [AssetDescriptor] {
    switch scope {
    case .timeline(let year, let month): return timelineAssets(year: year, month: month)
    case .favorites: return favoritesAssets
    case .album(let id): return assetsByAlbumLocalId[id] ?? []
    case .sharedAlbum(let id): return assetsBySharedAlbumLocalId[id] ?? []
    }
  }

  var descriptorFetchCalls: [String] = []
  var descriptorFetchObserver: ((String) -> Void)?
  var detailsFetchCalls: [String] = []

  func fetchAssetDescriptor(for assetId: String) -> AssetDescriptor? {
    descriptorFetchCalls.append(assetId)
    descriptorFetchObserver?(assetId)
    if missingAssetIds.contains(assetId) { return nil }
    for assets in assetsByYearMonth.values {
      if let found = assets.first(where: { $0.id == assetId }) { return found }
    }
    if let found = favoritesAssets.first(where: { $0.id == assetId }) { return found }
    for assets in assetsByAlbumLocalId.values {
      if let found = assets.first(where: { $0.id == assetId }) { return found }
    }
    for assets in assetsBySharedAlbumLocalId.values {
      if let found = assets.first(where: { $0.id == assetId }) { return found }
    }
    return nil
  }

  func countAssets(year: Int, month: Int) throws -> Int {
    timelineAssets(year: year, month: month).count
  }

  func countAssets(year: Int) throws -> Int {
    timelineAssets(year: year, month: nil).count
  }

  func countAdjustedAssets(year: Int, month: Int) async throws -> Int {
    timelineAssets(year: year, month: month).filter(\.hasAdjustments).count
  }

  func countAdjustedAssets(year: Int) async throws -> Int {
    timelineAssets(year: year, month: nil).filter(\.hasAdjustments).count
  }

  func availableYears() throws -> [Int] {
    availableYearsObserver?()
    if let error = availableYearsError { throw error }
    return yearCounts.map(\.year)
  }

  func availableYearsWithCounts() throws -> [(year: Int, count: Int)] {
    if let error = availableYearsError { throw error }
    return yearCounts
  }

  // MARK: - Phase 2: Collections

  func fetchCollectionTree() throws -> [PhotoCollectionDescriptor] {
    if let error = collectionTreeError { throw error }
    return collectionTree
  }

  /// Every `fetchAssets(in:mediaType:)` scope, in call order.
  private(set) var scopeFetchCalls: [PhotoFetchScope] = []

  func fetchAssets(in scope: PhotoFetchScope, mediaType: PHAssetMediaType?) async throws
    -> [AssetDescriptor]
  {
    scopeFetchCalls.append(scope)
    if let error = fetchAssetsError { throw error }
    switch scope {
    case .timeline(let year, let month):
      return try await fetchAssets(year: year, month: month, mediaType: mediaType)
    case .favorites:
      return sortedAssets(favoritesAssets, mediaType: mediaType)
    case .album(let collectionId):
      // The checkpoint precedes errors so tests can change the result while held.
      if let checkpoint = fetchAssetsCheckpointByAlbumId[collectionId] {
        await checkpoint.enter()
      }
      if let perAlbumError = fetchAssetsErrorByAlbumId[collectionId] {
        throw perAlbumError
      }
      return sortedAssets(assetsByAlbumLocalId[collectionId] ?? [], mediaType: mediaType)
    case .sharedAlbum(let collectionId):
      // User and shared albums share error/checkpoint settings keyed by collection id.
      if let checkpoint = fetchAssetsCheckpointByAlbumId[collectionId] {
        await checkpoint.enter()
      }
      if let perAlbumError = fetchAssetsErrorByAlbumId[collectionId] {
        throw perAlbumError
      }
      return sortedAssets(assetsBySharedAlbumLocalId[collectionId] ?? [], mediaType: mediaType)
    }
  }

  /// Yields the same assets `fetchAssets(in:mediaType:)` would return, but
  /// chopped into `batchSize`-sized chunks. Tests that want to observe
  /// intermediate state can set `progressiveCheckpointByScopeKey` to gate
  /// each batch on a checkpoint.
  nonisolated func fetchAssetsProgressive(
    in scope: PhotoFetchScope, mediaType: PHAssetMediaType?, batchSize: Int
  ) -> AsyncThrowingStream<[AssetDescriptor], any Error> {
    AsyncThrowingStream { continuation in
      let task = Task { @MainActor [weak self] in
        guard let self else {
          continuation.finish()
          return
        }
        if let stream = self.progressiveStreamOverride?(scope) {
          do {
            for try await batch in stream { continuation.yield(batch) }
            continuation.finish()
          } catch {
            continuation.finish(throwing: error)
          }
          return
        }
        let all: [AssetDescriptor]
        do {
          all = try await self.fetchAssets(in: scope, mediaType: mediaType)
        } catch {
          continuation.finish(throwing: error)
          return
        }
        let chunk = max(1, batchSize)
        var index = 0
        let scopeKey = Self.progressiveScopeKey(for: scope)
        while index < all.count {
          if Task.isCancelled {
            continuation.finish()
            return
          }
          if let gate = self.progressiveCheckpointByScopeKey[scopeKey] {
            await gate.enter()
          }
          let end = min(index + chunk, all.count)
          continuation.yield(Array(all[index..<end]))
          index = end
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Per-scope release-on-demand checkpoint for progressive streaming. When
  /// set, the fake suspends before yielding each batch — tests use this to
  /// observe partial state. Same shape as
  /// `fetchAssetsCheckpointByAlbumId` / `fetchAssetsCheckpointByYear`.
  var progressiveCheckpointByScopeKey: [String: AsyncCheckpoint] = [:]

  /// Test-only stream factory, invoked separately for each request on the main
  /// actor. Controlled continuations let race tests complete same-scope requests
  /// out of order, which a per-scope checkpoint cannot distinguish.
  var progressiveStreamOverride:
    (@MainActor (PhotoFetchScope) -> AsyncThrowingStream<[AssetDescriptor], any Error>?)?

  nonisolated fileprivate static func progressiveScopeKey(for scope: PhotoFetchScope)
    -> String
  {
    switch scope {
    case .timeline(let year, let month):
      return "timeline:\(year)-\(month.map(String.init) ?? "all")"
    case .favorites:
      return "favorites"
    case .album(let id):
      return "album:\(id)"
    case .sharedAlbum(let id):
      return "shared-album:\(id)"
    }
  }

  nonisolated func countAssets(in scope: PhotoFetchScope) async throws -> Int {
    await MainActor.run { self.cannedAssets(in: scope).count }
  }

  /// Phase 3 cache. Tests can read `collectionCountCache` to assert hit/miss behavior.
  nonisolated let collectionCountCache = CollectionCountCache()

  nonisolated func cachedCountAssets(in scope: PhotoFetchScope) async throws -> Int {
    if let override = await cachedCountOverride { return try await override(scope, false) }
    return try await collectionCountCache.count(
      for: Self.cacheKey(for: scope, adjusted: false)
    ) {
      try await self.countAssets(in: scope)
    }
  }

  nonisolated func cachedCountAdjustedAssets(in scope: PhotoFetchScope) async throws -> Int {
    if let override = await cachedCountOverride { return try await override(scope, true) }
    return try await collectionCountCache.count(
      for: Self.cacheKey(for: scope, adjusted: true)
    ) {
      try await self.countAdjustedAssets(in: scope)
    }
  }

  nonisolated fileprivate static func cacheKey(for scope: PhotoFetchScope, adjusted: Bool)
    -> String
  {
    let suffix = adjusted ? "@adjusted" : "@total"
    switch scope {
    case .timeline(let year, let month):
      return "timeline:\(year)-\(month.map(String.init) ?? "all")\(suffix)"
    case .favorites:
      return "favorites\(suffix)"
    case .album(let id):
      return "album:\(id)\(suffix)"
    case .sharedAlbum(let id):
      return "shared-album:\(id)\(suffix)"
    }
  }

  nonisolated func countAdjustedAssets(in scope: PhotoFetchScope) async throws -> Int {
    await MainActor.run { self.cannedAssets(in: scope).filter(\.hasAdjustments).count }
  }

  func startCachingThumbnails(for assets: [AssetDescriptor]) {
    startCachingCalls.append(assets)
  }

  func stopCachingThumbnails(for assets: [AssetDescriptor]) {
    stopCachingCalls.append(assets)
  }

  /// Asset ids whose thumbnail is "still syncing from iCloud" — the local cache is
  /// empty and only an `allowNetwork: true` call can produce the image. Lets tests
  /// reproduce the freshly-arrived-from-iCloud case where
  /// `photoLibraryDidChange` has fired but PhotoKit hasn't cached the thumbnail
  /// bytes locally yet.
  var thumbnailRequiresNetwork: Set<String> = []

  /// `(assetId, allowNetwork)` records of every `loadThumbnail` call, in order.
  var loadThumbnailCalls: [(assetId: String, allowNetwork: Bool)] = []

  func loadThumbnail(for assetId: String, allowNetwork: Bool) async -> NSImage? {
    loadThumbnailCalls.append((assetId, allowNetwork))
    if thumbnailRequiresNetwork.contains(assetId), !allowNetwork {
      return nil
    }
    return thumbnailsByAssetId[assetId]
  }

  func loadThumbnailHighQuality(
    for assetId: String, pixelSize: CGSize?, allowNetwork: Bool
  ) async -> NSImage? {
    hqThumbnailsByAssetId[assetId]
  }

  var decodedThumbnailCalls: [(assetId: String, deliveryMode: ThumbnailDeliveryMode)] = []
  var decodedThumbnailOverride:
    (@MainActor (String, CGSize, ThumbnailDeliveryMode) async -> CGImage?)?

  func decodedThumbnail(
    for assetId: String, quantizedSize: CGSize, deliveryMode: ThumbnailDeliveryMode
  ) async -> CGImage? {
    decodedThumbnailCalls.append((assetId, deliveryMode))
    if let decodedThumbnailOverride {
      return await decodedThumbnailOverride(assetId, quantizedSize, deliveryMode)
    }
    return cachedDecodedThumbnail(
      for: assetId, quantizedSize: quantizedSize, deliveryMode: deliveryMode)
  }

  func cachedDecodedThumbnail(
    for assetId: String, quantizedSize: CGSize, deliveryMode: ThumbnailDeliveryMode
  ) -> CGImage? {
    let source: NSImage?
    switch deliveryMode {
    case .fast:
      source = thumbnailsByAssetId[assetId]
    case .highQuality:
      source = hqThumbnailsByAssetId[assetId] ?? thumbnailsByAssetId[assetId]
    }
    guard let source else { return nil }
    var rect = CGRect(origin: .zero, size: source.size)
    return source.cgImage(forProposedRect: &rect, context: nil, hints: nil)
  }

  func requestFullImage(for assetId: String) async throws -> NSImage {
    if let fullImageRequestOverride { return try await fullImageRequestOverride(assetId) }
    if let error = requestFullImageError { throw error }
    guard let image = fullImagesByAssetId[assetId] else {
      throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "No image"])
    }
    return image
  }

  /// `resources(for:)` calls per asset id.
  private(set) var resourcesCallCounts: [String: Int] = [:]

  func resources(for assetId: String) -> [ResourceDescriptor] {
    resourcesCallCounts[assetId, default: 0] += 1
    return resourcesByAssetId[assetId] ?? []
  }

  func assetDetails(for assetId: String) -> AssetDetails? {
    detailsFetchCalls.append(assetId)
    return detailsByAssetId[assetId]
  }
}
