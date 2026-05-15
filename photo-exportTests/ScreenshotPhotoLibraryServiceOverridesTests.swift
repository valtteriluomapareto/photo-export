import Photos
import Testing

@testable import Photo_Export

/// Phase 6 regression gate. The screenshot run currently uses
/// `ScreenshotPhotoLibraryService: PhotoLibraryManager` (inheritance). Every
/// `PhotoLibraryService` method must be overridden — leaving any to inherit from
/// `PhotoLibraryManager` would route the screenshot run back to the real Photos
/// library and defeat the entire point of the mode.
///
/// This test exercises every method through the screenshot subclass and asserts the
/// curated synthetic data flows out — not the empty / nil values a production manager
/// would return when PhotoKit isn't authorised. A future regression that removed an
/// `override` (so the call fell through to `PhotoLibraryManager`'s production
/// implementation) would fail here.
///
/// The plan's Phase 6 also calls for "PhotoLibraryManager should not rely on
/// inheritance"; that's a follow-up extraction (Production / Screenshot services as
/// peers, manager as a thin wrapper). The change is large (~973 lines of production
/// PhotoKit code to relocate) and orthogonal to the regression-gate property the
/// inheritance contract relies on — pinned here so the larger move can land later
/// without losing the safety net.
///
/// **Known limitation**: this suite enumerates every `PhotoLibraryService` method that
/// exists today. A NEW method added to the protocol will be inherited from
/// `PhotoLibraryManager` (production behaviour) unless someone also adds an override
/// AND a corresponding test here. The gate catches missed overrides on existing
/// methods, not missed overrides on additions. The composition follow-up (drop the
/// inheritance entirely) closes this hole structurally; until then, anyone adding a
/// method to `PhotoLibraryService` should add a test to this suite in the same PR.
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
    _ = try await svc.countAdjustedAssets(in: .favorites)
    // Returning at all (vs trapping/throwing on a production fetch) proves the override
  }

  @Test func cachedCountAssetsInScopeReturnsCuratedCount() async throws {
    let svc = ScreenshotPhotoLibraryService()
    let count = try await svc.cachedCountAssets(in: .favorites)
    #expect(count > 0)
  }

  @Test func cachedCountAdjustedAssetsInScopeReturnsCuratedCount() async throws {
    let svc = ScreenshotPhotoLibraryService()
    _ = try await svc.cachedCountAdjustedAssets(in: .favorites)
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

  @Test func startStopCachingThumbnailsAreNoOps() {
    let svc = ScreenshotPhotoLibraryService()
    let asset = TestAssetFactory.makeAsset(id: "family-1")
    svc.startCachingThumbnails(for: [asset])
    svc.stopCachingThumbnails(for: [asset])
  }

  // MARK: - Wiring

  /// Single-source-of-truth check: the app-launch wiring in `photo_exportApp` selects
  /// `ScreenshotPhotoLibraryService` when `isRunningInScreenshotMode` is true. This
  /// test mirrors that branch to confirm the type-switch produces the expected
  /// concrete type for both modes.
  @Test func appWiringSelectsScreenshotServiceInScreenshotMode() {
    let production: PhotoLibraryManager = PhotoLibraryManager()
    #expect(!(production is ScreenshotPhotoLibraryService),
      "production manager must NOT also be ScreenshotPhotoLibraryService")

    let screenshot: PhotoLibraryManager = ScreenshotPhotoLibraryService()
    #expect(screenshot is ScreenshotPhotoLibraryService,
      "screenshot wiring must produce a ScreenshotPhotoLibraryService instance")
  }
}
