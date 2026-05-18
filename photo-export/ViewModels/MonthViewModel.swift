import AppKit
import Foundation
import Photos
import SwiftUI

@MainActor
final class MonthViewModel: ObservableObject {
  @Published private(set) var assets: [AssetDescriptor] = []
  @Published private(set) var thumbnailsById: [String: NSImage] = [:]
  @Published private(set) var failedThumbnailIds: Set<String> = []
  @Published var isLoading: Bool = false
  @Published var errorMessage: String?

  // Selection is tracked via id to avoid retaining assets strongly across updates
  @Published var selectedAssetId: String?
  @Published private(set) var isExportRunning: Bool = false

  private let photoLibraryService: any PhotoLibraryService

  // Control initial thumbnail batch size
  private let initialThumbnailBatchSize: Int = 40

  // Track cached assets to manage PHCachingImageManager preheating
  private var cachedAssets: [AssetDescriptor] = []

  // Track which thumbnails have been upgraded to high quality
  private var highQualityIds: Set<String> = []

  // Task for background HQ upgrades so we can cancel on month change
  private var hqUpgradeTask: Task<Void, Never>?

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
    thumbnailsById = [:]
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
      var initialThumbs: [String: NSImage] = [:]

      for asset in initialBatch {
        if let thumb = await photoLibraryService.loadThumbnail(
          for: asset.id, allowNetwork: false)
        {
          initialThumbs[asset.id] = thumb
        } else {
          failedThumbnailIds.insert(asset.id)
        }
      }
      thumbnailsById = initialThumbs
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
  /// Unlike `loadAssets(for:)`, this path *does not* blank `assets` or `thumbnailsById`
  /// before fetching. SwiftUI's `ForEach(viewModel.assets, id: \.id)` diffs the new
  /// array against the old one: assets that still exist keep their position and their
  /// already-loaded thumbnails (the thumbnail dict is keyed by asset id), assets that
  /// disappeared drop out, and newly-added assets show as "loading" until the
  /// background loop fills their entry. The visible grid never flashes empty.
  ///
  /// `scope == nil` is a no-op — there's nothing to refresh against.
  func refresh(for scope: PhotoFetchScope?) async {
    guard let scope else { return }
    do {
      let newAssets = try await photoLibraryService.fetchAssets(in: scope, mediaType: nil)
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

      // Drop dict entries for assets that left the scope so we don't hold stale
      // thumbnails for items the grid no longer renders.
      thumbnailsById = thumbnailsById.filter { newIds.contains($0.key) }
      failedThumbnailIds = failedThumbnailIds.filter { newIds.contains($0) }
      highQualityIds = highQualityIds.filter { newIds.contains($0) }

      assets = newAssets

      // Re-arm the background thumbnail loop. The skip-if-already-loaded guards inside
      // `loadAndStoreThumbnail` (checked via the dict here) and
      // `upgradeThumbnailToHighQuality` (its own guard on `highQualityIds`) keep the
      // loop cheap when most assets are unchanged.
      hqUpgradeTask?.cancel()
      hqUpgradeTask = Task { [weak self] in
        guard let self else { return }
        for asset in newAssets {
          guard !Task.isCancelled else { return }
          if self.thumbnailsById[asset.id] == nil,
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
      // Refresh failures shouldn't disrupt the visible grid — leave the existing
      // assets in place and surface the error message for the overlay.
      errorMessage = error.localizedDescription
    }
  }

  func thumbnail(for asset: AssetDescriptor) -> NSImage? {
    thumbnailsById[asset.id]
  }

  func thumbnailState(for asset: AssetDescriptor) -> ThumbnailState {
    let id = asset.id
    if let image = thumbnailsById[id] {
      return .loaded(image)
    } else if failedThumbnailIds.contains(id) {
      return .failed
    } else {
      return .loading
    }
  }

  func retryThumbnail(for assetId: String) {
    failedThumbnailIds.remove(assetId)
    Task { [weak self] in
      guard let self else { return }
      await self.loadAndStoreThumbnail(for: assetId)
      if self.thumbnailsById[assetId] != nil {
        await self.upgradeThumbnailToHighQuality(for: assetId)
      }
    }
  }

  func select(assetId: String?) {
    selectedAssetId = assetId
  }

  func setExportRunning(_ running: Bool) {
    isExportRunning = running
  }

  private func loadAndStoreThumbnail(for assetId: String) async {
    if let thumb = await photoLibraryService.loadThumbnail(
      for: assetId, allowNetwork: false)
    {
      thumbnailsById[assetId] = thumb
    } else {
      failedThumbnailIds.insert(assetId)
    }
  }

  private func upgradeThumbnailToHighQuality(for assetId: String) async {
    guard !highQualityIds.contains(assetId) else { return }
    guard !failedThumbnailIds.contains(assetId) else { return }
    if let hqThumb = await photoLibraryService.loadThumbnailHighQuality(
      for: assetId, allowNetwork: !isExportRunning)
    {
      thumbnailsById[assetId] = hqThumb
      highQualityIds.insert(assetId)
    }
  }
}
