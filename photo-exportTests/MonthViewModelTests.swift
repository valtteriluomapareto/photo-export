import AppKit
import Foundation
import Photos
import Testing

@testable import Photo_Export

/// `MonthViewModel` is the asset-list driver for both `MonthContentView` and
/// `CollectionContentView`. Since the cell-scoped thumbnail refactor, the
/// view model owns only the asset array, the `PHCachingImageManager`
/// preheat lifecycle, and the scope-race guard — thumbnail loading lives in
/// `ThumbnailView.task(id:)` against `PhotoLibraryManager.decodedThumbnail`.
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

  // MARK: - Initial load

  @Test func loadAssetsPopulatesAssetArray() async throws {
    let svc = FakePhotoLibraryService()
    let assets = (0..<3).map { makeAsset(id: "a\($0)") }
    svc.assetsByYearMonth["2025-6"] = assets

    let vm = MonthViewModel(photoLibraryService: svc)
    await vm.loadAssets(for: .timeline(year: 2025, month: 6))

    #expect(vm.assets.map(\.id) == ["a0", "a1", "a2"])
    #expect(!vm.isLoading)
    #expect(vm.errorMessage == nil)
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
    svc.assetsByYearMonth["2025-1"] = []

    let vm = MonthViewModel(photoLibraryService: svc)
    await vm.loadAssets(for: .timeline(year: 2025, month: 1))

    #expect(vm.assets.isEmpty)
    #expect(vm.selectedAssetId == nil)
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

  /// `PHCachingImageManager.startCachingImages` is meant for a visible-window
  /// sized set. Passing the entire scope choked the shared image manager when
  /// a user had 37k favorites — every subsequent `requestImage` (including the
  /// initial fast batch) stalled, so the grid sat on the spinner forever
  /// (issue #109). The view model now caps the set it hands to the service to
  /// `cachingWindowSize` (500).
  @Test func startCachingThumbnailsIsCappedToWindowForLargeScopes() async throws {
    let svc = FakePhotoLibraryService()
    // 600 assets — well above the 500-window cap.
    let many = (0..<600).map { makeAsset(id: "fav-\($0)") }
    svc.favoritesAssets = many

    let vm = MonthViewModel(photoLibraryService: svc)
    await vm.loadAssets(for: .favorites)

    // All 600 are in the published `assets` array (the grid renders them all,
    // lazily). But the caching call only saw the first 500.
    #expect(vm.assets.count == 600)
    let cachedBatch = svc.startCachingCalls.last
    #expect(cachedBatch?.count == 500)
    #expect(cachedBatch?.first?.id == "fav-0")
    #expect(cachedBatch?.last?.id == "fav-499")
  }

  @Test func nilScopeClearsAllState() async throws {
    let svc = FakePhotoLibraryService()
    let assets = [makeAsset(id: "a"), makeAsset(id: "b")]
    svc.assetsByYearMonth["2025-2"] = assets

    let vm = MonthViewModel(photoLibraryService: svc)
    await vm.loadAssets(for: .timeline(year: 2025, month: 2))
    #expect(!vm.assets.isEmpty)
    #expect(vm.selectedAssetId != nil)

    await vm.loadAssets(for: nil)

    #expect(vm.assets.isEmpty)
    #expect(vm.selectedAssetId == nil)
    #expect(!vm.isLoading)
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

  // MARK: - select

  @Test func selectTogglesSelectedAssetId() async throws {
    let svc = FakePhotoLibraryService()
    let vm = MonthViewModel(photoLibraryService: svc)

    vm.select(assetId: "abc")
    #expect(vm.selectedAssetId == "abc")
    vm.select(assetId: nil)
    #expect(vm.selectedAssetId == nil)
  }

  // MARK: - refresh(for:)

  /// Refresh keeps existing assets in place and adds newcomers without
  /// blanking the grid. Mirrors the iCloud-sync case where the user is
  /// watching a month grid as new photos land in the library. The newcomer
  /// must also be preheated for caching — only the added asset is started,
  /// survivors are not stopped.
  @Test func refreshKeepsExistingAssetsAndAddsNewcomers() async throws {
    let svc = FakePhotoLibraryService()
    let original = (0..<3).map { makeAsset(id: "a\($0)") }
    svc.assetsByYearMonth["2025-6"] = original

    let vm = MonthViewModel(photoLibraryService: svc)
    await vm.loadAssets(for: .timeline(year: 2025, month: 6))
    let startCountBefore = svc.startCachingCalls.count
    let stopCountBefore = svc.stopCachingCalls.count

    let added = makeAsset(id: "a3")
    svc.assetsByYearMonth["2025-6"] = original + [added]
    await vm.refresh(for: .timeline(year: 2025, month: 6))

    #expect(vm.assets.map(\.id) == ["a0", "a1", "a2", "a3"])
    #expect(svc.startCachingCalls.count == startCountBefore + 1)
    #expect(svc.startCachingCalls.last?.map(\.id) == ["a3"])
    #expect(svc.stopCachingCalls.count == stopCountBefore)
  }

  /// Assets that disappear from the library are removed from `assets` and
  /// their `PHCachingImageManager` preheat is stopped.
  @Test func refreshPrunesRemovedAssets() async throws {
    let svc = FakePhotoLibraryService()
    let keep = makeAsset(id: "keep")
    let drop = makeAsset(id: "drop")
    svc.assetsByYearMonth["2025-7"] = [keep, drop]

    let vm = MonthViewModel(photoLibraryService: svc)
    await vm.loadAssets(for: .timeline(year: 2025, month: 7))
    let stopCountBefore = svc.stopCachingCalls.count

    svc.assetsByYearMonth["2025-7"] = [keep]
    await vm.refresh(for: .timeline(year: 2025, month: 7))

    #expect(vm.assets.map(\.id) == ["keep"])
    #expect(svc.stopCachingCalls.count == stopCountBefore + 1)
    #expect(svc.stopCachingCalls.last?.map(\.id) == ["drop"])
  }

  /// `refresh(for: nil)` is a no-op — the view model retains whatever it was
  /// already displaying.
  @Test func refreshNilScopeIsNoOp() async throws {
    let svc = FakePhotoLibraryService()
    let assets = [makeAsset(id: "x")]
    svc.assetsByYearMonth["2025-1"] = assets

    let vm = MonthViewModel(photoLibraryService: svc)
    await vm.loadAssets(for: .timeline(year: 2025, month: 1))
    let assetsBefore = vm.assets

    await vm.refresh(for: nil)

    #expect(vm.assets.map(\.id) == assetsBefore.map(\.id))
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

    let vm = MonthViewModel(photoLibraryService: svc)
    await vm.loadAssets(for: .timeline(year: 2025, month: 5))
    #expect(vm.assets.map(\.id) == ["may-1", "may-2"])

    let gate = AsyncCheckpoint()
    svc.fetchAssetsCheckpointByYear[2025] = gate

    async let refreshTask: Void = vm.refresh(for: .timeline(year: 2025, month: 5))
    await gate.waitForEnter(count: 1)
    svc.fetchAssetsCheckpointByYear[2025] = nil
    await vm.loadAssets(for: .timeline(year: 2025, month: 6))
    #expect(vm.assets.map(\.id) == ["june-1"])

    await gate.releaseAll()
    await refreshTask

    #expect(
      vm.assets.map(\.id) == ["june-1"],
      "stale May refresh must not clobber June after navigation")
  }

  /// Grow-without-replacement: scope expands from 600 → 700 by appending
  /// 100 assets past the caching window. The windowed prefix is unchanged,
  /// so refresh must not re-invoke `startCachingThumbnails` (the very
  /// regression that motivated the cap — funnelling tens of thousands of
  /// assets back through PHCachingImageManager).
  @Test func refreshDoesNotRetriggerCachingWhenWindowedPrefixIsUnchanged() async throws {
    let svc = FakePhotoLibraryService()
    let initial = (0..<600).map { makeAsset(id: "a\($0)") }
    svc.favoritesAssets = initial

    let vm = MonthViewModel(photoLibraryService: svc)
    await vm.loadAssets(for: .favorites)
    let startCachingCountAfterLoad = svc.startCachingCalls.count

    let appended = (600..<700).map { makeAsset(id: "a\($0)") }
    svc.favoritesAssets = initial + appended

    await vm.refresh(for: .favorites)

    #expect(vm.assets.count == 700)
    #expect(
      svc.startCachingCalls.count == startCachingCountAfterLoad,
      "windowed prefix unchanged → no second startCachingThumbnails call")
    #expect(svc.stopCachingCalls.isEmpty)
  }

  /// Refresh into an empty scope must stop caching for the prior window
  /// without crashing on `prefix(500)` of `[]`.
  @Test func refreshIntoEmptyScopeStopsAllPriorCachingWithoutPanic() async throws {
    let svc = FakePhotoLibraryService()
    let initial = [makeAsset(id: "a"), makeAsset(id: "b")]
    svc.favoritesAssets = initial

    let vm = MonthViewModel(photoLibraryService: svc)
    await vm.loadAssets(for: .favorites)
    let stopCachingCountAfterLoad = svc.stopCachingCalls.count

    svc.favoritesAssets = []
    await vm.refresh(for: .favorites)

    #expect(vm.assets.isEmpty)
    #expect(svc.stopCachingCalls.count == stopCachingCountAfterLoad + 1)
    #expect(svc.stopCachingCalls.last?.map(\.id) == ["a", "b"])
  }


  // MARK: - Progressive streaming

  /// Mid-stream scope switch: the user clicks album B while album A's
  /// progressive fetch has only delivered its first batch. The remaining
  /// batches from A must not bleed into the assets array after B's load
  /// completes.
  @Test func loadAssetsDiscardsLateBatchesAfterScopeSwitch() async throws {
    let svc = FakePhotoLibraryService()
    // Two scopes, each with enough assets for multiple batches at size 200.
    let albumA = (0..<500).map { makeAsset(id: "a-\($0)") }
    let albumB = [makeAsset(id: "b-0"), makeAsset(id: "b-1")]
    svc.assetsByAlbumLocalId["A"] = albumA
    svc.assetsByAlbumLocalId["B"] = albumB

    // Gate every batch of A on a checkpoint so the test can interleave a
    // scope switch between batches.
    let gate = AsyncCheckpoint()
    svc.progressiveCheckpointByScopeKey["album:A"] = gate

    let vm = MonthViewModel(photoLibraryService: svc)
    async let loadA: Void = vm.loadAssets(for: .album(collectionId: "A"))

    // First batch arrives.
    await gate.waitForEnter(count: 1)
    await gate.release(1)
    // Second batch arrives.
    await gate.waitForEnter(count: 2)

    // Switch to album B while A's third batch is suspended on the gate.
    await vm.loadAssets(for: .album(collectionId: "B"))

    // Let any further A-batch attempts drain.
    await gate.releaseAll()
    await loadA

    #expect(
      vm.assets.map(\.id) == ["b-0", "b-1"],
      "stale batches from album A must not survive the scope switch")
  }

  /// Refresh during a progressive fetch must collect the entire new scope
  /// before committing, so partial state isn't visible. With a 700-asset
  /// scope (4 batches at size 200), the assets array still flips atomically
  /// once the stream finishes.
  @Test func refreshCommitsCollectedAssetsAtomically() async throws {
    let svc = FakePhotoLibraryService()
    let initial = (0..<700).map { makeAsset(id: "a\($0)") }
    svc.favoritesAssets = initial

    let vm = MonthViewModel(photoLibraryService: svc)
    await vm.loadAssets(for: .favorites)
    let countAfterLoad = vm.assets.count

    // Append 50 new assets at the tail.
    let appended = (700..<750).map { makeAsset(id: "a\($0)") }
    svc.favoritesAssets = initial + appended
    await vm.refresh(for: .favorites)

    #expect(countAfterLoad == 700)
    #expect(vm.assets.count == 750)
    #expect(vm.assets.last?.id == "a749")
  }

  // MARK: - Wrapper: loadAssets(forYear:month:)

  @Test func legacyWrapperIsEquivalentToScopeBasedLoader() async throws {
    let svc = FakePhotoLibraryService()
    let asset = makeAsset(id: "wrapper")
    svc.assetsByYearMonth["2025-8"] = [asset]

    let vm = MonthViewModel(photoLibraryService: svc)
    await vm.loadAssets(forYear: 2025, month: 8)

    #expect(vm.assets.map(\.id) == ["wrapper"])
    #expect(vm.selectedAssetId == "wrapper")
  }
}
