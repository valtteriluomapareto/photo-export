import AppKit
import Combine
import Observation
import Photos
import SwiftUI
import os

/// Manages access to the Photos library, including authorization and asset fetching.
///
/// Screenshot and test libraries implement `PhotoLibraryService` independently. This
/// class forwards service methods to an injected `overrideService` when present.
/// Independent conformances require every protocol method to be implemented, so a new
/// requirement cannot silently inherit production PhotoKit behavior in screenshot mode.
@Observable
@MainActor
final class PhotoLibraryManager: NSObject, PhotoLibraryService, PHAssetCacheControlling {
  /// Authorization changes retain synchronous Combine delivery and register Observation reads.
  var authorizationStatus: PHAuthorizationStatus {
    get {
      access(keyPath: \.authorizationStatus)
      return authorizationStatusBridge.value
    }
    set {
      authorizationStatusBridge.write(newValue) { withMutation(keyPath: \.authorizationStatus, $0) }
    }
  }
  private let authorizationStatusBridge = ObservableCombineBridge(
    PHAuthorizationStatus.notDetermined)

  var isAuthorized: Bool {
    get {
      access(keyPath: \.isAuthorized)
      return isAuthorizedBridge.value
    }
    set {
      isAuthorizedBridge.write(newValue) { withMutation(keyPath: \.isAuthorized, $0) }
    }
  }
  private let isAuthorizedBridge = ObservableCombineBridge(false)

  /// Synchronous, delivered before storage, and replaying the current value.
  /// Subscribe and request demand on the main actor; off-main adapters such as `.values`
  /// or `flatMap` can otherwise trap in the actor-isolated bridge.
  var authorizationStatusPublisher: AnyPublisher<PHAuthorizationStatus, Never> {
    authorizationStatusBridge.publisher
  }
  /// Synchronous, delivered before storage, and replaying the current value.
  /// Subscribe and request demand on the main actor; off-main adapters such as `.values`
  /// or `flatMap` can otherwise trap in the actor-isolated bridge.
  var isAuthorizedPublisher: AnyPublisher<Bool, Never> { isAuthorizedBridge.publisher }

  /// Bumps on every `photoLibraryDidChange`. Sidebar/grid views that depend on the
  /// current PhotoKit state observe this to trigger a re-fetch — without it, a user who
  /// renames an album or favorites/unfavorites a photo while the app is open would see
  /// stale data until manually re-selecting. The counter doesn't carry payload; its sole
  /// purpose is to signal that dependent views should refresh. Sidebar count tasks
  /// restart with the revision; asset grids use `.onChange` to refresh in place.
  var libraryRevision: Int = 0 {
    didSet { libraryRefresh.invalidate(changes: invalidatingQueryChanges) }
  }
  @ObservationIgnored private var invalidatingQueryChanges: [PhotoLibraryQuery: Bool]?
  @ObservationIgnored private var refreshClock: any AutoSyncClock = SystemAutoSyncClock()
  @ObservationIgnored private(set) lazy var libraryRefresh = LibraryRefreshState(
    service: self, clock: refreshClock)
  @ObservationIgnored private let queryObservations = PhotoLibraryQueryObservations<
    PHFetchResult<PHAsset>
  >()

  func beginObservingQuery(_ query: PhotoLibraryQuery) {
    queryObservations.begin(query)
    libraryRefresh.begin(query)
  }

  func endObservingQuery(_ query: PhotoLibraryQuery) {
    queryObservations.end(query)
    if !queryObservations.isObserved(query) { libraryRefresh.end(query) }
  }

  /// When the user turns on "Export Live Photos as paired image + video",
  /// `descriptor(from:)` enables a `PHAssetResource`-enumeration fallback to catch
  /// Live Photos whose `.photoLive` subtype flag is missing (a known iCloud-sync
  /// anomaly). Off by default so the per-asset cost is paid only by users who opted
  /// into the feature. Driven by `bindLivePhotoDetectionFallback(to:)` from the app-
  /// level wiring.
  @ObservationIgnored
  var livePhotoDetectionFallbackEnabled: Bool = false

  /// Bag for the publisher subscription wired by `bindLivePhotoDetectionFallback`. Kept
  /// alive for the manager's lifetime; AppCore owns the manager for the app's lifetime.
  @ObservationIgnored
  private var livePhotoDetectionCancellables = Set<AnyCancellable>()

  private let logger = Logger.app(.photos)

  /// Errors that can occur in the Photo Library Manager
  enum PhotoLibraryError: Error {
    case authorizationDenied
    case fetchFailed
    case assetUnavailable
  }

  /// Shared caching image manager for thumbnails. `nonisolated` because `onCancel` handlers
  /// cancel requests from whichever thread cancels; `PHCachingImageManager` is Sendable.
  private nonisolated static let cachingImageManager = PHCachingImageManager()
  private static var thumbnailPreheatRegistrations = ThumbnailPreheatRegistrations<PHAsset>()

  /// Long-lived cache of PHAsset objects keyed by `localIdentifier`. Populated
  /// additively by `cacheAssets(_:)` from `fetchAssets(in:)`. Cleared by
  /// `invalidateCache()` (library change) or `forgetPHAssetCache()`
  /// (per-iteration drops in `ExportManager.runBulkEnqueueLoop`).
  @ObservationIgnored
  private var phAssetCache: [String: PHAsset] = [:]

  /// Cache of adjusted-asset counts keyed by `"YYYY-M"`. Populated lazily by
  /// `countAdjustedAssets` and cleared when the Photos library changes or the user re-authorises.
  @ObservationIgnored
  private var adjustedCountByYearMonth: [String: Int] = [:]

  /// Scope-keyed collection-count cache. Invalidated on
  /// `photoLibraryDidChange` so subsequent reads re-fetch.
  nonisolated let collectionCountCache = CollectionCountCache()
  @ObservationIgnored
  private var countInvalidation: Task<Void, Never>?
  @ObservationIgnored
  private var countInvalidationGeneration = 0
  @ObservationIgnored
  private var countInvalidationOverride: (@Sendable () async -> Void)?
  @ObservationIgnored
  private var countInvalidationWaitObserver: (@MainActor () -> Void)?

  /// Bounded `CGImage` cache for thumbnail renders, keyed by content revision.
  /// Known edits supersede only their asset's entries; unknown changes clear
  /// the cache. Set up after init so the decode closure captures `[weak self]`.
  @ObservationIgnored
  private(set) var decodedThumbnailCache: DecodedThumbnailCache!

  /// Only thumbnail-requested PHAssets are inspected on a PhotoKit change.
  /// Bulk library fetches can cache tens of thousands of objects, so scanning
  /// `phAssetCache` on every callback would stall the main actor. If this bound
  /// is exceeded or an asset lookup fails, the next change uses the
  /// conservative global invalidation.
  private static let thumbnailTrackingLimit = 512
  @ObservationIgnored
  private var observedThumbnailAssets: [String: PHAsset] = [:]
  @ObservationIgnored
  private var thumbnailTrackingIncomplete = false

  /// Stable task/cache identity for edited content. The global value covers
  /// changes whose affected IDs are unknown; per-asset values avoid restarting
  /// unrelated visible thumbnails when PhotoKit identifies changed content.
  /// Tracks content edits independently of metadata-only library invalidations.
  private var nextThumbnailContentRevision = 0
  @ObservationIgnored
  private var globalThumbnailContentRevision = 0
  @ObservationIgnored
  private var assetThumbnailContentRevisions: [String: Int] = [:]

  /// Optional injection point that replaces the production PhotoKit implementation on
  /// every `PhotoLibraryService` method. Set at init time and never mutated. The
  /// screenshot run injects `ScreenshotPhotoLibraryService` here so its curated content
  /// reaches the UI through composition. `nil` for the production app launch.
  ///
  /// The Sendable reference also serves nonisolated count and inventory reads.
  nonisolated private let overrideService: (any PhotoLibraryService)?

  nonisolated static func isAuthorizationSufficient(_ status: PHAuthorizationStatus) -> Bool {
    status == .authorized || status == .limited
  }

  /// Reads the system's current Photos authorization. Used only when `overrideService` is
  /// nil; tests inject a stub so the production PhotoKit paths can be checked without
  /// touching the library.
  nonisolated private let liveAuthorizationStatus: @Sendable () -> PHAuthorizationStatus

  nonisolated private static let systemAuthorizationStatus: @Sendable () -> PHAuthorizationStatus =
    {
      PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

  /// Photos access as the system reports it now, not the cached `isAuthorized`. Without
  /// access PhotoKit returns empty results rather than an error, so the scan entry points
  /// check this: a revoke the app hasn't refreshed yet then fails the scan as unauthorized
  /// instead of reading as an empty library.
  nonisolated private func isLiveAuthorizationSufficient() -> Bool {
    Self.isAuthorizationSufficient(liveAuthorizationStatus())
  }

  /// A live check found access gone. If the cached flag still says authorized, refresh it
  /// so the main window switches to the access screen and Auto Export blocks at once.
  private func noteLiveDenial() {
    guard isAuthorized else { return }
    refreshAuthorizationStatus()
  }

  /// `noteLiveDenial()` from the detached scan paths, awaited before they throw.
  nonisolated private func noteLiveDenialOnMain() async {
    await MainActor.run { self.noteLiveDenial() }
  }

  /// The live check at a main-actor scan entry point. These can run inside a view body
  /// (`fetchCollectionTree` on a cache miss), so the refresh waits for the next main-actor
  /// turn instead of publishing during the view update.
  private func requireLiveAuthorization() throws {
    guard isLiveAuthorizationSufficient() else {
      Task { @MainActor [weak self] in self?.noteLiveDenial() }
      throw PhotoLibraryError.authorizationDenied
    }
  }

  /// The live check at a detached scan entry point.
  nonisolated private func requireLiveAuthorizationAsync() async throws {
    guard isLiveAuthorizationSufficient() else {
      await noteLiveDenialOnMain()
      throw PhotoLibraryError.authorizationDenied
    }
  }

  /// Production initializer: no override. Does NOT touch PhotoKit — the
  /// `PHPhotoLibrary.shared().register(self)` + authorization probe move into
  /// `start()`, called from the WindowGroup's `.task` after SwiftUI has rendered.
  ///
  /// Synchronous PhotoKit first-touch during `App.init`, before any window
  /// appears, can hang on PhotoKit's
  /// internal account/TCC paths. Deferring those calls into the `.task` block
  /// keeps the UI responsive while the library handshake happens.
  ///
  /// Test and screenshot launches route through `init(overrideService:)`
  /// (the screenshot service is passed in; tests inject `FakePhotoLibraryService`
  /// into `ExportManager` directly and don't construct a manager).
  override init() {
    self.overrideService = nil
    self.liveAuthorizationStatus = Self.systemAuthorizationStatus
    super.init()
    setupDecodedThumbnailCache()
  }

  convenience init(refreshClock: any AutoSyncClock, photoKitReader: (any PhotoKitReading)? = nil) {
    self.init()
    self.refreshClock = refreshClock
    if let photoKitReader { thumbnailReaderFactory = photoKitReader }
  }

  #if DEBUG
    /// The production PhotoKit paths with a stubbed status reader, for tests of the live
    /// authorization guards. A method whose guard the stub passes reads the real library,
    /// so tests call only methods whose guard the stub fails.
    init(liveAuthorizationStatus: @escaping @Sendable () -> PHAuthorizationStatus) {
      self.overrideService = nil
      self.liveAuthorizationStatus = liveAuthorizationStatus
      super.init()
      setupDecodedThumbnailCache()
    }
  #endif

  /// Composition entry point: `overrideService` (when non-nil) replaces every
  /// `PhotoLibraryService` method on this manager. PhotoKit registration is skipped
  /// when an override is set — the curated service produces its own content and any
  /// observer firing would overwrite it.
  init(
    overrideService: any PhotoLibraryService,
    countInvalidationOverride: (@Sendable () async -> Void)? = nil,
    countInvalidationWaitObserver: (@MainActor () -> Void)? = nil,
    refreshClock: (any AutoSyncClock)? = nil,
    photoKitReader: (any PhotoKitReading)? = nil
  ) {
    self.overrideService = overrideService
    self.liveAuthorizationStatus = Self.systemAuthorizationStatus
    self.countInvalidationOverride = countInvalidationOverride
    self.countInvalidationWaitObserver = countInvalidationWaitObserver
    self.thumbnailReaderFactory =
      photoKitReader ?? PhotoLibraryServiceReader(service: overrideService)
    self.refreshClock = refreshClock ?? SystemAutoSyncClock()
    super.init()
    // Sync the UI-facing auth state from the injected service so the onboarding
    // gate (`ContentView`) sees the right gating value. Explicit authorization
    // refreshes also read this service, without registering a real PhotoKit observer.
    authorizationStatus = overrideService.authorizationStatus
    isAuthorized = overrideService.isAuthorized
    setupDecodedThumbnailCache()
  }

  @ObservationIgnored private var thumbnailReaderFactory: any PhotoKitReading =
    ProductionPhotoKitReader()
  private struct ResolvedThumbnail {
    let handle: ThumbnailAsset
    let revision: Int
  }
  @ObservationIgnored private var defaultThumbnailAssets: [String: ResolvedThumbnail] = [:]
  #if DEBUG
    @ObservationIgnored var thumbnailRegistrationObserver: (@MainActor (ThumbnailAsset) -> Void)?
  #endif

  private func thumbnailReader() async -> any ThumbnailReading {
    if let reader = await thumbnailReaderFactory.thumbnailReader { return reader }
    if let service = overrideService { return ServiceThumbnailReader(service: service) }
    return UnavailableThumbnailReader()
  }

  private func setupDecodedThumbnailCache() {
    decodedThumbnailCache = DecodedThumbnailCache { [weak self] key in
      guard let self else { return nil }
      return await self.decodeThumbnail(for: key)
    }
  }

  private func decodeThumbnail(for key: DecodedThumbnailCache.Key) async -> CGImage? {
    let handle: ThumbnailAsset
    if let cached = defaultThumbnailAssets[key.assetId], cached.revision == key.contentRevision {
      handle = cached.handle
    } else {
      let resolved = await resolveThumbnailAssets(ids: [key.assetId])
      guard let first = resolved.first, !Task.isCancelled,
        key.contentRevision == thumbnailContentRevision(for: key.assetId)
      else { return nil }
      handle = first
      if defaultThumbnailAssets.count >= 64, let oldest = defaultThumbnailAssets.keys.first {
        defaultThumbnailAssets.removeValue(forKey: oldest)
      }
      defaultThumbnailAssets[key.assetId] = ResolvedThumbnail(
        handle: first, revision: key.contentRevision)
    }
    let reader = await thumbnailReader()
    guard key.contentRevision == thumbnailContentRevision(for: key.assetId), !Task.isCancelled
    else { return nil }
    registerDisplayedThumbnail(handle)
    return await reader.image(
      for: handle, spec: .init(size: key.quantizedSize, delivery: key.deliveryMode))
  }

  func resolveThumbnailAssets(ids: [String]) async -> [ThumbnailAsset] {
    let revisions = Dictionary(
      ids.map { ($0, thumbnailContentRevision(for: $0)) }, uniquingKeysWith: { first, _ in first })
    let reader = await thumbnailReader()
    let resolved = await reader.resolveAssets(ids: ids)
    guard !Task.isCancelled else { return [] }
    let handles = resolved.compactMap { handle -> ThumbnailAsset? in
      let id = handle.descriptor.id
      guard let revision = revisions[id], revision == thumbnailContentRevision(for: id) else {
        return nil
      }
      return handle.withRevision(revision)
    }
    let resolvedIDs = Set(resolved.map { $0.descriptor.id })
    if overrideService == nil,
      ids.contains(where: {
        revisions[$0] == thumbnailContentRevision(for: $0) && !resolvedIDs.contains($0)
      })
    {
      thumbnailTrackingIncomplete = true
    }
    return handles
  }

  /// Preheat-only assets must not crowd out the bounded registry of displayed content.
  private func registerDisplayedThumbnail(_ handle: ThumbnailAsset) {
    if let asset = handle.photoKitAsset { observeThumbnailAsset(asset) }
    #if DEBUG
      thumbnailRegistrationObserver?(handle)
    #endif
  }

  func preheatThumbnailAssets(start: [ThumbnailAsset], stop: [ThumbnailAsset]) async {
    let reader = await thumbnailReader()
    await reader.preheat(start: start, stop: stop)
  }

  func coverAssets(in scope: PhotoFetchScope, limit: Int) async throws -> [AssetDescriptor] {
    if overrideService == nil { try await requireLiveAuthorizationAsync() }
    let source = libraryRevision
    let reader = await thumbnailReader()
    let handles = try await reader.coverAssets(in: scope, limit: limit)
    try Task.checkCancellation()
    // A changed query cannot seed current image keys with older framework snapshots.
    guard source == libraryRevision else { return handles.map(\.descriptor) }
    for rawHandle in handles {
      let handle = rawHandle.withRevision(thumbnailContentRevision(for: rawHandle.descriptor.id))
      let id = handle.descriptor.id
      if defaultThumbnailAssets.count >= 64, let oldest = defaultThumbnailAssets.keys.first {
        defaultThumbnailAssets.removeValue(forKey: oldest)
      }
      defaultThumbnailAssets[id] = ResolvedThumbnail(
        handle: handle, revision: thumbnailContentRevision(for: id))
      if let asset = handle.photoKitAsset { observeThumbnailAsset(asset) }
      #if DEBUG
        thumbnailRegistrationObserver?(handle)
      #endif
    }
    return handles.map(\.descriptor)
  }

  func decodedThumbnail(
    for asset: ThumbnailAsset, quantizedSize: CGSize, deliveryMode: ThumbnailDeliveryMode
  ) async -> CGImage? {
    let id = asset.descriptor.id
    let revision = thumbnailContentRevision(for: id)
    let reader = await thumbnailReader()
    guard revision == thumbnailContentRevision(for: id), asset.contentRevision == revision,
      !Task.isCancelled
    else { return nil }
    registerDisplayedThumbnail(asset)
    let image = await decodedThumbnailCache.image(
      for: .init(
        assetId: id, quantizedSize: quantizedSize, deliveryMode: deliveryMode,
        contentRevision: revision),
      decode: { key in
        await reader.image(
          for: asset, spec: .init(size: key.quantizedSize, delivery: key.deliveryMode))
      })
    guard revision == thumbnailContentRevision(for: id), !Task.isCancelled else { return nil }
    return image
  }

  func decodedThumbnail(
    for assetId: String,
    quantizedSize: CGSize,
    deliveryMode: ThumbnailDeliveryMode
  ) async -> CGImage? {
    let revision = thumbnailContentRevision(for: assetId)
    let image = await decodedThumbnailCache.image(
      for: .init(
        assetId: assetId, quantizedSize: quantizedSize, deliveryMode: deliveryMode,
        contentRevision: revision))
    guard !Task.isCancelled, revision == thumbnailContentRevision(for: assetId) else { return nil }
    return image
  }

  func cachedDecodedThumbnail(
    for assetId: String,
    quantizedSize: CGSize,
    deliveryMode: ThumbnailDeliveryMode
  ) -> CGImage? {
    decodedThumbnailCache.cached(
      for: .init(
        assetId: assetId, quantizedSize: quantizedSize, deliveryMode: deliveryMode,
        contentRevision: thumbnailContentRevision(for: assetId)))
  }

  func thumbnailContentRevision(for assetId: String) -> Int {
    access(keyPath: \.nextThumbnailContentRevision)
    return max(globalThumbnailContentRevision, assetThumbnailContentRevisions[assetId] ?? 0)
  }

  /// Performs the PhotoKit authorization probe and registers as a
  /// `PHPhotoLibraryChangeObserver`. Production callers invoke this once from
  /// the WindowGroup's `.task` block; idempotent so accidental re-entry from
  /// scene recreation or test harnesses is a no-op.
  ///
  /// Skips entirely under XCTest / swift-testing (`AppEntry.isRunningInTests`; tests
  /// construct this manager directly, outside the app): tests run from DerivedData,
  /// and TCC sees that path as a different binary than the released app —
  /// asking for permissions would surface a prompt that blocks the test
  /// process with no automated way to dismiss. AutoSync and PhotoLibrary
  /// integration tests inject `FakePhotoLibraryService` /
  /// `FakePersistentChangeSource` instead.
  ///
  /// Also skips when an `overrideService` is set (screenshot mode). That mode
  /// uses `init(overrideService:)`, which produces curated content; running
  /// the real observer here would race with the override.
  func start() {
    guard !AppEntry.isRunningInTests else { return }
    guard overrideService == nil else { return }
    guard !hasStarted else { return }
    hasStarted = true
    observeAppActivation()
    verifyPhotoLibraryPermissions()
    // Observe library changes to invalidate cache
    PHPhotoLibrary.shared().register(self)
    // Initialize with current authorization status
    authorizationStatus = liveAuthorizationStatus()
    isAuthorized = Self.isAuthorizationSufficient(authorizationStatus)
  }

  @ObservationIgnored
  private var hasStarted = false

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

  /// Re-reads Photos access each time the app becomes active, whichever window is
  /// showing, or none: macOS posts nothing when access changes in System Settings, so the
  /// main window and Auto Export learn of a grant or revoke on return. Idempotent. `start()`
  /// calls it; tests pass their own center.
  func observeAppActivation(notificationCenter: NotificationCenter = .default) {
    guard appActivationSubscription == nil else { return }
    appActivationSubscription =
      notificationCenter
      .publisher(for: NSApplication.didBecomeActiveNotification)
      .sink { [weak self] _ in
        dispatchPrecondition(condition: .onQueue(.main))
        MainActor.assumeIsolated {
          self?.refreshAuthorizationStatus()
        }
      }
  }

  @ObservationIgnored
  private var appActivationSubscription: AnyCancellable?

  /// Re-reads existing permission without prompting. Install fresh-cache barriers
  /// before an authorization subscriber can start work against the newly visible library.
  func refreshAuthorizationStatus() {
    let status =
      overrideService?.authorizationStatus ?? liveAuthorizationStatus()
    guard status != authorizationStatus else { return }
    invalidateCache()
    authorizationStatus = status
    isAuthorized = Self.isAuthorizationSufficient(status)
  }

  /// Request authorization to access the Photos library
  func requestAuthorization() async -> Bool {
    if let s = overrideService {
      let result = await s.requestAuthorization()
      authorizationStatus = s.authorizationStatus
      isAuthorized = s.isAuthorized
      return result
    }
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

  /// Subscribes `livePhotoDetectionFallbackEnabled` to a Bool publisher — typically
  /// `ExportManager.livePhotosPairedExportPublisher`. Drives the `descriptor(from:)` resource
  /// fallback so it fires only when the user has opted into paired-video export.
  /// Synchronous sink (no `.receive(on:)`) so the value is observable immediately when
  /// the next fetch starts. Calling this multiple times replaces the prior binding.
  func bindLivePhotoDetectionFallback(to publisher: AnyPublisher<Bool, Never>) {
    livePhotoDetectionCancellables.removeAll()
    publisher
      .sink { [weak self] in self?.livePhotoDetectionFallbackEnabled = $0 }
      .store(in: &livePhotoDetectionCancellables)
  }

  /// Returns the number of assets in the given year/month whose `hasAdjustments` is true.
  ///
  /// `PHAsset.hasAdjustments` cannot be expressed as a Photos fetch predicate, so this falls
  /// back to iterating the month's assets. Results are cached until the next library change
  /// or authorisation change.
  func countAdjustedAssets(year: Int, month: Int) async throws -> Int {
    if let s = overrideService { return try await s.countAdjustedAssets(year: year, month: month) }
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
    if let s = overrideService { return try await s.countAdjustedAssets(year: year) }
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
    // Forward through the scope-aware overload below — that's where the override
    // dispatch happens. (Going through the override directly here would still work
    // but would double-dispatch when the override is nil; the scope path is the
    // canonical entry.)
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
    if let s = overrideService {
      return try await s.fetchAssets(in: scope, mediaType: mediaType)
    }
    guard isAuthorized else { throw PhotoLibraryError.authorizationDenied }
    let useResourceFallback = livePhotoDetectionFallbackEnabled
    switch scope {
    case .timeline(let year, let month):
      let phAssets = try await fetchPHAssets(year: year, month: month, mediaType: mediaType)
      cacheAssets(phAssets)
      return phAssets.map { Self.descriptor(from: $0, useResourceFallback: useResourceFallback) }
    case .favorites:
      let phAssets = fetchFavoritesPHAssets(mediaType: mediaType)
      cacheAssets(phAssets)
      return phAssets.map { Self.descriptor(from: $0, useResourceFallback: useResourceFallback) }
    case .album(let collectionLocalId), .sharedAlbum(let collectionLocalId):
      // Shared albums enumerate identically to user albums; the only difference is the
      // `PHAssetCollection.assetCollectionSubtype` we surfaced in the tree.
      let phAssets = fetchAlbumPHAssets(collectionLocalId: collectionLocalId, mediaType: mediaType)
      cacheAssets(phAssets)
      return phAssets.map { Self.descriptor(from: $0, useResourceFallback: useResourceFallback) }
    }
  }

  /// Streams the asset list for `scope` in `batchSize`-sized chunks. Runs the
  /// `PHFetchResult` enumeration off-main; PHAsset caching and descriptor
  /// mapping fold into a single main-actor hop per batch. PhotoKit allows
  /// `result.object(at:)` from a non-main thread; the main-actor constraint
  /// only applies to the cache + descriptor reads it follows.
  nonisolated func fetchAssetsProgressive(
    in scope: PhotoFetchScope, mediaType: PHAssetMediaType?, batchSize: Int = 200
  ) -> AsyncThrowingStream<[AssetDescriptor], any Error> {
    if let s = overrideService {
      return s.fetchAssetsProgressive(
        in: scope, mediaType: mediaType, batchSize: batchSize)
    }
    return AsyncThrowingStream { continuation in
      let task = Task.detached(priority: .userInitiated) { [weak self] in
        guard let self else {
          continuation.finish()
          return
        }
        do {
          try await self.requireLiveAuthorizationAsync()
        } catch {
          continuation.finish(throwing: error)
          return
        }
        let useResourceFallback = await MainActor.run {
          self.livePhotoDetectionFallbackEnabled
        }

        let query = PhotoLibraryQuery(scope: scope, mediaType: mediaType)
        let ticket = await MainActor.run {
          self.queryObservations.ticket(for: query, revision: self.libraryRevision)
        }
        let result: PHFetchResult<PHAsset>
        switch scope {
        case .timeline, .favorites:
          let opts = Self.fetchOptions(for: scope)
          Self.applyMediaTypeFilter(mediaType, to: opts)
          result = PHAsset.fetchAssets(with: opts)
        case .album(let collectionLocalId), .sharedAlbum(let collectionLocalId):
          guard
            let collection = Self.fetchAssetCollection(
              localIdentifier: collectionLocalId)
          else {
            continuation.finish()
            return
          }
          let opts = Self.fetchOptions(for: scope)
          Self.applyMediaTypeFilter(mediaType, to: opts)
          result = PHAsset.fetchAssets(in: collection, options: opts)
        }

        if let ticket {
          await MainActor.run {
            _ = self.queryObservations.install(result, for: ticket, revision: self.libraryRevision)
          }
        }
        let count = result.count
        let chunk = max(1, batchSize)
        var index = 0
        while index < count {
          if Task.isCancelled {
            continuation.finish()
            return
          }
          let end = min(index + chunk, count)
          // A `let` so the main-actor hop below can capture the batch.
          let phAssets: [PHAsset] = (index..<end).map { i in
            autoreleasepool { result.object(at: i) }
          }
          // descriptor(from:) is @MainActor (inherits from PLM); fold the
          // cache update + descriptor mapping into one main-actor hop.
          let descriptors = await MainActor.run {
            guard !Task.isCancelled else { return [AssetDescriptor]() }
            self.cacheAssets(phAssets)
            return phAssets.map {
              Self.descriptor(from: $0, useResourceFallback: useResourceFallback)
            }
          }
          guard !Task.isCancelled else {
            continuation.finish()
            return
          }
          if case .terminated = continuation.yield(descriptors) { return }
          index = end
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// ANDs a `mediaType ==` clause onto `opts.predicate` when `mediaType`
  /// is non-nil.
  nonisolated fileprivate static func applyMediaTypeFilter(
    _ mediaType: PHAssetMediaType?, to opts: PHFetchOptions
  ) {
    guard let mediaType else { return }
    let mediaPredicate = NSPredicate(format: "mediaType == %d", mediaType.rawValue)
    if let existing = opts.predicate {
      opts.predicate = NSCompoundPredicate(
        andPredicateWithSubpredicates: [existing, mediaPredicate])
    } else {
      opts.predicate = mediaPredicate
    }
  }

  // MARK: - Uncached collection scope counts

  /// Number of assets in a fetch scope, without caching. The detached fetch keeps
  /// PhotoKit enumeration off the main actor. Call `cachedCountAssets(in:)` when
  /// repeated reads should share the collection-count cache.
  nonisolated func countAssets(in scope: PhotoFetchScope) async throws -> Int {
    if let s = overrideService { return try await s.countAssets(in: scope) }
    try await requireLiveAuthorizationAsync()
    return try await runDetached(priority: .userInitiated) {
      try Task.checkCancellation()
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
    }
  }

  // MARK: - Cached counts

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
    try await awaitCountInvalidation()
    if let s = overrideService { return try await s.cachedCountAssets(in: scope) }
    let key = Self.cacheKey(for: scope, adjusted: false)
    return try await collectionCountCache.count(for: key) {
      try await self.countAssets(in: scope)
    }
  }

  nonisolated func cachedCountAdjustedAssets(in scope: PhotoFetchScope) async throws -> Int {
    try await awaitCountInvalidation()
    if let s = overrideService { return try await s.cachedCountAdjustedAssets(in: scope) }
    let key = Self.cacheKey(for: scope, adjusted: true)
    return try await collectionCountCache.count(for: key) {
      try await self.countAdjustedAssets(in: scope)
    }
  }

  private func awaitCountInvalidation() async throws {
    while let pending = countInvalidation {
      let gen = countInvalidationGeneration
      countInvalidationWaitObserver?()
      await pending.value
      try Task.checkCancellation()
      if gen == countInvalidationGeneration { return }
    }
    try Task.checkCancellation()
  }

  /// Number of assets in a fetch scope whose `hasAdjustments` is `true`. Iterates the
  /// fetch result inside a detached task; PHAsset values are not crossed back to the
  /// main actor.
  nonisolated func countAdjustedAssets(in scope: PhotoFetchScope) async throws -> Int {
    if let s = overrideService { return try await s.countAdjustedAssets(in: scope) }
    try await requireLiveAuthorizationAsync()
    return try await runDetached(priority: .userInitiated) {
      try Task.checkCancellation()
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
    }
  }

  func fetchAssetDescriptor(for assetId: String) -> AssetDescriptor? {
    if let s = overrideService { return s.fetchAssetDescriptor(for: assetId) }
    // Always re-fetch from Photos to ensure the asset still exists
    // (it may have been deleted since it was enqueued for export)
    let result = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
    guard let asset = result.firstObject else {
      phAssetCache.removeValue(forKey: assetId)
      return nil
    }
    cacheAssets([asset])
    return Self.descriptor(from: asset, useResourceFallback: livePhotoDetectionFallbackEnabled)
  }

  /// Fast count of assets in a given year/month without loading them into memory
  func countAssets(year: Int, month: Int) throws -> Int {
    if let s = overrideService { return try s.countAssets(year: year, month: month) }
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
    if let s = overrideService { return try s.countAssets(year: year) }
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
    if let s = overrideService { return try s.availableYears() }
    return try availableYearsWithCounts().map(\.year)
  }

  /// Returns descending list of years with at least one asset, together with per-year asset counts.
  func availableYearsWithCounts() throws -> [(year: Int, count: Int)] {
    if let s = overrideService { return try s.availableYearsWithCounts() }
    try requireLiveAuthorization()

    return try Self.scanYearsWithCounts().map { ($0.year, $0.count) }
  }

  nonisolated func loadYearsWithCounts() async throws -> [PhotoLibraryYearCount] {
    if let service = overrideService { return try await service.loadYearsWithCounts() }
    try await requireLiveAuthorizationAsync()
    return try await runDetached(priority: .userInitiated) { try Self.scanYearsWithCounts() }
  }

  nonisolated private static func scanYearsWithCounts() throws -> [PhotoLibraryYearCount] {
    try Task.checkCancellation()
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

    var yearCounts: [PhotoLibraryYearCount] = []
    for year in stride(from: endYear, through: startYear, by: -1) {
      let c = PHAsset.fetchAssets(with: Self.fetchOptions(for: .timeline(year: year, month: nil)))
        .count
      if c > 0 {
        yearCounts.append(PhotoLibraryYearCount(year: year, count: c))
      }
    }
    try Task.checkCancellation()
    return yearCounts
  }

  // MARK: - Thumbnail Management (PhotoLibraryService)

  func startCachingThumbnails(for assets: [AssetDescriptor]) {
    if let s = overrideService {
      s.startCachingThumbnails(for: assets)
      return
    }
    // Retain the PHAssets and balance overlapping consumers of the shared manager.
    let phAssets = Self.thumbnailPreheatRegistrations.register(assets.map(\.id)) {
      self.phAssetCache[$0]
    }
    guard !phAssets.isEmpty else { return }
    for delivery in [ThumbnailDeliveryMode.fast, .highQuality] {
      let spec = ThumbnailRequestSpec(size: ThumbnailRequestSpec.gridSize, delivery: delivery)
      Self.cachingImageManager.startCachingImages(
        for: phAssets, targetSize: spec.size, contentMode: spec.contentMode, options: spec.options()
      )
    }
  }

  func stopCachingThumbnails(for assets: [AssetDescriptor]) {
    if let s = overrideService {
      s.stopCachingThumbnails(for: assets)
      return
    }
    let phAssets = Self.thumbnailPreheatRegistrations.release(assets.map(\.id))
    guard !phAssets.isEmpty else { return }
    for delivery in [ThumbnailDeliveryMode.fast, .highQuality] {
      let spec = ThumbnailRequestSpec(size: ThumbnailRequestSpec.gridSize, delivery: delivery)
      Self.cachingImageManager.stopCachingImages(
        for: phAssets, targetSize: spec.size, contentMode: spec.contentMode, options: spec.options()
      )
    }
  }

  /// Load thumbnail for an asset (fast/degraded version only, for initial grid
  /// population). `allowNetwork` controls whether PhotoKit may go to iCloud if a fast
  /// format isn't cached locally — historically this was hardcoded to `false`, which
  /// stranded freshly-arrived iCloud assets with no rendered thumbnail (`PHPhotosError`
  /// 3303 "no resource found matching image request spec") even when the caller
  /// explicitly opted into the network. The `MonthViewModel.refresh(for:)` path and
  /// `retryThumbnail(for:)` both pass `true` for that reason.
  func loadThumbnail(for assetId: String, allowNetwork: Bool = true) async -> NSImage? {
    if let s = overrideService {
      return await s.loadThumbnail(for: assetId, allowNetwork: allowNetwork)
    }
    guard let asset = cachedOrFetchPHAsset(id: assetId) else { return nil }
    let options = PHImageRequestOptions()
    options.deliveryMode = .fastFormat
    options.isNetworkAccessAllowed = allowNetwork
    options.resizeMode = .fast
    let requestIDLock = OSAllocatedUnfairLock<PHImageRequestID?>(initialState: nil)
    return await withTaskCancellationHandler {
      if Task.isCancelled { return nil }
      return await withCheckedContinuation { continuation in
        let resumed = OSAllocatedUnfairLock(initialState: false)
        let requestID = Self.cachingImageManager.requestImage(
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
        requestIDLock.withLock { $0 = requestID }
        if Task.isCancelled {
          Self.cachingImageManager.cancelImageRequest(requestID)
        }
      }
    } onCancel: {
      if let requestID = requestIDLock.withLock({ $0 }) {
        Self.cachingImageManager.cancelImageRequest(requestID)
      }
    }
  }

  /// Load a high-quality thumbnail for an asset. `pixelSize` defaults to
  /// 200×200 px (the legacy size used by the timeline grid's high-quality
  /// upgrade path); tile views pass their displayed-pixel dimensions so
  /// PhotoKit doesn't return a smaller cached version that has to be
  /// scaled up by AppKit.
  func loadThumbnailHighQuality(
    for assetId: String,
    pixelSize: CGSize? = nil,
    allowNetwork: Bool = true
  ) async -> NSImage? {
    if let s = overrideService {
      return await s.loadThumbnailHighQuality(
        for: assetId, pixelSize: pixelSize, allowNetwork: allowNetwork)
    }
    guard let asset = cachedOrFetchPHAsset(id: assetId) else { return nil }
    let target = pixelSize ?? CGSize(width: 200, height: 200)
    let options = PHImageRequestOptions()
    options.deliveryMode = .highQualityFormat
    options.isNetworkAccessAllowed = allowNetwork
    options.resizeMode = .exact
    let requestIDLock = OSAllocatedUnfairLock<PHImageRequestID?>(initialState: nil)
    return await withTaskCancellationHandler {
      if Task.isCancelled { return nil }
      return await withCheckedContinuation { continuation in
        let resumed = OSAllocatedUnfairLock(initialState: false)
        let requestID = Self.cachingImageManager.requestImage(
          for: asset,
          targetSize: target,
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
        requestIDLock.withLock { $0 = requestID }
        if Task.isCancelled {
          Self.cachingImageManager.cancelImageRequest(requestID)
        }
      }
    } onCancel: {
      if let requestID = requestIDLock.withLock({ $0 }) {
        Self.cachingImageManager.cancelImageRequest(requestID)
      }
    }
  }

  func requestPreview(
    for assetId: String, pixelSize: CGSize,
    onDegraded: @escaping @MainActor @Sendable (NSImage) -> Void
  ) async throws -> NSImage {
    if let service = overrideService {
      return try await service.requestPreview(
        for: assetId, pixelSize: pixelSize, onDegraded: onDegraded)
    }
    return try await requestImage(
      for: assetId, targetSize: pixelSize, deliveryMode: .opportunistic,
      onDegraded: onDegraded)
  }

  /// Original-size requests remain available to consumers that need source pixels.
  func requestFullImage(for assetId: String) async throws -> NSImage {
    if let service = overrideService { return try await service.requestFullImage(for: assetId) }
    return try await requestImage(
      for: assetId, targetSize: PHImageManagerMaximumSize, deliveryMode: .highQualityFormat,
      onDegraded: { _ in })
  }

  private func requestImage(
    for assetId: String, targetSize: CGSize, deliveryMode: PHImageRequestOptionsDeliveryMode,
    onDegraded: @escaping @MainActor @Sendable (NSImage) -> Void
  ) async throws -> NSImage {
    try Task.checkCancellation()
    guard let asset = cachedOrFetchPHAsset(id: assetId) else {
      throw PhotoLibraryError.assetUnavailable
    }
    let options = PHImageRequestOptions()
    options.deliveryMode = deliveryMode
    options.isNetworkAccessAllowed = true
    options.isSynchronous = false
    let missingImageError: Error = PhotoLibraryError.assetUnavailable
    let bridge = FullImageRequestBridge { requestID in
      PHImageManager.default().cancelImageRequest(requestID)
    }
    return try await bridge.request { callback in
      PHImageManager.default().requestImage(
        for: asset, targetSize: targetSize, contentMode: .aspectFit, options: options
      ) { image, info in
        let response = FullImageRequestBridge.response(
          image: image, info: info, missingImageError: missingImageError)
        if response == nil, let image {
          Task { @MainActor in onDegraded(image) }
        }
        callback(response)
      }
    }
  }

  // MARK: - Resource Access (PhotoLibraryService)

  func resources(for assetId: String) -> [ResourceDescriptor] {
    if let s = overrideService { return s.resources(for: assetId) }
    guard let asset = cachedOrFetchPHAsset(id: assetId) else { return [] }
    return PHAssetResource.assetResources(for: asset).map {
      ResourceDescriptor(
        type: $0.type,
        originalFilename: $0.originalFilename,
        fileSize: Self.resourceFileSize($0))
    }
  }

  /// Reads PhotoKit's undocumented `fileSize` KVC property. Same trick used by
  /// `assetDetails(for:)`. Returns nil when the property is
  /// missing, non-numeric, or non-positive (treated as "unknown").
  fileprivate static func resourceFileSize(_ resource: PHAssetResource) -> Int64? {
    guard let size = resource.value(forKey: "fileSize") as? Int64, size > 0
    else { return nil }
    return size
  }

  func assetDetails(for assetId: String) -> AssetDetails? {
    access(keyPath: \.libraryRevision)
    if let s = overrideService { return s.assetDetails(for: assetId) }
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

  /// Resolves a single PHAsset by id from the cache, falling back to a
  /// one-shot fetch on miss. Does *not* write the miss result back: doing
  /// so would let per-asset resource-fallback resolves silently refill the
  /// cache during export and defeat `forgetPHAssetCache()`.
  private func cachedOrFetchPHAsset(id: String) -> PHAsset? {
    if let cached = phAssetCache[id] { return cached }
    let result = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
    return result.firstObject
  }

  private func observeThumbnailAsset(_ asset: PHAsset) {
    let id = asset.localIdentifier
    if observedThumbnailAssets[id] != nil
      || observedThumbnailAssets.count < Self.thumbnailTrackingLimit
    {
      observedThumbnailAssets[id] = asset
    } else {
      thumbnailTrackingIncomplete = true
    }
  }

  /// PhotoKit supplies details only for objects we previously fetched. Keep
  /// their after-change snapshots for the next callback. An empty or incomplete
  /// registry cannot establish which visible thumbnails changed, so callers
  /// fall back to a global content revision.
  private func changedThumbnailAssetIDs(in change: PHChange) -> Set<String>? {
    guard !thumbnailTrackingIncomplete, !observedThumbnailAssets.isEmpty else { return nil }
    var changedIDs: Set<String> = []
    let before = observedThumbnailAssets
    for (id, asset) in before {
      guard let details = change.changeDetails(for: asset) else { continue }
      if details.assetContentChanged || details.objectWasDeleted {
        changedIDs.insert(id)
      }
      if details.objectWasDeleted {
        observedThumbnailAssets.removeValue(forKey: id)
      } else if let updated = details.objectAfterChanges {
        observedThumbnailAssets[id] = updated
      }
    }
    return changedIDs
  }

  /// Invalidates library metadata and optionally known changed thumbnail
  /// content. A no-argument call is the conservative path used when a
  /// persistent-change catch-up has no PhotoKit object details.
  func invalidateCache(
    changedThumbnailAssetIDs: Set<String>? = nil,
    queryChanges: [PhotoLibraryQuery: Bool]? = nil
  ) {
    invalidatingQueryChanges = queryChanges
    defer { invalidatingQueryChanges = nil }
    phAssetCache.removeAll()
    adjustedCountByYearMonth.removeAll()
    cachedCollectionTree = nil
    if let changedThumbnailAssetIDs,
      assetThumbnailContentRevisions.count
        + changedThumbnailAssetIDs.subtracting(assetThumbnailContentRevisions.keys).count
        <= Self.thumbnailTrackingLimit
    {
      if !changedThumbnailAssetIDs.isEmpty {
        nextThumbnailContentRevision &+= 1
        for id in changedThumbnailAssetIDs {
          assetThumbnailContentRevisions[id] = nextThumbnailContentRevision
        }
      }
    } else {
      // Unknown IDs or a revision-map overflow: restart visible thumbnails
      // and clear the bounded decoded cache. Existing per-asset values are
      // subsumed by the newer global revision.
      nextThumbnailContentRevision &+= 1
      globalThumbnailContentRevision = nextThumbnailContentRevision
      assetThumbnailContentRevisions.removeAll()
      observedThumbnailAssets.removeAll()
      thumbnailTrackingIncomplete = false
      decodedThumbnailCache.clear()
    }
    // Install the barrier before observers can start a count refresh. Chain changes
    // so completion of an older invalidation cannot expose an intermediate cache.
    let previous = countInvalidation
    let invalidate = countInvalidationOverride
    countInvalidationGeneration &+= 1
    countInvalidation = Task { [collectionCountCache] in
      await previous?.value
      if let invalidate { await invalidate() }
      await collectionCountCache.invalidateAll()
    }
    libraryRevision &+= 1
  }

  /// Drops only the PHAsset cache. Unlike `invalidateCache()` it does not
  /// bump `libraryRevision` or clear the collection tree, so it can run
  /// mid-export without triggering SwiftUI re-fetches in sidebar/grid views.
  func forgetPHAssetCache() {
    phAssetCache.removeAll()
  }

  // MARK: - Collection scope fetch helpers

  /// Builds a `PHFetchOptions` for the given scope. Hidden assets stay excluded by
  /// default; sort is `creationDate` ascending for deterministic output. The Favorites
  /// scope adds a `favorite == YES` predicate; the timeline scope adds a date-range
  /// predicate. Album scope's predicate is empty (the collection itself bounds the
  /// fetch).
  nonisolated static func fetchOptions(for scope: PhotoFetchScope) -> PHFetchOptions {
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

  nonisolated static func fetchAssetCollection(localIdentifier: String)
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
    // Index-based form (not `enumerateObjects`) so `autoreleasepool` wraps
    // `result.object(at:)` — that's where the autoreleased Obj-C temporaries
    // are minted. A pool inside `enumerateObjects`'s closure drains only the
    // user-side body, not PhotoKit's allocation.
    for index in 0..<result.count {
      autoreleasepool {
        assets.append(result.object(at: index))
      }
    }
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
    // See `fetchFavoritesPHAssets` above for why this uses the index-based
    // form with `autoreleasepool` wrapping `result.object(at:)` rather than
    // `enumerateObjects { ... }`.
    for index in 0..<result.count {
      autoreleasepool {
        assets.append(result.object(at: index))
      }
    }
    return assets
  }

  // MARK: - Collection tree

  /// Cached collection tree. Invalidated on `photoLibraryDidChange`. Constructed lazily
  /// on the first `fetchCollectionTree()` call after a change (or first launch).
  @ObservationIgnored
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
    access(keyPath: \.libraryRevision)
    if let s = overrideService { return try s.fetchCollectionTree() }
    // A cache hit stays cheap and keeps the album sidebar while access is being rechecked.
    // Every collection scan still meets the live check in `fetchAssetsProgressive`.
    if let cached = cachedCollectionTree { return cached }
    try requireLiveAuthorization()
    let tree = try Self.scanCollectionTree(logger: logger)
    cachedCollectionTree = tree
    return tree
  }

  nonisolated func loadCollectionTree() async throws -> [PhotoCollectionDescriptor] {
    while true {
      try Task.checkCancellation()
      let (captured, cached) = await MainActor.run {
        (self.libraryRevision, self.cachedCollectionTree)
      }
      if overrideService == nil, let cached {
        try Task.checkCancellation()
        return cached
      }
      let tree: [PhotoCollectionDescriptor]
      if let service = overrideService {
        tree = try await service.loadCollectionTree()
      } else {
        try await requireLiveAuthorizationAsync()
        let logger = self.logger
        tree = try await runDetached(priority: .userInitiated) {
          try Self.scanCollectionTree(logger: logger)
        }
      }
      try Task.checkCancellation()
      let current = await MainActor.run {
        guard self.libraryRevision == captured else { return false }
        if self.overrideService == nil { self.cachedCollectionTree = tree }
        return true
      }
      if current { return tree }
      // A live operation retries changed membership instead of returning an obsolete snapshot.
    }
  }

  nonisolated private static func scanCollectionTree(logger: Logger) throws
    -> [PhotoCollectionDescriptor]
  {
    try Task.checkCancellation()
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
        logger.info(
          "fetchCollectionTree: shared-album surfaced title=\(title, privacy: .public) subtype=\(subtypeRaw) kind=\(descriptor.kind.rawValue, privacy: .public)"
        )
        sharedAlbumResults.append(descriptor)
      } else {
        logger.info(
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
      let histogramString =
        subtypeHistogram
        .sorted { $0.key < $1.key }
        .map { "subtype=\($0.key):\($0.value)" }
        .joined(separator: " ")
      logger.info(
        "fetchCollectionTree: no shared albums returned. Broad .album scan found \(anyAlbums.count) collection(s): \(histogramString, privacy: .public). If you have shared albums in Photos.app, check Photos → Settings → iCloud → \"Shared Albums\" is enabled. PHAssetCollectionSubtype.albumCloudShared raw value is 102."
      )
    }

    try Task.checkCancellation()
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
  /// Shared albums (`.albumCloudShared`) route to `.sharedAlbum` so the sidebar
  /// and export path can preserve their distinct fidelity and placement rules.
  ///
  /// `internal` (default) instead of `fileprivate` so the routing — the single
  /// place that decides which PhotoKit subtypes the app surfaces, and how — is
  /// directly unit-testable through `@testable import`. Without that test the
  /// production tree only sees these decisions via `descriptor(from:)` plus a
  /// canned `PHCollection`, which is harder to instantiate in a unit test.
  nonisolated static func descriptorKind(
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
  nonisolated fileprivate static func descriptor(
    from collection: PHCollection, parentPath: [String]
  )
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

    // batchSize 100 (down from 500) for 5× more frequent main-thread yields
    // during the AutoSync startup sweep. Memory is bounded by
    // the autoreleasepool below; this only controls yield frequency.
    let totalAssets = fetchResult.count
    let batchSize = 100

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

  /// Defaults `useResourceFallback: false` so the cheap path (subtype-flag only) runs
  /// for legacy/test call sites. Production fetches go through the instance methods
  /// above which read `livePhotoDetectionFallbackEnabled` and pass `true` when the
  /// user has paired Live Photo export enabled.
  static func descriptor(from asset: PHAsset, useResourceFallback: Bool = false)
    -> AssetDescriptor
  {
    AssetDescriptor(
      id: asset.localIdentifier,
      creationDate: asset.creationDate,
      mediaType: asset.mediaType,
      pixelWidth: asset.pixelWidth,
      pixelHeight: asset.pixelHeight,
      duration: asset.duration,
      hasAdjustments: asset.hasAdjustments,
      originalUTI: Self.originalUTI(for: asset),
      isLivePhoto: Self.detectLivePhoto(asset: asset, useResourceFallback: useResourceFallback)
    )
  }

  /// PHAsset's `uniformTypeIdentifier` is exposed via undocumented KVC — it's
  /// the cheapest reliable way to detect format without iterating
  /// `PHAssetResource.assetResources(for:)`. Same shape as the existing
  /// `resource.value(forKey: "fileSize")` call used for
  /// `ResourceDescriptor.fileSize` — stable in practice through
  /// current macOS versions, but defended against KVC returning nil or
  /// non-String in case the property is renamed or removed: `originalUTI: nil`
  /// falls back to "treat as non-HEIC" which matches the conversion-off
  /// default.
  ///
  /// **Must be called from the main actor.** PHAsset KVC thread-safety is not
  /// documented; in practice every PhotoKit call in this manager originates
  /// from `@MainActor`-isolated contexts, so we don't race against PhotoKit's
  /// own queues. If a future `nonisolated` fetch path needs to build
  /// descriptors, either add a main-actor hop or switch to
  /// `PHAssetResource.assetResources(for:).first?.uniformTypeIdentifier` at
  /// the (one PhotoKit call per resource) cost.
  private static func originalUTI(for asset: PHAsset) -> String? {
    asset.value(forKey: "uniformTypeIdentifier") as? String
  }

  /// `.photoLive` media subtype is the canonical Live Photo signal and is essentially
  /// free to check. The fallback enumerates `PHAssetResource` to also catch iCloud-
  /// synced assets that drop the subtype flag — gated by `useResourceFallback` because
  /// the resource enumeration allocates per asset and would fire for every image in a
  /// large fetch. Caller passes `true` only when paired-video export is enabled
  /// and will use the result. Image-
  /// typed assets only — video and audio assets are never Live Photos.
  static func detectLivePhoto(asset: PHAsset, useResourceFallback: Bool) -> Bool {
    guard asset.mediaType == .image else { return false }
    if asset.mediaSubtypes.contains(.photoLive) { return true }
    guard useResourceFallback else { return false }
    let resources = PHAssetResource.assetResources(for: asset)
    return resources.contains { resource in
      resource.type == .pairedVideo || resource.type == .fullSizePairedVideo
    }
  }
}

// MARK: - PHPhotoLibraryChangeObserver

extension PhotoLibraryManager: PHPhotoLibraryChangeObserver {
  nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
    Task { @MainActor in
      let changedIDs = self.changedThumbnailAssetIDs(in: changeInstance)
      let queries = self.queryObservations.changes { result in
        guard let details = changeInstance.changeDetails(for: result) else {
          return (result, false)
        }
        let affected =
          !details.hasIncrementalChanges || details.hasMoves
          || !(details.insertedIndexes?.isEmpty ?? true)
          || !(details.removedIndexes?.isEmpty ?? true)
          || !(details.changedIndexes?.isEmpty ?? true)
        return (details.fetchResultAfterChanges, affected)
      }
      self.invalidateCache(changedThumbnailAssetIDs: changedIDs, queryChanges: queries)
    }
  }
}
