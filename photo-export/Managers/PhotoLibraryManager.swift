import AppKit
import Photos
import SwiftUI
import os

/// Manages access to the Photos library, including authorization and asset fetching.
///
/// Not `final` only so `ScreenshotPhotoLibraryService` can subclass and replace every
/// `PhotoLibraryService` method with curated synthetic content for marketing screenshots
/// (see `docs/project/plans/screenshot-automation-plan.md`). No other subclass should
/// exist — production launches always instantiate this class directly.
@MainActor
class PhotoLibraryManager: NSObject, ObservableObject, PhotoLibraryService {
  /// Published properties to track authorization status
  @Published var authorizationStatus: PHAuthorizationStatus = .notDetermined
  @Published var isAuthorized: Bool = false

  /// Bumps on every `photoLibraryDidChange`. Sidebar/grid views that depend on the
  /// current PhotoKit state observe this to trigger a re-fetch — without it, a user who
  /// renames an album or favorites/unfavorites a photo while the app is open would see
  /// stale data until manually re-selecting. The counter doesn't carry payload; its sole
  /// purpose is to break SwiftUI view-update equality so the dependent `.task(id:)`
  /// re-runs.
  @Published var libraryRevision: Int = 0

  private let logger = Logger(subsystem: "com.valtteriluoma.photo-export", category: "Photos")

  /// Errors that can occur in the Photo Library Manager
  enum PhotoLibraryError: Error {
    case authorizationDenied
    case fetchFailed
    case assetUnavailable
  }

  /// Shared caching image manager for thumbnails
  private static let cachingImageManager = PHCachingImageManager()

  /// Bounded cache of recently-fetched PHAsset objects keyed by localIdentifier.
  /// Populated by fetchAssets so thumbnail and resource lookups avoid re-fetching.
  /// Replaced wholesale on each fetch rather than doing per-entry eviction.
  private var phAssetCache: [String: PHAsset] = [:]

  /// Cache of adjusted-asset counts keyed by `"YYYY-M"`. Populated lazily by
  /// `countAdjustedAssets` and cleared when the Photos library changes or the user re-authorises.
  private var adjustedCountByYearMonth: [String: Int] = [:]

  /// Phase 3 collection-count cache. Keyed by scope. Invalidated on
  /// `photoLibraryDidChange` so subsequent reads re-fetch.
  nonisolated let collectionCountCache = CollectionCountCache()

  nonisolated static func isAuthorizationSufficient(_ status: PHAuthorizationStatus) -> Bool {
    status == .authorized || status == .limited
  }

  override init() {
    super.init()
    // Skip PhotoKit registration entirely under XCTest / swift-testing.
    // Tests run from DerivedData; TCC sees that path as a different
    // binary than the released app and would surface a fresh permission
    // prompt even when the user has approved the app in System Settings.
    // The prompt blocks the test process and there's no automated way
    // to dismiss it. AutoSync and PhotoLibrary integration tests inject
    // `FakePhotoLibraryService` / `FakePersistentChangeSource` instead,
    // so they don't need the real PhotoKit observer.
    //
    // Screenshot mode (`--screenshot-mode` launch arg) gets the same
    // early-return for a different reason: the subclass serves curated
    // synthetic content and must not register an observer that would
    // overwrite it on the next PhotoKit change notification. Test mode
    // and screenshot mode are sibling guards, not OR'd into one — the
    // post-conditions differ (test mode wants `isAuthorized = false`,
    // screenshot mode wants `true`; the subclass sets it post-`super.init`).
    guard !Self.isRunningInTests, !Self.isRunningInScreenshotMode else { return }
    // Check if Info.plist contains photos usage description
    verifyPhotoLibraryPermissions()
    // Observe library changes to invalidate cache
    PHPhotoLibrary.shared().register(self)

    // Initialize with current authorization status
    authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    isAuthorized = Self.isAuthorizationSufficient(authorizationStatus)
  }

  /// XCTest and Swift Testing both set `XCTestConfigurationFilePath` in
  /// the test-host environment. Production launches never have it set.
  private static var isRunningInTests: Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
  }

  /// True when the app was launched with `--screenshot-mode`. Used by `init` to
  /// skip PhotoKit registration so the `ScreenshotPhotoLibraryService` subclass can
  /// serve curated content without the real library bleeding in. Also read by
  /// `photo_exportApp.swift` to select which class to instantiate.
  static var isRunningInScreenshotMode: Bool {
    ProcessInfo.processInfo.arguments.contains("--screenshot-mode")
  }

  /// Verify that Photos usage description is properly set in Info.plist
  private func verifyPhotoLibraryPermissions() {
    let bundleDict = Bundle.main.infoDictionary
    if bundleDict?["NSPhotoLibraryUsageDescription"] == nil {
      logger.warning("NSPhotoLibraryUsageDescription not found in Info.plist")
      logger.warning(
        "Available keys: \(bundleDict?.keys.joined(separator: ", ") ?? "none", privacy: .public)")
    } else {
      logger.debug("Found NSPhotoLibraryUsageDescription in Info.plist")
    }
  }

  /// Request authorization to access the Photos library
  func requestAuthorization() async -> Bool {
    let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)

    await MainActor.run {
      self.authorizationStatus = status
      self.isAuthorized = Self.isAuthorizationSufficient(status)
      // Authorisation changes may change which assets are visible; drop the adjusted-count
      // cache so the next query reflects the new scope.
      self.adjustedCountByYearMonth.removeAll()
    }

    return Self.isAuthorizationSufficient(status)
  }

  /// Returns the number of assets in the given year/month whose `hasAdjustments` is true.
  ///
  /// `PHAsset.hasAdjustments` cannot be expressed as a Photos fetch predicate, so this falls
  /// back to iterating the month's assets. Results are cached until the next library change
  /// or authorisation change.
  func countAdjustedAssets(year: Int, month: Int) async throws -> Int {
    guard isAuthorized else { throw PhotoLibraryError.authorizationDenied }
    let key = "\(year)-\(month)"
    if let cached = adjustedCountByYearMonth[key] { return cached }
    let assets = try await fetchPHAssets(year: year, month: month, mediaType: nil)
    var count = 0
    for asset in assets where asset.hasAdjustments { count += 1 }
    adjustedCountByYearMonth[key] = count
    return count
  }

  /// Returns the number of assets in the given year whose `hasAdjustments` is true. Sums the
  /// per-month cache, populating each month on demand.
  func countAdjustedAssets(year: Int) async throws -> Int {
    guard isAuthorized else { throw PhotoLibraryError.authorizationDenied }
    var total = 0
    for month in 1...12 {
      total += try await countAdjustedAssets(year: year, month: month)
    }
    return total
  }

  // MARK: - Asset Fetching (PhotoLibraryService)

  func fetchAssets(year: Int, month: Int? = nil, mediaType: PHAssetMediaType? = nil) async throws
    -> [AssetDescriptor]
  {
    try await fetchAssets(in: .timeline(year: year, month: month), mediaType: mediaType)
  }

  /// Generic scope-based asset fetch. The timeline path goes through the existing
  /// `fetchPHAssets(year:month:mediaType:)`; collection scopes (`.favorites`, `.album`)
  /// build a fetch with the appropriate predicate or use the album's
  /// `PHAssetCollection`. Hidden assets stay excluded by default; sort is by
  /// `creationDate` ascending for deterministic output (matches existing timeline
  /// behavior).
  func fetchAssets(in scope: PhotoFetchScope, mediaType: PHAssetMediaType?) async throws
    -> [AssetDescriptor]
  {
    guard isAuthorized else { throw PhotoLibraryError.authorizationDenied }
    switch scope {
    case .timeline(let year, let month):
      let phAssets = try await fetchPHAssets(year: year, month: month, mediaType: mediaType)
      cacheAssets(phAssets)
      return phAssets.map { Self.descriptor(from: $0) }
    case .favorites:
      let phAssets = fetchFavoritesPHAssets(mediaType: mediaType)
      cacheAssets(phAssets)
      return phAssets.map { Self.descriptor(from: $0) }
    case .album(let collectionLocalId), .sharedAlbum(let collectionLocalId):
      // Shared albums enumerate identically to user albums; the only difference is the
      // `PHAssetCollection.assetCollectionSubtype` we surfaced in the tree.
      let phAssets = fetchAlbumPHAssets(collectionLocalId: collectionLocalId, mediaType: mediaType)
      cacheAssets(phAssets)
      return phAssets.map { Self.descriptor(from: $0) }
    }
  }

  // MARK: - Collection scope counts (Phase 2; uncached)

  /// Number of assets in a fetch scope. Phase 2 keeps these uncached. The implementation
  /// runs the `PHFetchResult` on a detached task so the call doesn't block the main
  /// actor. The protocol declares this `nonisolated`; we forward to a
  /// detached-task implementation here.
  nonisolated func countAssets(in scope: PhotoFetchScope) async throws -> Int {
    try await Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
      guard Self.isAuthorizationSufficient(status) else {
        throw PhotoLibraryError.authorizationDenied
      }
      let opts = Self.fetchOptions(for: scope)
      switch scope {
      case .timeline, .favorites:
        try Task.checkCancellation()
        return PHAsset.fetchAssets(with: opts).count
      case .album(let collectionLocalId), .sharedAlbum(let collectionLocalId):
        try Task.checkCancellation()
        guard let collection = Self.fetchAssetCollection(localIdentifier: collectionLocalId)
        else { return 0 }
        return PHAsset.fetchAssets(in: collection, options: opts).count
      }
    }.value
  }

  // MARK: - Cached counts (Phase 3)

  /// Stable string key for a scope. Same scope → same key, so the cache dedups across
  /// callers asking the same question.
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

  nonisolated func cachedCountAssets(in scope: PhotoFetchScope) async throws -> Int {
    let key = Self.cacheKey(for: scope, adjusted: false)
    return try await collectionCountCache.count(for: key) {
      try await self.countAssets(in: scope)
    }
  }

  nonisolated func cachedCountAdjustedAssets(in scope: PhotoFetchScope) async throws -> Int {
    let key = Self.cacheKey(for: scope, adjusted: true)
    return try await collectionCountCache.count(for: key) {
      try await self.countAdjustedAssets(in: scope)
    }
  }

  /// Number of assets in a fetch scope whose `hasAdjustments` is `true`. Iterates the
  /// fetch result inside a detached task; PHAsset values are not crossed back to the
  /// main actor.
  nonisolated func countAdjustedAssets(in scope: PhotoFetchScope) async throws -> Int {
    try await Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
      guard Self.isAuthorizationSufficient(status) else {
        throw PhotoLibraryError.authorizationDenied
      }
      let opts = Self.fetchOptions(for: scope)
      let result: PHFetchResult<PHAsset>
      switch scope {
      case .timeline, .favorites:
        try Task.checkCancellation()
        result = PHAsset.fetchAssets(with: opts)
      case .album(let collectionLocalId), .sharedAlbum(let collectionLocalId):
        try Task.checkCancellation()
        guard let collection = Self.fetchAssetCollection(localIdentifier: collectionLocalId)
        else { return 0 }
        result = PHAsset.fetchAssets(in: collection, options: opts)
      }
      var count = 0
      // Stop iteration when the task is cancelled. PHFetchResult.enumerateObjects' stop
      // pointer is the documented way to abort early.
      result.enumerateObjects { asset, _, stop in
        if Task.isCancelled {
          stop.pointee = true
          return
        }
        if asset.hasAdjustments { count += 1 }
      }
      try Task.checkCancellation()
      return count
    }.value
  }

  func fetchAssetDescriptor(for assetId: String) -> AssetDescriptor? {
    // Always re-fetch from Photos to ensure the asset still exists
    // (it may have been deleted since it was enqueued for export)
    let result = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
    guard let asset = result.firstObject else {
      phAssetCache.removeValue(forKey: assetId)
      return nil
    }
    cacheAssets([asset])
    return Self.descriptor(from: asset)
  }

  /// Fast count of assets in a given year/month without loading them into memory
  func countAssets(year: Int, month: Int) throws -> Int {
    guard isAuthorized else { throw PhotoLibraryError.authorizationDenied }
    let calendar = Calendar.current
    var start = DateComponents()
    start.year = year
    start.month = month
    start.day = 1
    var end = DateComponents()
    end.year = year
    end.month = month + 1
    end.day = 1
    guard let startDate = calendar.date(from: start), let endDate = calendar.date(from: end)
    else {
      throw PhotoLibraryError.fetchFailed
    }
    let opts = PHFetchOptions()
    opts.predicate = NSPredicate(
      format: "creationDate >= %@ AND creationDate < %@", startDate as NSDate,
      endDate as NSDate)
    let result = PHAsset.fetchAssets(with: opts)
    return result.count
  }

  /// Fast count of assets in a given year
  func countAssets(year: Int) throws -> Int {
    guard isAuthorized else { throw PhotoLibraryError.authorizationDenied }
    let calendar = Calendar.current
    var start = DateComponents()
    start.year = year
    start.month = 1
    start.day = 1
    var end = DateComponents()
    end.year = year + 1
    end.month = 1
    end.day = 1
    guard let startDate = calendar.date(from: start), let endDate = calendar.date(from: end)
    else {
      throw PhotoLibraryError.fetchFailed
    }
    let opts = PHFetchOptions()
    opts.predicate = NSPredicate(
      format: "creationDate >= %@ AND creationDate < %@", startDate as NSDate,
      endDate as NSDate)
    let result = PHAsset.fetchAssets(with: opts)
    return result.count
  }

  /// Returns descending list of years that have at least one asset
  func availableYears() throws -> [Int] {
    try availableYearsWithCounts().map(\.year)
  }

  /// Returns descending list of years with at least one asset, together with per-year asset counts.
  func availableYearsWithCounts() throws -> [(year: Int, count: Int)] {
    guard isAuthorized else { throw PhotoLibraryError.authorizationDenied }

    let opts = PHFetchOptions()
    opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
    let result = PHAsset.fetchAssets(with: opts)
    let count = result.count
    guard count > 0 else { return [] }

    guard let firstDate = result.object(at: 0).creationDate,
      let lastDate = result.object(at: count - 1).creationDate
    else {
      return []
    }

    let calendar = Calendar.current
    let startYear = calendar.component(.year, from: firstDate)
    let endYear = calendar.component(.year, from: lastDate)
    guard startYear <= endYear else { return [] }

    var yearCounts: [(year: Int, count: Int)] = []
    for year in stride(from: endYear, through: startYear, by: -1) {
      let c = (try? self.countAssets(year: year)) ?? 0
      if c > 0 {
        yearCounts.append((year, c))
      }
    }
    return yearCounts
  }

  // MARK: - Thumbnail Management (PhotoLibraryService)

  func startCachingThumbnails(for assets: [AssetDescriptor]) {
    // Use cached PHAssets (populated by the preceding fetchAssets call)
    let phAssets = assets.compactMap { phAssetCache[$0.id] }
    guard !phAssets.isEmpty else { return }
    let options = PHImageRequestOptions()
    options.deliveryMode = .opportunistic
    options.isNetworkAccessAllowed = true
    options.resizeMode = .fast
    Self.cachingImageManager.startCachingImages(
      for: phAssets, targetSize: CGSize(width: 200, height: 200),
      contentMode: .aspectFill, options: options)
  }

  func stopCachingThumbnails(for assets: [AssetDescriptor]) {
    let phAssets = assets.compactMap { phAssetCache[$0.id] }
    guard !phAssets.isEmpty else { return }
    let options = PHImageRequestOptions()
    options.deliveryMode = .opportunistic
    options.isNetworkAccessAllowed = true
    options.resizeMode = .fast
    Self.cachingImageManager.stopCachingImages(
      for: phAssets, targetSize: CGSize(width: 200, height: 200),
      contentMode: .aspectFill, options: options)
  }

  /// Load thumbnail for an asset (fast/degraded version only, for initial grid population)
  func loadThumbnail(for assetId: String, allowNetwork: Bool = true) async -> NSImage? {
    guard let asset = cachedOrFetchPHAsset(id: assetId) else { return nil }
    return await withCheckedContinuation { continuation in
      let options = PHImageRequestOptions()
      options.deliveryMode = .fastFormat
      options.isNetworkAccessAllowed = false
      options.resizeMode = .fast

      let resumed = OSAllocatedUnfairLock(initialState: false)

      Self.cachingImageManager.requestImage(
        for: asset,
        targetSize: CGSize(width: 200, height: 200),
        contentMode: .aspectFill,
        options: options
      ) { image, _ in
        guard
          resumed.withLock({
            let was = $0
            $0 = true
            return !was
          })
        else { return }
        continuation.resume(returning: image)
      }
    }
  }

  /// Load a high-quality thumbnail for an asset
  func loadThumbnailHighQuality(for assetId: String, allowNetwork: Bool = true) async -> NSImage? {
    guard let asset = cachedOrFetchPHAsset(id: assetId) else { return nil }
    return await withCheckedContinuation { continuation in
      let options = PHImageRequestOptions()
      options.deliveryMode = .highQualityFormat
      options.isNetworkAccessAllowed = allowNetwork
      options.resizeMode = .exact

      let resumed = OSAllocatedUnfairLock(initialState: false)

      Self.cachingImageManager.requestImage(
        for: asset,
        targetSize: CGSize(width: 200, height: 200),
        contentMode: .aspectFill,
        options: options
      ) { image, _ in
        guard
          resumed.withLock({
            let was = $0
            $0 = true
            return !was
          })
        else { return }
        continuation.resume(returning: image)
      }
    }
  }

  /// Request a full-size image for an asset
  func requestFullImage(for assetId: String) async throws -> NSImage {
    guard let asset = cachedOrFetchPHAsset(id: assetId) else {
      throw PhotoLibraryError.assetUnavailable
    }
    return try await withCheckedThrowingContinuation { continuation in
      let options = PHImageRequestOptions()
      options.deliveryMode = .highQualityFormat
      options.isNetworkAccessAllowed = true
      options.isSynchronous = false

      self.logger.debug(
        "requestFullImage start id: \(assetId, privacy: .public) size: \(asset.pixelWidth)x\(asset.pixelHeight)"
      )

      let resumed = OSAllocatedUnfairLock(initialState: false)

      PHImageManager.default().requestImage(
        for: asset,
        targetSize: PHImageManagerMaximumSize,
        contentMode: .aspectFit,
        options: options
      ) { image, info in
        let isDegraded = (info?[PHImageResultIsDegradedKey] as? NSNumber)?.boolValue ?? false
        let isInCloud = (info?[PHImageResultIsInCloudKey] as? NSNumber)?.boolValue ?? false
        let isCancelled = (info?[PHImageCancelledKey] as? NSNumber)?.boolValue ?? false
        let requestID = (info?[PHImageResultRequestIDKey] as? NSNumber)?.intValue ?? 0
        let error = info?[PHImageErrorKey] as? NSError
        self.logger.debug(
          "requestFullImage callback id: \(assetId, privacy: .public) requestID: \(requestID) degraded: \(isDegraded) inCloud: \(isInCloud) cancelled: \(isCancelled) imageNil: \((image == nil)) error: \(String(describing: error?.localizedDescription), privacy: .public)"
        )

        if isCancelled || error != nil {
          guard
            resumed.withLock({
              let was = $0
              $0 = true
              return !was
            })
          else { return }
          if let error = error as? Error {
            continuation.resume(throwing: error)
          } else {
            continuation.resume(throwing: PhotoLibraryError.assetUnavailable)
          }
          return
        }

        if isDegraded { return }

        guard
          resumed.withLock({
            let was = $0
            $0 = true
            return !was
          })
        else { return }

        guard let image = image else {
          continuation.resume(throwing: PhotoLibraryError.assetUnavailable)
          return
        }

        continuation.resume(returning: image)
      }
    }
  }

  // MARK: - Resource Access (PhotoLibraryService)

  func resources(for assetId: String) -> [ResourceDescriptor] {
    guard let asset = cachedOrFetchPHAsset(id: assetId) else { return [] }
    return PHAssetResource.assetResources(for: asset).map {
      ResourceDescriptor(
        type: $0.type,
        originalFilename: $0.originalFilename,
        fileSize: Self.resourceFileSize($0))
    }
  }

  /// Reads PhotoKit's undocumented `fileSize` KVC property. Same trick used by
  /// `assetDetails(for:)` — see issue #32. Returns nil when the property is
  /// missing, non-numeric, or non-positive (treated as "unknown").
  fileprivate static func resourceFileSize(_ resource: PHAssetResource) -> Int64? {
    guard let size = resource.value(forKey: "fileSize") as? Int64, size > 0
    else { return nil }
    return size
  }

  func assetDetails(for assetId: String) -> AssetDetails? {
    guard let asset = cachedOrFetchPHAsset(id: assetId) else { return nil }
    let phResources = PHAssetResource.assetResources(for: asset)
    let primaryResource =
      phResources.first(where: { $0.type == .photo })
      ?? phResources.first(where: { $0.type == .video })
      ?? phResources.first
    let originalFilename = primaryResource?.originalFilename
    let fileSize = primaryResource.flatMap(Self.resourceFileSize)
    let descriptors = phResources.map {
      ResourceDescriptor(
        type: $0.type,
        originalFilename: $0.originalFilename,
        fileSize: Self.resourceFileSize($0))
    }
    return AssetDetails(
      originalFilename: originalFilename, fileSize: fileSize, resources: descriptors)
  }

  // MARK: - Internal PHAsset Helpers

  /// Inserts assets into the cache.
  private func cacheAssets(_ assets: [PHAsset]) {
    for asset in assets {
      phAssetCache[asset.localIdentifier] = asset
    }
  }

  /// Resolves a single PHAsset by id, preferring the in-memory cache.
  private func cachedOrFetchPHAsset(id: String) -> PHAsset? {
    if let cached = phAssetCache[id] { return cached }
    let result = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
    guard let asset = result.firstObject else { return nil }
    cacheAssets([asset])
    return asset
  }

  /// Clears the entire PHAsset cache (called on library changes).
  private func invalidateCache() {
    phAssetCache.removeAll()
    adjustedCountByYearMonth.removeAll()
    cachedCollectionTree = nil
    libraryRevision &+= 1
    // Cancel any in-flight count tasks and drop cached counts so the next sidebar read
    // re-fetches against the updated library state.
    Task { [collectionCountCache] in
      await collectionCountCache.invalidateAll()
    }
  }

  // MARK: - Collection scope fetch helpers

  /// Builds a `PHFetchOptions` for the given scope. Hidden assets stay excluded by
  /// default; sort is `creationDate` ascending for deterministic output. The Favorites
  /// scope adds a `favorite == YES` predicate; the timeline scope adds a date-range
  /// predicate. Album scope's predicate is empty (the collection itself bounds the
  /// fetch).
  nonisolated fileprivate static func fetchOptions(for scope: PhotoFetchScope) -> PHFetchOptions {
    let opts = PHFetchOptions()
    opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
    switch scope {
    case .timeline(let year, let month):
      let calendar = Calendar.current
      var startComps = DateComponents()
      startComps.year = year
      startComps.month = month ?? 1
      startComps.day = 1
      var endComps = DateComponents()
      endComps.year = month == nil ? year + 1 : year
      endComps.month = month == nil ? 1 : (month! + 1)
      endComps.day = 1
      if let startDate = calendar.date(from: startComps),
        let endDate = calendar.date(from: endComps)
      {
        opts.predicate = NSPredicate(
          format: "creationDate >= %@ AND creationDate < %@", startDate as NSDate,
          endDate as NSDate)
      }
    case .favorites:
      opts.predicate = NSPredicate(format: "favorite == YES")
    case .album, .sharedAlbum:
      // Album / shared-album scopes are bounded by the PHAssetCollection; no
      // additional predicate.
      break
    }
    return opts
  }

  nonisolated fileprivate static func fetchAssetCollection(localIdentifier: String)
    -> PHAssetCollection?
  {
    let result = PHAssetCollection.fetchAssetCollections(
      withLocalIdentifiers: [localIdentifier], options: nil)
    return result.firstObject
  }

  /// Fetches Favorites contents on the main actor (used by `fetchAssets(in:)` to populate
  /// the asset cache). Counts go through the detached `countAssets(in:)` path instead.
  private func fetchFavoritesPHAssets(mediaType: PHAssetMediaType?) -> [PHAsset] {
    let opts = Self.fetchOptions(for: .favorites)
    if let mediaType = mediaType {
      let mediaPredicate = NSPredicate(format: "mediaType == %d", mediaType.rawValue)
      opts.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        opts.predicate ?? NSPredicate(value: true), mediaPredicate,
      ])
    }
    let result = PHAsset.fetchAssets(with: opts)
    var assets: [PHAsset] = []
    result.enumerateObjects { asset, _, _ in assets.append(asset) }
    return assets
  }

  /// Fetches one user album's contents.
  private func fetchAlbumPHAssets(collectionLocalId: String, mediaType: PHAssetMediaType?)
    -> [PHAsset]
  {
    guard let collection = Self.fetchAssetCollection(localIdentifier: collectionLocalId) else {
      return []
    }
    let opts = Self.fetchOptions(for: .album(collectionId: collectionLocalId))
    if let mediaType = mediaType {
      let mediaPredicate = NSPredicate(format: "mediaType == %d", mediaType.rawValue)
      opts.predicate = mediaPredicate
    }
    let result = PHAsset.fetchAssets(in: collection, options: opts)
    var assets: [PHAsset] = []
    result.enumerateObjects { asset, _, _ in assets.append(asset) }
    return assets
  }

  // MARK: - Collection tree (Phase 2)

  /// Cached collection tree. Invalidated on `photoLibraryDidChange`. Constructed lazily
  /// on the first `fetchCollectionTree()` call after a change (or first launch).
  private var cachedCollectionTree: [PhotoCollectionDescriptor]?

  /// Builds the user's Photos collection tree: a synthetic Favorites entry first, then
  /// user-created top-level albums and folders (recursively), then any iCloud shared
  /// albums as flat top-level entries.
  ///
  /// Shared albums require a **separate** fetch: `PHCollection.fetchTopLevelUserCollections`
  /// returns user-created albums and folders only, and excludes iCloud shared albums by
  /// design even though they share the same `.album` collection type. The second call,
  /// `PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumCloudShared,
  /// options: nil)`, surfaces them. Without the second call the "Shared Albums" sidebar
  /// section would stay empty even when the user has shared albums in Photos.
  ///
  /// Both passes route through `descriptor(from:parentPath:)` for consistency, so the
  /// `descriptorKind(for:)` subtype switch is the single source of truth for which
  /// collections we surface and how.
  func fetchCollectionTree() throws -> [PhotoCollectionDescriptor] {
    guard isAuthorized else { throw PhotoLibraryError.authorizationDenied }
    if let cached = cachedCollectionTree { return cached }
    var tree: [PhotoCollectionDescriptor] = []
    tree.append(
      PhotoCollectionDescriptor(
        id: "favorites",
        localIdentifier: nil,
        title: "Favorites",
        kind: .favorites,
        pathComponents: [],
        children: []
      ))

    // Pass 1: user-created albums and folders (top level). Excludes shared albums.
    let topLevel = PHCollection.fetchTopLevelUserCollections(with: nil)
    var userTopResults: [PhotoCollectionDescriptor] = []
    topLevel.enumerateObjects { collection, _, _ in
      if let descriptor = Self.descriptor(from: collection, parentPath: []) {
        userTopResults.append(descriptor)
      }
    }
    tree.append(contentsOf: userTopResults)

    // Pass 2: iCloud shared albums. Returned by a dedicated fetch — they are
    // intentionally absent from `fetchTopLevelUserCollections`. Shared albums never
    // nest, so they always land at the top level with `parentPath = []`.
    //
    // Logged with raw counts and per-collection (subtype, title) tuples so a user
    // reporting "I have shared albums in Photos but the sidebar section is empty"
    // can run Console.app and see whether PhotoKit returned anything at all, and
    // if so, why a given collection was dropped by `descriptor(from:)`.
    let sharedFetch = PHAssetCollection.fetchAssetCollections(
      with: .album, subtype: .albumCloudShared, options: nil)
    logger.info(
      "fetchCollectionTree: shared-album fetch returned \(sharedFetch.count) result(s)"
    )
    var sharedAlbumResults: [PhotoCollectionDescriptor] = []
    sharedFetch.enumerateObjects { collection, _, _ in
      let title = collection.localizedTitle ?? "<nil>"
      let subtypeRaw = collection.assetCollectionSubtype.rawValue
      let descriptor = Self.descriptor(from: collection, parentPath: [])
      if let descriptor {
        self.logger.info(
          "fetchCollectionTree: shared-album surfaced title=\(title, privacy: .public) subtype=\(subtypeRaw) kind=\(descriptor.kind.rawValue, privacy: .public)"
        )
        sharedAlbumResults.append(descriptor)
      } else {
        self.logger.info(
          "fetchCollectionTree: shared-album dropped title=\(title, privacy: .public) subtype=\(subtypeRaw) — descriptor builder returned nil"
        )
      }
    }
    tree.append(contentsOf: sharedAlbumResults)

    // Diagnostic: if the targeted shared-album fetch came back empty, do a broad
    // sweep with `.any` subtype and log everything PhotoKit knows about. This
    // disambiguates "shared albums exist but PhotoKit classified them under a
    // subtype I didn't anticipate" (a code bug we need to fix) from "PhotoKit
    // genuinely has no shared albums" (typically because **Photos.app → Settings
    // → iCloud → Shared Albums** is disabled, which prevents Photos from
    // syncing them down to the local library at all). The log line tells the
    // user which checkbox to look at.
    if sharedFetch.count == 0 {
      let anyAlbums = PHAssetCollection.fetchAssetCollections(
        with: .album, subtype: .any, options: nil)
      var subtypeHistogram: [Int: Int] = [:]
      anyAlbums.enumerateObjects { collection, _, _ in
        subtypeHistogram[collection.assetCollectionSubtype.rawValue, default: 0] += 1
      }
      let histogramString = subtypeHistogram
        .sorted { $0.key < $1.key }
        .map { "subtype=\($0.key):\($0.value)" }
        .joined(separator: " ")
      logger.info(
        "fetchCollectionTree: no shared albums returned. Broad .album scan found \(anyAlbums.count) collection(s): \(histogramString, privacy: .public). If you have shared albums in Photos.app, check Photos → Settings → iCloud → \"Shared Albums\" is enabled. PHAssetCollectionSubtype.albumCloudShared raw value is 102."
      )
    }

    cachedCollectionTree = tree
    return tree
  }

  /// Routes a `PHAssetCollectionSubtype` to the matching descriptor kind, or `nil` if
  /// the subtype isn't surfaced. The `assetCollectionType == .album` check at the call
  /// site is **not** sufficient on its own — that type includes `.albumCloudShared`
  /// (shared albums), `.albumImported` (legacy iTunes imports), and
  /// `.albumMyPhotoStream` (deprecated). This switch is the single place that decides
  /// which subtypes count, and how.
  ///
  /// Smart albums (including the Favorites smart album) have a different
  /// `assetCollectionType == .smartAlbum`, so they are excluded at the type check
  /// upstream and never reach this routing — Favorites is surfaced as a synthetic
  /// descriptor in `fetchCollectionTree()` instead.
  ///
  /// Shared albums (`.albumCloudShared`) now route to `.sharedAlbum`. Issue #48
  /// surfaced them as their own section in the sidebar. Earlier versions of this
  /// codebase explicitly dropped shared albums; the comment above the call site
  /// recorded that choice. The README's "Known limitations" was updated alongside.
  nonisolated fileprivate static func descriptorKind(
    for subtype: PHAssetCollectionSubtype
  ) -> PhotoCollectionDescriptor.Kind? {
    switch subtype {
    case .albumRegular, .albumSyncedAlbum:
      return .album
    case .albumCloudShared:
      return .sharedAlbum
    default:
      return nil
    }
  }

  /// Builds a descriptor for a `PHCollection`. Albums become leaf descriptors; folders
  /// recurse into their children. Returns `nil` for kinds we don't surface (smart albums
  /// other than Favorites, legacy iTunes-synced albums, etc).
  ///
  /// Shared albums land at `parentPath = []` because PhotoKit returns them in the same
  /// `fetchTopLevelUserCollections` enumeration as regular albums but the issue calls for
  /// them to live in a flat top-level group. The tree-builder partitions them after
  /// construction.
  fileprivate static func descriptor(from collection: PHCollection, parentPath: [String])
    -> PhotoCollectionDescriptor?
  {
    let title = collection.localizedTitle ?? ""
    if let assetCollection = collection as? PHAssetCollection,
      assetCollection.assetCollectionType == .album,
      let kind = Self.descriptorKind(for: assetCollection.assetCollectionSubtype)
    {
      let idPrefix: String = (kind == .sharedAlbum) ? "shared-album" : "album"
      return PhotoCollectionDescriptor(
        id: "\(idPrefix):\(assetCollection.localIdentifier)",
        localIdentifier: assetCollection.localIdentifier,
        title: title,
        kind: kind,
        pathComponents: parentPath,
        children: []
      )
    }
    if let folder = collection as? PHCollectionList {
      let childPath = parentPath + [title]
      let children = PHCollection.fetchCollections(in: folder, options: nil)
      var childDescriptors: [PhotoCollectionDescriptor] = []
      children.enumerateObjects { child, _, _ in
        if let descriptor = Self.descriptor(from: child, parentPath: childPath) {
          childDescriptors.append(descriptor)
        }
      }
      return PhotoCollectionDescriptor(
        id: "folder:\(folder.localIdentifier)",
        localIdentifier: folder.localIdentifier,
        title: title,
        kind: .folder,
        pathComponents: parentPath,
        children: childDescriptors
      )
    }
    return nil
  }

  private func fetchPHAssets(identifiers: [String]) -> [PHAsset] {
    let result = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
    var assets: [PHAsset] = []
    result.enumerateObjects { asset, _, _ in
      assets.append(asset)
    }
    return assets
  }

  /// Fetch raw PHAssets for a specific year and month
  private func fetchPHAssets(year: Int, month: Int? = nil, mediaType: PHAssetMediaType? = nil)
    async throws -> [PHAsset]
  {
    guard isAuthorized else {
      throw PhotoLibraryError.authorizationDenied
    }

    // Create date predicates for filtering
    let calendar = Calendar.current
    var startDateComponents = DateComponents()
    startDateComponents.year = year
    startDateComponents.month = month ?? 1
    startDateComponents.day = 1

    var endDateComponents = DateComponents()
    endDateComponents.year = month == nil ? year + 1 : year
    endDateComponents.month = month == nil ? 1 : (month! + 1)
    endDateComponents.day = 1

    guard let startDate = calendar.date(from: startDateComponents),
      let endDate = calendar.date(from: endDateComponents)
    else {
      throw PhotoLibraryError.fetchFailed
    }

    // Create fetch options
    let fetchOptions = PHFetchOptions()

    // Create date predicate
    fetchOptions.predicate = NSPredicate(
      format: "creationDate >= %@ AND creationDate < %@", startDate as NSDate,
      endDate as NSDate)

    // Add media type filter if specified
    if let mediaType = mediaType {
      let mediaTypePredicate = NSPredicate(format: "mediaType == %d", mediaType.rawValue)

      if let existingPredicate = fetchOptions.predicate {
        fetchOptions.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
          existingPredicate, mediaTypePredicate,
        ])
      } else {
        fetchOptions.predicate = mediaTypePredicate
      }
    }

    fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

    // Fetch assets
    let fetchResult = PHAsset.fetchAssets(with: fetchOptions)
    var assets: [PHAsset] = []

    // Process in batches to avoid loading everything into memory at once
    let totalAssets = fetchResult.count
    let batchSize = 500

    for index in 0..<totalAssets {
      autoreleasepool {
        assets.append(fetchResult.object(at: index))
      }

      // Yield to main thread periodically
      if index % batchSize == 0 && index > 0 {
        try? await Task.sleep(nanoseconds: 1_000_000)  // 1ms
      }
    }

    return assets
  }

  static func descriptor(from asset: PHAsset) -> AssetDescriptor {
    AssetDescriptor(
      id: asset.localIdentifier,
      creationDate: asset.creationDate,
      mediaType: asset.mediaType,
      pixelWidth: asset.pixelWidth,
      pixelHeight: asset.pixelHeight,
      duration: asset.duration,
      hasAdjustments: asset.hasAdjustments
    )
  }
}

// MARK: - PHPhotoLibraryChangeObserver

extension PhotoLibraryManager: @preconcurrency PHPhotoLibraryChangeObserver {
  nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
    Task { @MainActor in
      self.invalidateCache()
    }
  }
}
