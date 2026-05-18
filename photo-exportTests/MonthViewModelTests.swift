import AppKit
import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Closes a P0 coverage gap: `MonthViewModel` had **zero** direct tests despite
/// being the heart of both `MonthContentView` and `CollectionContentView`. It
/// owns the asset/thumbnail pipeline (initial fast-thumbnail batch → background
/// fast-thumbnail fanout → HQ upgrade), the `PHCachingImageManager` lifecycle
/// (`stopCachingThumbnails` for the previous scope before `startCachingThumbnails`
/// for the new), and the cancellation of the in-flight HQ upgrade task on every
/// scope change.
///
/// A regression that broke any of those — for example, dropping the
/// `stopCachingThumbnails` call so the cache leaks across scope changes, or
/// flipping the order of the auto-select-first and `isLoading=false` settings —
/// would be invisible to the rest of the test suite.
@MainActor
struct MonthViewModelTests {

  // MARK: - Fixtures

  private func makeAsset(id: String, hasAdjustments: Bool = false) -> AssetDescriptor {
    AssetDescriptor(
      id: id,
      creationDate: Date(timeIntervalSince1970: 1_700_000_000),
      mediaType: .image,
      pixelWidth: 100,
      pixelHeight: 100,
      duration: 0,
      hasAdjustments: hasAdjustments
    )
  }

  /// 1×1 transparent NSImage so the fake's `loadThumbnail` returns a non-nil value.
  private func dummyImage() -> NSImage {
    let img = NSImage(size: NSSize(width: 1, height: 1))
    img.lockFocus()
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: 1, height: 1).fill()
    img.unlockFocus()
    return img
  }

  /// Wait briefly for the background HQ upgrade `Task` (spawned at the end of
  /// `loadAssets(for:)`) to drain. The fake's thumbnail methods return
  /// synchronously, so two yields is enough on a quiet test runner.
  private func drainBackgroundWork() async {
    for _ in 0..<5 {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
  }

  // MARK: - Initial load

  @Test func initialLoadFetchesAssetsAndThumbnails() async throws {
    let svc = FakePhotoLibraryService()
    let assets = (0..<3).map { makeAsset(id: "a\($0)") }
    svc.assetsByYearMonth["2025-6"] = assets
    for asset in assets {
      svc.thumbnailsByAssetId[asset.id] = dummyImage()
    }

    let vm = MonthViewModel(photoLibraryService: svc)
    await vm.loadAssets(for: .timeline(year: 2025, month: 6))

    #expect(vm.assets.map(\.id) == ["a0", "a1", "a2"])
    #expect(!vm.isLoading)
    #expect(vm.errorMessage == nil)
    // All three assets had canned thumbnails — none should be in failedThumbnailIds.
    #expect(vm.failedThumbnailIds.isEmpty)
    #expect(vm.thumbnailsById.count == 3)
  }

  @Test func assetsWithoutThumbnailsLandInFailedSet() async throws {
    let svc = FakePhotoLibraryService()
    let withThumb = makeAsset(id: "ok")
    let noThumb = makeAsset(id: "missing")
    svc.assetsByYearMonth["2025-7"] = [withThumb, noThumb]
    svc.thumbnailsByAssetId[withThumb.id] = dummyImage()
    // noThumb has no canned thumbnail → fake returns nil → failedThumbnailIds.

    let vm = MonthViewModel(photoLibraryService: svc)
    await vm.loadAssets(for: .timeline(year: 2025, month: 7))

    #expect(vm.thumbnailsById.keys.sorted() == ["ok"])
    #expect(vm.failedThumbnailIds == ["missing"])
    if case .loaded(let img) = vm.thumbnailState(for: withThumb) {
      #expect(img === svc.thumbnailsByAssetId["ok"])
    } else {
      Issue.record("expected .loaded for withThumb")
    }
    if case .failed = vm.thumbnailState(for: noThumb) {
      // good
    } else {
      Issue.record("expected .failed for noThumb")
    }
  }

  // MARK: - Auto-select

  @Test func autoSelectsFirstAssetAfterLoad() async throws {
    let svc = FakePhotoLibraryService()
    let assets = (0..<3).map { makeAsset(id: "a\($0)") }
    svc.assetsByYearMonth["2025-6"] = assets

    let vm = MonthViewModel(photoLibraryService: svc)
    await vm.loadAssets(for: .timeline(year: 2025, month: 6))

    #expect(vm.selectedAssetId == "a0")
  }

  @Test func emptyAssetListDoesNotAutoSelect() async throws {
    let svc = FakePhotoLibraryService()
    svc.assetsByYearMonth["2025-1"] = []  // no assets

    let vm = MonthViewModel(photoLibraryService: svc)
    await vm.loadAssets(for: .timeline(year: 2025, month: 1))

    #expect(vm.assets.isEmpty)
    #expect(vm.selectedAssetId == nil)
    #expect(vm.thumbnailsById.isEmpty)
  }

  // MARK: - Scope switching + caching lifecycle

  /// `PHCachingImageManager` lifecycle: when the user switches scope, the
  /// previous scope's preheating must stop *before* the new scope's
  /// preheating starts. A regression that drops the stop call would leak
  /// PHAssets in the cache across scope changes.
  @Test func switchingScopeStopsPriorCacheBeforeStartingNew() async throws {
    let svc = FakePhotoLibraryService()
    let scope1Assets = [makeAsset(id: "s1-a"), makeAsset(id: "s1-b")]
    let scope2Assets = [makeAsset(id: "s2-a")]
    svc.assetsByYearMonth["2025-3"] = scope1Assets
    svc.favoritesAssets = scope2Assets

    let vm = MonthViewModel(photoLibraryService: svc)
    await vm.loadAssets(for: .timeline(year: 2025, month: 3))
    #expect(svc.startCachingCalls.count == 1)
    #expect(svc.startCachingCalls.last?.map(\.id) == ["s1-a", "s1-b"])
    #expect(svc.stopCachingCalls.isEmpty, "first scope has nothing to stop")

    await vm.loadAssets(for: .favorites)
    #expect(
      svc.stopCachingCalls.last?.map(\.id) == ["s1-a", "s1-b"],
      "previous scope's assets must be stopped before the new scope is loaded")
    #expect(svc.startCachingCalls.last?.map(\.id) == ["s2-a"])
    #expect(vm.assets.map(\.id) == ["s2-a"])
  }

  @Test func nilScopeClearsAllState() async throws {
    let svc = FakePhotoLibraryService()
    let assets = [makeAsset(id: "a"), makeAsset(id: "b")]
    svc.assetsByYearMonth["2025-2"] = assets
    for asset in assets { svc.thumbnailsByAssetId[asset.id] = dummyImage() }

    let vm = MonthViewModel(photoLibraryService: svc)
    await vm.loadAssets(for: .timeline(year: 2025, month: 2))
    #expect(!vm.assets.isEmpty)
    #expect(vm.selectedAssetId != nil)

    // Pass nil — view model should clear everything.
    await vm.loadAssets(for: nil)

    #expect(vm.assets.isEmpty)
    #expect(vm.thumbnailsById.isEmpty)
    #expect(vm.failedThumbnailIds.isEmpty)
    #expect(vm.selectedAssetId == nil)
    #expect(!vm.isLoading)
    // The previous scope's caching was stopped on entry to the nil-scope load.
    #expect(svc.stopCachingCalls.last?.map(\.id) == ["a", "b"])
  }

  // MARK: - Error path

  @Test func fetchErrorSurfacesViaErrorMessage() async throws {
    let svc = FakePhotoLibraryService()
    svc.fetchAssetsError = NSError(
      domain: "Test", code: 7, userInfo: [NSLocalizedDescriptionKey: "boom"])

    let vm = MonthViewModel(photoLibraryService: svc)
    await vm.loadAssets(for: .timeline(year: 2025, month: 4))

    #expect(vm.errorMessage == "boom")
    #expect(!vm.isLoading)
    #expect(vm.assets.isEmpty)
  }

  // MARK: - retryThumbnail

  @Test func retryThumbnailClearsFailedAndReloads() async throws {
    let svc = FakePhotoLibraryService()
    let asset = makeAsset(id: "retry-me")
    svc.assetsByYearMonth["2025-5"] = [asset]
    // Initial load: no canned thumbnail → falls into failedThumbnailIds.

    let vm = MonthViewModel(photoLibraryService: svc)
    await vm.loadAssets(for: .timeline(year: 2025, month: 5))
    #expect(vm.failedThumbnailIds == ["retry-me"])
    #expect(vm.thumbnailsById["retry-me"] == nil)

    // Now stage a thumbnail and retry — failedThumbnailIds clears, thumbnail loads.
    svc.thumbnailsByAssetId["retry-me"] = dummyImage()
    vm.retryThumbnail(for: "retry-me")
    await drainBackgroundWork()

    #expect(!vm.failedThumbnailIds.contains("retry-me"))
    #expect(vm.thumbnailsById["retry-me"] != nil)
  }

  // MARK: - select / setExportRunning

  @Test func selectAndSetExportRunningToggleState() async throws {
    let svc = FakePhotoLibraryService()
    let vm = MonthViewModel(photoLibraryService: svc)

    vm.select(assetId: "abc")
    #expect(vm.selectedAssetId == "abc")
    vm.select(assetId: nil)
    #expect(vm.selectedAssetId == nil)

    #expect(!vm.isExportRunning)
    vm.setExportRunning(true)
    #expect(vm.isExportRunning)
    vm.setExportRunning(false)
    #expect(!vm.isExportRunning)
  }

  // MARK: - thumbnail(for:) accessor

  @Test func thumbnailAccessorReturnsLoadedImageOrNil() async throws {
    let svc = FakePhotoLibraryService()
    let asset = makeAsset(id: "t")
    let img = dummyImage()
    svc.assetsByYearMonth["2025-9"] = [asset]
    svc.thumbnailsByAssetId[asset.id] = img

    let vm = MonthViewModel(photoLibraryService: svc)
    #expect(vm.thumbnail(for: asset) == nil)  // before load
    await vm.loadAssets(for: .timeline(year: 2025, month: 9))
    #expect(vm.thumbnail(for: asset) === img)
  }

  // MARK: - refresh(for:)

  /// Refresh keeps already-loaded thumbnails for assets that still exist and
  /// fetches thumbnails for newly added assets. Mirrors the iCloud-sync case
  /// where the user is watching a month grid as new photos land in the library.
  @Test func refreshKeepsExistingThumbnailsAndLoadsAddedOnes() async throws {
    let svc = FakePhotoLibraryService()
    let original = (0..<3).map { makeAsset(id: "a\($0)") }
    svc.assetsByYearMonth["2025-6"] = original
    for asset in original { svc.thumbnailsByAssetId[asset.id] = dummyImage() }

    let vm = MonthViewModel(photoLibraryService: svc)
    await vm.loadAssets(for: .timeline(year: 2025, month: 6))
    await drainBackgroundWork()
    let thumbsBefore = vm.thumbnailsById
    #expect(thumbsBefore.count == 3)

    // Library mutation: a fourth photo lands.
    let added = makeAsset(id: "a3")
    svc.assetsByYearMonth["2025-6"] = original + [added]
    svc.thumbnailsByAssetId[added.id] = dummyImage()

    await vm.refresh(for: .timeline(year: 2025, month: 6))
    await drainBackgroundWork()

    #expect(vm.assets.map(\.id) == ["a0", "a1", "a2", "a3"])
    // Survivors keep their original NSImage references — the dict was filtered,
    // not rebuilt.
    for asset in original {
      #expect(vm.thumbnailsById[asset.id] === thumbsBefore[asset.id])
    }
    // Newcomer's thumbnail loaded too.
    #expect(vm.thumbnailsById["a3"] != nil)
  }

  /// Assets that disappear from the library are removed from `assets` and from
  /// every per-id dict (`thumbnailsById`, `failedThumbnailIds`, `highQualityIds`),
  /// and their PHCachingImageManager preheat is stopped.
  @Test func refreshPrunesRemovedAssets() async throws {
    let svc = FakePhotoLibraryService()
    let keep = makeAsset(id: "keep")
    let drop = makeAsset(id: "drop")
    svc.assetsByYearMonth["2025-7"] = [keep, drop]
    svc.thumbnailsByAssetId[keep.id] = dummyImage()
    svc.thumbnailsByAssetId[drop.id] = dummyImage()

    let vm = MonthViewModel(photoLibraryService: svc)
    await vm.loadAssets(for: .timeline(year: 2025, month: 7))
    await drainBackgroundWork()
    #expect(vm.thumbnailsById.count == 2)
    let stopCountBefore = svc.stopCachingCalls.count

    // Library mutation: `drop` is deleted from Photos.app.
    svc.assetsByYearMonth["2025-7"] = [keep]
    await vm.refresh(for: .timeline(year: 2025, month: 7))

    #expect(vm.assets.map(\.id) == ["keep"])
    #expect(vm.thumbnailsById.keys.sorted() == ["keep"])
    #expect(!vm.failedThumbnailIds.contains("drop"))
    #expect(svc.stopCachingCalls.count == stopCountBefore + 1)
    #expect(svc.stopCachingCalls.last?.map(\.id) == ["drop"])
  }

  /// `refresh(for: nil)` is a no-op — the view model retains whatever it was
  /// already displaying. Mirrors the docstring contract.
  @Test func refreshNilScopeIsNoOp() async throws {
    let svc = FakePhotoLibraryService()
    let assets = [makeAsset(id: "x")]
    svc.assetsByYearMonth["2025-1"] = assets
    svc.thumbnailsByAssetId["x"] = dummyImage()

    let vm = MonthViewModel(photoLibraryService: svc)
    await vm.loadAssets(for: .timeline(year: 2025, month: 1))
    let assetsBefore = vm.assets
    let thumbsBefore = vm.thumbnailsById

    await vm.refresh(for: nil)

    #expect(vm.assets.map(\.id) == assetsBefore.map(\.id))
    #expect(vm.thumbnailsById.count == thumbsBefore.count)
  }

  /// Race fix: if the user navigates to a new scope while a `refresh` task is
  /// awaiting `fetchAssets`, the resumed refresh must NOT overwrite the new
  /// scope's state. The `currentScope` guard inside `refresh` is the safeguard;
  /// without it the stale May fetch would clobber June's freshly-loaded assets.
  @Test func refreshBailsWhenScopeChangedMidFetch() async throws {
    let svc = FakePhotoLibraryService()
    let may = [makeAsset(id: "may-1"), makeAsset(id: "may-2")]
    let june = [makeAsset(id: "june-1")]
    svc.assetsByYearMonth["2025-5"] = may
    svc.assetsByYearMonth["2025-6"] = june
    for asset in may + june { svc.thumbnailsByAssetId[asset.id] = dummyImage() }

    let vm = MonthViewModel(photoLibraryService: svc)
    await vm.loadAssets(for: .timeline(year: 2025, month: 5))
    await drainBackgroundWork()
    #expect(vm.assets.map(\.id) == ["may-1", "may-2"])

    // Gate the May refresh's fetch so we can navigate to June while it's
    // mid-flight.
    let gate = AsyncCheckpoint()
    svc.fetchAssetsCheckpointByYear[2025] = gate

    async let refreshTask: Void = vm.refresh(for: .timeline(year: 2025, month: 5))
    await gate.waitForEnter(count: 1)
    // While the refresh is suspended at the fetch, navigate to June.
    svc.fetchAssetsCheckpointByYear[2025] = nil
    await vm.loadAssets(for: .timeline(year: 2025, month: 6))
    await drainBackgroundWork()
    #expect(vm.assets.map(\.id) == ["june-1"])

    // Release the gated refresh — its scope guard should make it discard the
    // May payload rather than overwrite June.
    await gate.releaseAll()
    await refreshTask
    await drainBackgroundWork()

    #expect(
      vm.assets.map(\.id) == ["june-1"],
      "stale May refresh must not clobber June after navigation")
  }

  /// Regression: when iCloud lands a new photo, `photoLibraryDidChange` fires
  /// the moment the asset's metadata is available, but PhotoKit's local
  /// thumbnail cache may still be empty for a moment. `refresh(for:)` must
  /// fetch the new asset's thumbnail with `allowNetwork: true` so the tile
  /// fills in immediately; otherwise the asset lands in `failedThumbnailIds`
  /// and the HQ upgrade — gated on that set — can't rescue it, leaving the
  /// user staring at a "Retry" tile until they navigate away and back.
  @Test func refreshUsesNetworkForNewlyArrivedAsset() async throws {
    let svc = FakePhotoLibraryService()
    let existing = makeAsset(id: "existing")
    svc.assetsByYearMonth["2025-6"] = [existing]
    svc.thumbnailsByAssetId[existing.id] = dummyImage()

    let vm = MonthViewModel(photoLibraryService: svc)
    await vm.loadAssets(for: .timeline(year: 2025, month: 6))
    await drainBackgroundWork()

    // Fresh iCloud arrival: thumbnail exists in PhotoKit but the local cache is
    // cold, so an `allowNetwork: false` call would return nil and stamp the
    // asset as failed.
    let fresh = makeAsset(id: "fresh-from-icloud")
    svc.assetsByYearMonth["2025-6"] = [existing, fresh]
    svc.thumbnailsByAssetId[fresh.id] = dummyImage()
    svc.thumbnailRequiresNetwork = [fresh.id]
    svc.loadThumbnailCalls.removeAll()

    await vm.refresh(for: .timeline(year: 2025, month: 6))
    await drainBackgroundWork()

    #expect(vm.assets.map(\.id) == ["existing", "fresh-from-icloud"])
    #expect(
      vm.thumbnailsById[fresh.id] != nil,
      "newly-arrived asset must get its thumbnail without manual retry")
    #expect(!vm.failedThumbnailIds.contains(fresh.id))
    // The added asset was fetched with allowNetwork: true. The existing asset is
    // already in `thumbnailsById` so the loop skips it — no second probe.
    let freshCall = svc.loadThumbnailCalls.first { $0.assetId == fresh.id }
    #expect(freshCall?.allowNetwork == true, "added-asset path must allow network")
  }

  /// User-reported regression: PhotoKit's `fastFormat` thumbnail request can return
  /// `PHPhotosError` 3303 ("no resource found matching image request spec") for
  /// assets that have just synced from iCloud — the asset's metadata is present but
  /// no fast-format render has been built yet. `highQualityFormat` uses a different
  /// pipeline and *does* return an image. The view model must therefore run the HQ
  /// upgrade even when the fast probe failed, and clear `failedThumbnailIds` when
  /// HQ succeeds, so the user doesn't have to click "Retry."
  @Test func hqUpgradeRescuesFastFormatFailureForFreshAsset() async throws {
    let svc = FakePhotoLibraryService()
    let existing = makeAsset(id: "existing")
    svc.assetsByYearMonth["2025-6"] = [existing]
    svc.thumbnailsByAssetId[existing.id] = dummyImage()

    let vm = MonthViewModel(photoLibraryService: svc)
    await vm.loadAssets(for: .timeline(year: 2025, month: 6))
    await drainBackgroundWork()

    // Fresh arrival: PhotoKit has NO fast-format render (thumbnailsByAssetId
    // empty) but DOES have an HQ-format render available. This is the case the
    // user reported on the PR — Retry tile in the grid until they navigate away.
    let fresh = makeAsset(id: "fresh")
    svc.assetsByYearMonth["2025-6"] = [existing, fresh]
    svc.hqThumbnailsByAssetId[fresh.id] = dummyImage()
    // Intentionally NO svc.thumbnailsByAssetId[fresh.id] — fast format fails.

    await vm.refresh(for: .timeline(year: 2025, month: 6))
    await drainBackgroundWork()

    #expect(vm.assets.map(\.id) == ["existing", "fresh"])
    #expect(
      vm.thumbnailsById[fresh.id] != nil,
      "HQ upgrade must rescue the fresh asset after fast failed")
    #expect(
      !vm.failedThumbnailIds.contains(fresh.id),
      "failed flag must be cleared once HQ provides a thumbnail")
    if case .loaded = vm.thumbnailState(for: fresh) {
      // good
    } else {
      Issue.record("fresh asset should render as .loaded after HQ rescue")
    }
  }

  // MARK: - Wrapper: loadAssets(forYear:month:)

  /// The legacy wrapper `loadAssets(forYear:month:)` simply delegates to
  /// `loadAssets(for: .timeline(...))`. Verify both paths produce the same
  /// observable state.
  @Test func legacyWrapperIsEquivalentToScopeBasedLoader() async throws {
    let svc = FakePhotoLibraryService()
    let asset = makeAsset(id: "wrapper")
    svc.assetsByYearMonth["2025-8"] = [asset]
    svc.thumbnailsByAssetId[asset.id] = dummyImage()

    let vm = MonthViewModel(photoLibraryService: svc)
    await vm.loadAssets(forYear: 2025, month: 8)

    #expect(vm.assets.map(\.id) == ["wrapper"])
    #expect(vm.thumbnailsById["wrapper"] != nil)
    #expect(vm.selectedAssetId == "wrapper")
  }
}
