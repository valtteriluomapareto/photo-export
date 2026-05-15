import AppKit
import Foundation
import Photos

@testable import Photo_Export

@MainActor
final class FakePhotoLibraryService: PhotoLibraryService {
  var isAuthorized: Bool = true
  var authorizationStatus: PHAuthorizationStatus = .authorized

  // Canned data
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

  // Call tracking
  var fetchAssetsCalls: [(year: Int, month: Int?, mediaType: PHAssetMediaType?)] = []
  var writeResourceCalls: [(ResourceDescriptor, String, URL)] = []
  var startCachingCalls: [[AssetDescriptor]] = []
  var stopCachingCalls: [[AssetDescriptor]] = []

  // Error injection
  var fetchAssetsError: Error?
  /// Per-album error injection. When `fetchAssets(in: .album(id))` is called and
  /// `id` is in this map, the fake throws the mapped error instead of returning the
  /// canned assets. Used to exercise partial-enqueue failure paths.
  var fetchAssetsErrorByAlbumId: [String: Error] = [:]
  /// Per-album async delay. When `fetchAssets(in: .album(id))` is called and `id` is
  /// in this map, the fake `Task.sleep`s for the given seconds before returning. Used
  /// to widen the "queued but run loop not started" window for tests that exercise the
  /// pre-process pause path.
  ///
  /// Prefer `fetchAssetsCheckpointByAlbumId` over this for any test that asserts
  /// on transient queue state — a delay only widens a window, but a checkpoint
  /// makes arrival deterministic. See issue #30.
  var fetchAssetsDelayByAlbumId: [String: TimeInterval] = [:]
  /// Per-album release-on-demand checkpoint. When `fetchAssets(in: .album(id))` is
  /// called and `id` is in this map, the fake calls `await checkpoint.enter()`
  /// before any per-album error/delay handling, so the gate signals "the enqueue
  /// loop reached this album fetch." Tests can `waitForEnter(count:)` to assert
  /// the loop is suspended on this album, take some action (pause, start another
  /// export), then `release(_:)` or `releaseAll()`.
  ///
  /// Harness teardown must call `await checkpoint.releaseAll()` so a suspended
  /// fetch task can't outlive the test.
  var fetchAssetsCheckpointByAlbumId: [String: AsyncCheckpoint] = [:]
  var requestFullImageError: Error?

  func requestAuthorization() async -> Bool { isAuthorized }

  func fetchAssets(year: Int, month: Int?, mediaType: PHAssetMediaType?) async throws
    -> [AssetDescriptor]
  {
    fetchAssetsCalls.append((year, month, mediaType))
    if let error = fetchAssetsError { throw error }

    if let month {
      let key = "\(year)-\(month)"
      let assets = assetsByYearMonth[key] ?? []
      if let mediaType {
        return assets.filter { $0.mediaType == mediaType }
      }
      return assets
    } else {
      // Fetch all months for the year
      var allAssets: [AssetDescriptor] = []
      for m in 1...12 {
        let key = "\(year)-\(m)"
        allAssets.append(contentsOf: assetsByYearMonth[key] ?? [])
      }
      if let mediaType {
        return allAssets.filter { $0.mediaType == mediaType }
      }
      return allAssets
    }
  }

  func fetchAssetDescriptor(for assetId: String) -> AssetDescriptor? {
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
    let key = "\(year)-\(month)"
    return assetsByYearMonth[key]?.count ?? 0
  }

  func countAssets(year: Int) throws -> Int {
    var total = 0
    for m in 1...12 {
      total += (assetsByYearMonth["\(year)-\(m)"]?.count ?? 0)
    }
    return total
  }

  func countAdjustedAssets(year: Int, month: Int) async throws -> Int {
    let key = "\(year)-\(month)"
    return (assetsByYearMonth[key] ?? []).reduce(0) { $0 + ($1.hasAdjustments ? 1 : 0) }
  }

  func countAdjustedAssets(year: Int) async throws -> Int {
    var total = 0
    for m in 1...12 {
      total += try await countAdjustedAssets(year: year, month: m)
    }
    return total
  }

  func availableYears() throws -> [Int] {
    yearCounts.map(\.year)
  }

  func availableYearsWithCounts() throws -> [(year: Int, count: Int)] {
    yearCounts
  }

  // MARK: - Phase 2: Collections

  func fetchCollectionTree() throws -> [PhotoCollectionDescriptor] {
    collectionTree
  }

  func fetchAssets(in scope: PhotoFetchScope, mediaType: PHAssetMediaType?) async throws
    -> [AssetDescriptor]
  {
    if let error = fetchAssetsError { throw error }
    switch scope {
    case .timeline(let year, let month):
      return try await fetchAssets(year: year, month: month, mediaType: mediaType)
    case .favorites:
      if let mediaType {
        return favoritesAssets.filter { $0.mediaType == mediaType }
      }
      return favoritesAssets
    case .album(let collectionId):
      // The checkpoint runs *before* the error/delay branches so the gate's
      // "entered" semantic is "the enqueue loop reached this album fetch,"
      // independent of whether the album is wired to throw or sleep next.
      if let checkpoint = fetchAssetsCheckpointByAlbumId[collectionId] {
        await checkpoint.enter()
      }
      if let perAlbumError = fetchAssetsErrorByAlbumId[collectionId] {
        throw perAlbumError
      }
      if let delay = fetchAssetsDelayByAlbumId[collectionId] {
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      }
      let assets = assetsByAlbumLocalId[collectionId] ?? []
      if let mediaType {
        return assets.filter { $0.mediaType == mediaType }
      }
      return assets
    case .sharedAlbum(let collectionId):
      // Shared albums share the `fetchAssetsErrorByAlbumId` / -checkpoint /
      // -delay knobs with `.album` — the dict is keyed by collection id, and
      // PhotoKit-side identifiers don't overlap between the two kinds so a
      // single map is unambiguous in practice. Same ordering as the `.album`
      // branch (checkpoint, error, delay) so tests can exercise the bulk
      // shared-album partial-failure path the same way they do for user
      // albums.
      if let checkpoint = fetchAssetsCheckpointByAlbumId[collectionId] {
        await checkpoint.enter()
      }
      if let perAlbumError = fetchAssetsErrorByAlbumId[collectionId] {
        throw perAlbumError
      }
      if let delay = fetchAssetsDelayByAlbumId[collectionId] {
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      }
      let assets = assetsBySharedAlbumLocalId[collectionId] ?? []
      if let mediaType {
        return assets.filter { $0.mediaType == mediaType }
      }
      return assets
    }
  }

  nonisolated func countAssets(in scope: PhotoFetchScope) async throws -> Int {
    // The fake's storage is `@MainActor`-isolated; hop on to read it.
    return await MainActor.run { [weak self] in
      guard let self else { return 0 }
      switch scope {
      case .timeline(let year, let month):
        if let month {
          return self.assetsByYearMonth["\(year)-\(month)"]?.count ?? 0
        }
        var total = 0
        for m in 1...12 {
          total += self.assetsByYearMonth["\(year)-\(m)"]?.count ?? 0
        }
        return total
      case .favorites:
        return self.favoritesAssets.count
      case .album(let collectionId):
        return self.assetsByAlbumLocalId[collectionId]?.count ?? 0
      case .sharedAlbum(let collectionId):
        return self.assetsBySharedAlbumLocalId[collectionId]?.count ?? 0
      }
    }
  }

  /// Phase 3 cache. Tests can read `collectionCountCache` to assert hit/miss behavior.
  nonisolated let collectionCountCache = CollectionCountCache()

  nonisolated func cachedCountAssets(in scope: PhotoFetchScope) async throws -> Int {
    try await collectionCountCache.count(
      for: Self.cacheKey(for: scope, adjusted: false)
    ) {
      try await self.countAssets(in: scope)
    }
  }

  nonisolated func cachedCountAdjustedAssets(in scope: PhotoFetchScope) async throws -> Int {
    try await collectionCountCache.count(
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
    return await MainActor.run { [weak self] in
      guard let self else { return 0 }
      let assets: [AssetDescriptor]
      switch scope {
      case .timeline(let year, let month):
        if let month {
          assets = self.assetsByYearMonth["\(year)-\(month)"] ?? []
        } else {
          var collected: [AssetDescriptor] = []
          for m in 1...12 {
            collected.append(contentsOf: self.assetsByYearMonth["\(year)-\(m)"] ?? [])
          }
          assets = collected
        }
      case .favorites:
        assets = self.favoritesAssets
      case .album(let collectionId):
        assets = self.assetsByAlbumLocalId[collectionId] ?? []
      case .sharedAlbum(let collectionId):
        assets = self.assetsBySharedAlbumLocalId[collectionId] ?? []
      }
      return assets.reduce(0) { $0 + ($1.hasAdjustments ? 1 : 0) }
    }
  }

  func startCachingThumbnails(for assets: [AssetDescriptor]) {
    startCachingCalls.append(assets)
  }

  func stopCachingThumbnails(for assets: [AssetDescriptor]) {
    stopCachingCalls.append(assets)
  }

  func loadThumbnail(for assetId: String, allowNetwork: Bool) async -> NSImage? {
    thumbnailsByAssetId[assetId]
  }

  func loadThumbnailHighQuality(for assetId: String, allowNetwork: Bool) async -> NSImage? {
    hqThumbnailsByAssetId[assetId]
  }

  func requestFullImage(for assetId: String) async throws -> NSImage {
    if let error = requestFullImageError { throw error }
    guard let image = fullImagesByAssetId[assetId] else {
      throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "No image"])
    }
    return image
  }

  func resources(for assetId: String) -> [ResourceDescriptor] {
    resourcesByAssetId[assetId] ?? []
  }

  func assetDetails(for assetId: String) -> AssetDetails? {
    detailsByAssetId[assetId]
  }
}
