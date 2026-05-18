import Photos
import Testing

@testable import Photo_Export

/// Phase 6 regression gate. Pins that every `PhotoLibraryService` method on
/// `ScreenshotPhotoLibraryService` returns curated synthetic data — not the empty /
/// nil values a production-PhotoKit call without authorisation would return.
///
/// Since issue #67 item 1 (May 2026), `ScreenshotPhotoLibraryService` is a peer
/// type — it no longer inherits from `PhotoLibraryManager`, so a newly-added
/// `PhotoLibraryService` method now fails to compile until it has a real
/// implementation here. That closes the structural hole this gate's previous
/// docstring called out as a "known limitation". The behavioral assertions
/// below still run as a safety net against a future regression that swaps the
/// curated content back to PhotoKit-shaped empties.
@MainActor
struct ScreenshotPhotoLibraryServiceOverridesTests {

  // MARK: - Auth

  @Test func authorizationOverrideReturnsAuthorized() async {
    let svc = ScreenshotPhotoLibraryService()
    let ok = await svc.requestAuthorization()
    #expect(ok)
    #expect(svc.isAuthorized)
    #expect(svc.authorizationStatus == .authorized)
  }

  // MARK: - Timeline reads

  @Test func fetchAssetsForYearMonthReturnsCuratedData() async throws {
    let svc = ScreenshotPhotoLibraryService()
    let years = try svc.availableYears()
    #expect(!years.isEmpty,
      "screenshot mode must surface curated years; an empty list means the override didn't take")
    guard let firstYear = years.first else { return }
    let yearAssets = try await svc.fetchAssets(year: firstYear, month: nil, mediaType: nil)
    #expect(!yearAssets.isEmpty,
      "fetchAssets(year:month:) must return curated synthetic assets, not an empty production result")
  }

  @Test func availableYearsWithCountsReturnsCuratedData() throws {
    let svc = ScreenshotPhotoLibraryService()
    let counts = try svc.availableYearsWithCounts()
    #expect(!counts.isEmpty)
    #expect(counts.allSatisfy { $0.count > 0 },
      "every screenshot year must surface a non-zero curated count")
  }

  @Test func countAssetsForYearMonthReturnsCuratedData() throws {
    let svc = ScreenshotPhotoLibraryService()
    let years = try svc.availableYears()
    guard let firstYear = years.first else { return }
    let total = try svc.countAssets(year: firstYear)
    #expect(total > 0)
  }

  @Test func countAdjustedAssetsForYearMonthReturnsCuratedData() async throws {
    let svc = ScreenshotPhotoLibraryService()
    let years = try svc.availableYears()
    guard let firstYear = years.first else { return }
    let adjusted = try await svc.countAdjustedAssets(year: firstYear)
    #expect(adjusted >= 0)
  }

  // MARK: - Collections

  @Test func fetchCollectionTreeReturnsCuratedTree() throws {
    let svc = ScreenshotPhotoLibraryService()
    let tree = try svc.fetchCollectionTree()
    #expect(!tree.isEmpty)
    let kinds = Set(tree.map(\.kind))
    #expect(kinds.contains(.favorites))
    #expect(kinds.contains(.album))
    #expect(kinds.contains(.folder),
      "tree must include the Trips folder so folder-export surfaces in marketing captures")
    #expect(kinds.contains(.sharedAlbum),
      "tree must include the shared-album entry (issue #48) so the Shared Albums section renders")
  }

  @Test func fetchAssetsInFavoritesScopeReturnsCuratedFavorites() async throws {
    let svc = ScreenshotPhotoLibraryService()
    let favs = try await svc.fetchAssets(in: .favorites, mediaType: nil)
    #expect(!favs.isEmpty,
      "favorites scope must surface curated synthetic favorites, not empty production result")
  }

  @Test func fetchAssetsInAlbumScopeReturnsCuratedAlbumAssets() async throws {
    let svc = ScreenshotPhotoLibraryService()
    let tree = try svc.fetchCollectionTree()
    let firstAlbum = tree.first { $0.kind == .album }
    guard let albumId = firstAlbum?.localIdentifier else {
      Issue.record("Curated tree must contain at least one album")
      return
    }
    let assets = try await svc.fetchAssets(in: .album(collectionId: albumId), mediaType: nil)
    #expect(!assets.isEmpty)
  }

  @Test func countAssetsInScopeReturnsCuratedCount() async throws {
    let svc = ScreenshotPhotoLibraryService()
    let count = try await svc.countAssets(in: .favorites)
    #expect(count > 0)
  }

  @Test func countAdjustedAssetsInScopeReturnsCuratedCount() async throws {
    let svc = ScreenshotPhotoLibraryService()
    let total = try await svc.countAssets(in: .favorites)
    let adjusted = try await svc.countAdjustedAssets(in: .favorites)
    #expect(adjusted == max(0, total / 4),
      "screenshot adjusted count must follow the curated max(0, total / 4) shape; any other value means the production path ran (which would throw `authorizationDenied` in unit tests)")
  }

  @Test func cachedCountAssetsInScopeReturnsCuratedCount() async throws {
    let svc = ScreenshotPhotoLibraryService()
    let count = try await svc.cachedCountAssets(in: .favorites)
    #expect(count > 0)
  }

  @Test func cachedCountAdjustedAssetsInScopeReturnsCuratedCount() async throws {
    let svc = ScreenshotPhotoLibraryService()
    let total = try await svc.countAssets(in: .favorites)
    let adjusted = try await svc.cachedCountAdjustedAssets(in: .favorites)
    #expect(adjusted == max(0, total / 4),
      "cached adjusted count must follow the curated max(0, total / 4) shape; production would throw `authorizationDenied` from `collectionCountCache.count(_:_:)`'s producer")
  }

  // MARK: - Asset details

  @Test func fetchAssetDescriptorReturnsCuratedDescriptor() {
    let svc = ScreenshotPhotoLibraryService()
    let descriptor = svc.fetchAssetDescriptor(for: "family-1")
    #expect(descriptor != nil,
      "screenshot service must surface a curated descriptor for any curated id, not nil")
  }

  @Test func resourcesReturnsCuratedResource() {
    let svc = ScreenshotPhotoLibraryService()
    let resources = svc.resources(for: "family-1")
    #expect(!resources.isEmpty)
    #expect(resources.first?.originalFilename == "family-1.HEIC")
  }

  @Test func assetDetailsReturnsCuratedDetails() {
    let svc = ScreenshotPhotoLibraryService()
    let details = svc.assetDetails(for: "family-1")
    #expect(details?.originalFilename == "family-1.HEIC")
  }

  // MARK: - Thumbnails

  @Test func loadThumbnailReturnsImage() async {
    let svc = ScreenshotPhotoLibraryService()
    let img = await svc.loadThumbnail(for: "family-1", allowNetwork: false)
    #expect(img != nil,
      "screenshot service must return at minimum a placeholder gradient — nil means the override fell through to production")
  }

  @Test func loadThumbnailHighQualityReturnsImage() async {
    let svc = ScreenshotPhotoLibraryService()
    let img = await svc.loadThumbnailHighQuality(for: "family-1", allowNetwork: false)
    #expect(img != nil)
  }

  @Test func requestFullImageReturnsImage() async throws {
    let svc = ScreenshotPhotoLibraryService()
    let img = try await svc.requestFullImage(for: "family-1")
    _ = img  // non-throw is the pin
  }

  /// Limitation: production's `start/stopCachingThumbnails(for:)` also no-ops in unit
  /// tests because `phAssetCache` is empty (it's populated by a prior `fetchAssets` on
  /// the real Photos library, which never runs here). Removing the override therefore
  /// would not fail this test — the override exists so the production path never reaches
  /// `PHCachingImageManager.shared`, which would otherwise be poked on the real system
  /// at runtime. The composition follow-up closes this hole structurally; until then
  /// the assertion below pins method presence + call-shape only.
  @Test func startStopCachingThumbnailsAreNoOps() {
    let svc = ScreenshotPhotoLibraryService()
    let asset = TestAssetFactory.makeAsset(id: "family-1")
    svc.startCachingThumbnails(for: [asset])
    svc.stopCachingThumbnails(for: [asset])
    // Also exercise the empty path so a future override that crashes on empty input fails here.
    svc.startCachingThumbnails(for: [])
    svc.stopCachingThumbnails(for: [])
  }

  // MARK: - Wiring

  /// Single-source-of-truth check mirroring the `photo_exportApp` injection: in
  /// screenshot mode the wrapping `PhotoLibraryManager` holds an injected
  /// `ScreenshotPhotoLibraryService` as its `overrideService`. In production the
  /// override is nil and the manager runs its built-in PhotoKit code. With the
  /// inheritance removed (issue #67 item 1), these are peer types — the
  /// composition wiring is what reaches the curated service from the UI.
  @Test func appWiringSelectsScreenshotServiceInScreenshotMode() {
    let production = PhotoLibraryManager()
    let screenshotService = ScreenshotPhotoLibraryService()
    let wrapped = PhotoLibraryManager(overrideService: screenshotService)

    // Production manager has no override and is its own production
    // implementation; wrapping the screenshot service makes the manager forward
    // every PhotoLibraryService method to it.
    #expect(production.authorizationStatus != .authorized || production.isAuthorized,
      "production manager state is whatever PhotoKit reports; sanity check only")
    #expect(wrapped.isAuthorized == true,
      "wrapped manager mirrors the override's auth state")
    #expect(wrapped.authorizationStatus == .authorized,
      "wrapped manager mirrors the override's auth status")
  }
}
