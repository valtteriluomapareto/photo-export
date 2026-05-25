import AppKit
import Foundation
import Photos
import SwiftUI

@MainActor
final class MonthViewModel: ObservableObject {
  @Published private(set) var assets: [AssetDescriptor] = []
  /// Ids whose thumbnail has been successfully fetched into the
  /// `DecodedThumbnailCache` since the current scope loaded. Drives
  /// `thumbnailState(for:)` — the actual `CGImage` lives in the cache, not
  /// here, so the per-scope memory footprint is bounded by `NSCache` limits
  /// rather than scaling with how many scopes the user has visited.
  @Published private(set) var loadedThumbnailIds: Set<String> = []
  @Published private(set) var failedThumbnailIds: Set<String> = []
  @Published var isLoading: Bool = false
  @Published var errorMessage: String?

  // Selection is tracked via id to avoid retaining assets strongly across updates
  @Published var selectedAssetId: String?
  @Published private(set) var isExportRunning: Bool = false

  private let photoLibraryService: any PhotoLibraryService

  /// Display-pixel target for the grid thumbnails. Quantized to a single
  /// bucket so the cache key for a given asset stays stable across grid
  /// reuse. 256×256 covers 120pt tiles at 2× retina with a small margin.
  private let gridThumbnailSize = CGSize(width: 256, height: 256)

  // Control initial thumbnail batch size
  private let initialThumbnailBatchSize: Int = 40

  // Track cached assets to manage PHCachingImageManager preheating
  private var cachedAssets: [AssetDescriptor] = []

  // Track which thumbnails have been upgraded to high quality
  private var highQualityIds: Set<String> = []

  // Task for background HQ upgrades so we can cancel on month change
  private var hqUpgradeTask: Task<Void, Never>?

  /// The scope this view model is currently displaying. Written *synchronously* at the
  /// top of `loadAssets(for:)` so any in-flight `refresh(for:)` task can detect a
  /// navigation that happened during its `await` and bail before clobbering the new
  /// scope's state. Reads inside `refresh` use this as the "is what I fetched still
  /// what the user is looking at?" gate.
  private var currentScope: PhotoFetchScope?

  init(photoLibraryService: any PhotoLibraryService) {
    self.photoLibraryService = photoLibraryService
  }

  /// Timeline-scope wrapper. Phase 4 keeps it as the call site for the existing
  /// `MonthContentView`; new collection views call `loadAssets(for:)` directly. Both
  /// paths share `loadAssets(for:)` for caching/preheat behavior.
  func loadAssets(forYear year: Int, month: Int) async {
    await loadAssets(for: .timeline(year: year, month: month))
  }

  /// Scope-based loader used by both timeline and collection grids. A `nil` scope clears
  /// the view model (used when `LibrarySelection` is nil — e.g. before any collection is
  /// selected).
  func loadAssets(for scope: PhotoFetchScope?) async {
    // Claim the scope *before* the first await so a parallel `refresh(for:)` that's
    // mid-fetch sees the new scope and discards its result instead of overwriting.
    currentScope = scope
    isLoading = true
    errorMessage = nil
    // Cancel any in-flight HQ upgrade work
    hqUpgradeTask?.cancel()
    hqUpgradeTask = nil
    // Stop caching for previous scope
    if !cachedAssets.isEmpty {
      photoLibraryService.stopCachingThumbnails(for: cachedAssets)
      cachedAssets = []
    }
    assets = []
    loadedThumbnailIds = []
    failedThumbnailIds = []
    highQualityIds = []
    selectedAssetId = nil

    guard let scope else {
      isLoading = false
      return
    }

    do {
      let scopedAssets = try await photoLibraryService.fetchAssets(in: scope, mediaType: nil)
      assets = scopedAssets
      // Start caching for new scope
      photoLibraryService.startCachingThumbnails(for: scopedAssets)
      cachedAssets = scopedAssets

      // Preload an initial batch of fast thumbnails
      let initialBatch = Array(scopedAssets.prefix(initialThumbnailBatchSize))
      var initialLoaded = Set<String>()

      for asset in initialBatch {
        if await photoLibraryService.decodedThumbnail(
          for: asset.id, quantizedSize: gridThumbnailSize, deliveryMode: .fast) != nil
        {
          initialLoaded.insert(asset.id)
        } else {
          failedThumbnailIds.insert(asset.id)
        }
      }
      loadedThumbnailIds = initialLoaded
      isLoading = false

      // Auto-select first asset if available
      if let first = scopedAssets.first {
        selectedAssetId = first.id
      }

      // Load remaining fast thumbnails in background, then upgrade all to HQ
      hqUpgradeTask = Task { [weak self] in
        guard let self else { return }
        // First: load fast thumbnails for remaining assets
        for asset in scopedAssets.dropFirst(self.initialThumbnailBatchSize) {
          guard !Task.isCancelled else { return }
          await self.loadAndStoreThumbnail(for: asset.id)
        }
        // Then: upgrade all to high quality
        for asset in scopedAssets {
          guard !Task.isCancelled else { return }
          await self.upgradeThumbnailToHighQuality(for: asset.id)
        }
      }
    } catch {
      errorMessage = error.localizedDescription
      isLoading = false
    }
  }

  /// In-place refresh used when the underlying Photos library changes underneath us
  /// (`PhotoLibraryManager.libraryRevision` bumps after a `photoLibraryDidChange`,
  /// typically from iCloud sync landing new assets or the user editing in Photos.app).
  ///
  /// Unlike `loadAssets(for:)`, this path *does not* blank `assets` or
  /// `loadedThumbnailIds` before fetching. SwiftUI's `ForEach(viewModel.assets)` diffs
  /// the new array against the old one: assets that still exist keep their position
  /// and their already-cached thumbnails, assets that disappeared drop out, and
  /// newly-added assets show as "loading" until the background loop fills their entry.
  /// The visible grid never flashes empty.
  ///
  /// **Scope race.** The trigger is an orphan `Task { await refresh(...) }` fired from
  /// `.onChange(of: libraryRevision)`; if the user navigates mid-fetch, the resumed
  /// refresh would otherwise overwrite the new scope's state. We guard against that by
  /// comparing the requested `scope` against `currentScope` (which `loadAssets` claims
  /// synchronously) right before writing — a mismatch means a navigation happened
  /// during the await and the fetch result is no longer relevant.
  ///
  /// `scope == nil` is a no-op — there's nothing to refresh against.
  ///
  /// **Error visibility.** Surface `errorMessage` on failure so a stalled iCloud
  /// refresh is at least debuggable; deliberately leaves `isLoading` alone so a
  /// populated grid doesn't flash a loading overlay when the user can't act on it.
  func refresh(for scope: PhotoFetchScope?) async {
    guard let scope else { return }
    do {
      let newAssets = try await photoLibraryService.fetchAssets(in: scope, mediaType: nil)
      // Bail if the user (or another refresh) replaced the active scope while we were
      // awaiting the fetch. Writing now would clobber a freshly-loaded different scope.
      guard currentScope == scope else { return }
      let newIds = Set(newAssets.map(\.id))
      let oldIds = Set(cachedAssets.map(\.id))
      let added = newAssets.filter { !oldIds.contains($0.id) }
      let removed = cachedAssets.filter { !newIds.contains($0.id) }

      if !removed.isEmpty {
        photoLibraryService.stopCachingThumbnails(for: removed)
      }
      if !added.isEmpty {
        photoLibraryService.startCachingThumbnails(for: added)
      }
      cachedAssets = newAssets

      // Drop set entries for assets that left the scope so we don't claim "loaded"
      // for items the grid no longer renders.
      loadedThumbnailIds = loadedThumbnailIds.intersection(newIds)
      failedThumbnailIds = failedThumbnailIds.intersection(newIds)
      highQualityIds = highQualityIds.intersection(newIds)

      assets = newAssets

      // Re-arm the background thumbnail loop. The skip-if-already-loaded guards inside
      // `loadAndStoreThumbnail` (checked via `loadedThumbnailIds`) and
      // `upgradeThumbnailToHighQuality` (its own guard on `highQualityIds`) keep the
      // loop cheap when most assets are unchanged.
      //
      // Newly-added assets are likely fresh from iCloud — PhotoKit fires
      // `photoLibraryDidChange` once the asset's metadata lands, but the decoded cache
      // is still empty for them. The fast probe issued via `decodedThumbnail` will
      // either land an entry or surface a failure that the HQ upgrade can still rescue.
      hqUpgradeTask?.cancel()
      hqUpgradeTask = Task { [weak self] in
        guard let self else { return }
        for asset in newAssets {
          guard !Task.isCancelled else { return }
          if !self.loadedThumbnailIds.contains(asset.id),
            !self.failedThumbnailIds.contains(asset.id)
          {
            await self.loadAndStoreThumbnail(for: asset.id)
          }
        }
        for asset in newAssets {
          guard !Task.isCancelled else { return }
          await self.upgradeThumbnailToHighQuality(for: asset.id)
        }
      }
    } catch {
      // Same scope-guard so a late-arriving error from a stale fetch doesn't show on
      // the new scope's UI.
      guard currentScope == scope else { return }
      errorMessage = error.localizedDescription
    }
  }

  /// Synchronous probe of the decoded-thumbnail cache. Returns `.loaded` only
  /// when the cache still holds an entry for the asset; an evicted entry
  /// surfaces as `.loading` and the background loop will refetch.
  func thumbnailState(for asset: AssetDescriptor) -> ThumbnailState {
    let id = asset.id
    if loadedThumbnailIds.contains(id) {
      if let image = photoLibraryService.cachedDecodedThumbnail(
        for: id, quantizedSize: gridThumbnailSize, deliveryMode: .highQuality)
        ?? photoLibraryService.cachedDecodedThumbnail(
          for: id, quantizedSize: gridThumbnailSize, deliveryMode: .fast)
      {
        return .loaded(image)
      }
      return .loading
    }
    if failedThumbnailIds.contains(id) {
      return .failed
    }
    return .loading
  }

  func retryThumbnail(for assetId: String) {
    failedThumbnailIds.remove(assetId)
    highQualityIds.remove(assetId)
    loadedThumbnailIds.remove(assetId)
    Task { [weak self] in
      guard let self else { return }
      // Explicit user retry — try both delivery modes. The fast pipeline can
      // return `PHPhotosError` 3303 for freshly-arrived iCloud assets while HQ
      // returns a valid render; treating retry as "try everything" means the
      // user only needs to click once.
      await self.loadAndStoreThumbnail(for: assetId)
      await self.upgradeThumbnailToHighQuality(for: assetId)
    }
  }

  func select(assetId: String?) {
    selectedAssetId = assetId
  }

  func setExportRunning(_ running: Bool) {
    isExportRunning = running
  }

  /// Initial-load and second-batch fast-thumbnail fetch. Reads through the
  /// decoded-thumbnail cache; the underlying decode path handles
  /// `allowNetwork` (currently always enabled at the cache decode level).
  private func loadAndStoreThumbnail(for assetId: String) async {
    if await photoLibraryService.decodedThumbnail(
      for: assetId, quantizedSize: gridThumbnailSize, deliveryMode: .fast) != nil
    {
      loadedThumbnailIds.insert(assetId)
    } else {
      failedThumbnailIds.insert(assetId)
    }
  }

  /// Upgrade an asset's thumbnail to high quality. Runs even when the fast probe
  /// previously failed (`failedThumbnailIds` contains it) — PhotoKit's fast/HQ
  /// pipelines are independent, and freshly-arrived iCloud assets routinely fail
  /// `fastFormat` with `PHPhotosError` 3303 while `highQualityFormat` returns a
  /// valid render. Clearing `failedThumbnailIds` on success makes the grid drop the
  /// "Retry" tile silently once HQ rescues it.
  private func upgradeThumbnailToHighQuality(for assetId: String) async {
    guard !highQualityIds.contains(assetId) else { return }
    if await photoLibraryService.decodedThumbnail(
      for: assetId, quantizedSize: gridThumbnailSize, deliveryMode: .highQuality) != nil
    {
      loadedThumbnailIds.insert(assetId)
      highQualityIds.insert(assetId)
      failedThumbnailIds.remove(assetId)
    }
  }
}
