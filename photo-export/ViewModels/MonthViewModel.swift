import AppKit
import Foundation
import Photos
import SwiftUI

/// Owns the asset list for a single scope (timeline month, favorites, album)
/// and the `PHCachingImageManager` preheat lifecycle. Thumbnail loading
/// itself lives on the cell.
@MainActor
final class MonthViewModel: ObservableObject {
  @Published private(set) var assets: [AssetDescriptor] = []
  @Published var isLoading: Bool = false
  @Published var errorMessage: String?

  // Selection is tracked via id to avoid retaining assets strongly across updates
  @Published var selectedAssetId: String?

  private let photoLibraryService: any PhotoLibraryService

  /// Upper bound on how many assets we hand to `PHCachingImageManager` at once.
  /// `startCachingImages` is designed for the visible window (Apple's sample
  /// code typically caches scores to low hundreds); passing the full scope —
  /// e.g. a 37k-asset Favorites collection — choked the shared caching manager
  /// and stalled every subsequent `requestImage`, so the grid sat on the
  /// spinner forever (issue #109). 500 covers any realistic visible row count
  /// for the 144 pt tile grid with comfortable headroom.
  private let cachingWindowSize: Int = 500

  /// Per-batch chunk handed to `fetchAssetsProgressive`. Bigger batches stutter
  /// the main actor on each commit; smaller batches add per-batch overhead
  /// without measurable UI benefit.
  private let progressiveBatchSize: Int = 200

  /// Assets currently registered with `PHCachingImageManager`. After
  /// `loadAssets`/`refresh` returns, this mirrors the prefix of the active
  /// scope that we passed to `startCachingThumbnails`, capped at
  /// `cachingWindowSize`. `refresh(for:)`'s diff (added/removed) is computed
  /// against this windowed set, not the full scope, so the cache delta stays
  /// bounded.
  private var cachedAssets: [AssetDescriptor] = []

  /// The scope this view model is currently displaying. Written *synchronously* at the
  /// top of `loadAssets(for:)` so any in-flight `refresh(for:)` task can detect a
  /// navigation that happened during its `await` and bail before clobbering the new
  /// scope's state. Reads inside `refresh` use this as the "is what I fetched still
  /// what the user is looking at?" gate.
  private var currentScope: PhotoFetchScope?

  init(photoLibraryService: any PhotoLibraryService) {
    self.photoLibraryService = photoLibraryService
  }

  /// Timeline-scope wrapper kept for the existing `MonthContentView` call site.
  func loadAssets(forYear year: Int, month: Int) async {
    await loadAssets(for: .timeline(year: year, month: month))
  }

  /// Scope-based loader used by both timeline and collection grids. A `nil` scope clears
  /// the view model (used when `LibrarySelection` is nil — e.g. before any collection is
  /// selected).
  func loadAssets(for scope: PhotoFetchScope?) async {
    // Claim the scope *before* the first await so a parallel `refresh(for:)`
    // that's mid-fetch sees the new scope and discards its result instead of
    // overwriting.
    currentScope = scope
    isLoading = true
    errorMessage = nil
    if !cachedAssets.isEmpty {
      photoLibraryService.stopCachingThumbnails(for: cachedAssets)
      cachedAssets = []
    }
    assets = []
    selectedAssetId = nil

    guard let scope else {
      isLoading = false
      return
    }

    let stream = photoLibraryService.fetchAssetsProgressive(
      in: scope, mediaType: nil, batchSize: progressiveBatchSize)
    do {
      for try await batch in stream {
        // Bail if the parent Task was cancelled (the cell scrolled off, the
        // window closed) or if a new scope claimed `currentScope` during the
        // await.
        if Task.isCancelled { return }
        guard currentScope == scope else { return }
        let wasEmpty = assets.isEmpty
        assets.append(contentsOf: batch)
        if wasEmpty {
          isLoading = false
          if let first = batch.first { selectedAssetId = first.id }
        }
      }
    } catch {
      guard currentScope == scope else { return }
      errorMessage = error.localizedDescription
      isLoading = false
      return
    }
    if Task.isCancelled { return }
    if currentScope != scope { return }
    isLoading = false

    // Preheat the windowed prefix once the full asset list has settled.
    let cachingWindow = Array(assets.prefix(cachingWindowSize))
    if !cachingWindow.isEmpty {
      photoLibraryService.startCachingThumbnails(for: cachingWindow)
    }
    cachedAssets = cachingWindow
  }

  /// In-place refresh used when the underlying Photos library changes underneath us
  /// (`PhotoLibraryManager.libraryRevision` bumps after a `photoLibraryDidChange`,
  /// typically from iCloud sync landing new assets or the user editing in Photos.app).
  ///
  /// Does *not* blank `assets` before fetching: `ForEach(viewModel.assets)` diffs
  /// the new array against the old, survivors keep their position and their cells
  /// keep their loaded thumbnails, and newly-added assets show as "loading" until
  /// each cell's `.task` fills its tile. The visible grid never flashes empty.
  ///
  /// Collects the full stream into a local array before committing so partial
  /// state isn't visible mid-refresh; the per-batch scope guard still discards
  /// in-flight batches if the user navigates away.
  ///
  /// `scope == nil` is a no-op.
  func refresh(for scope: PhotoFetchScope?) async {
    guard let scope else { return }
    var collected: [AssetDescriptor] = []
    let stream = photoLibraryService.fetchAssetsProgressive(
      in: scope, mediaType: nil, batchSize: progressiveBatchSize)
    do {
      for try await batch in stream {
        if Task.isCancelled { return }
        guard currentScope == scope else { return }
        collected.append(contentsOf: batch)
      }
    } catch {
      guard currentScope == scope else { return }
      errorMessage = error.localizedDescription
      return
    }
    if Task.isCancelled { return }
    guard currentScope == scope else { return }

    // Window the cache delta the same way `loadAssets` does — diff between
    // the *windowed* prefix of new vs old, not the full scopes. Without this,
    // refreshing a 37k-asset scope where everything is "new to the cache"
    // would funnel the entire scope into `startCachingThumbnails` and
    // re-trigger the choke we're guarding against.
    let newCachingWindow = Array(collected.prefix(cachingWindowSize))
    let newCachedIds = Set(newCachingWindow.map(\.id))
    let oldCachedIds = Set(cachedAssets.map(\.id))
    let added = newCachingWindow.filter { !oldCachedIds.contains($0.id) }
    let removed = cachedAssets.filter { !newCachedIds.contains($0.id) }

    if !removed.isEmpty {
      photoLibraryService.stopCachingThumbnails(for: removed)
    }
    if !added.isEmpty {
      photoLibraryService.startCachingThumbnails(for: added)
    }
    cachedAssets = newCachingWindow
    assets = collected
  }

  func select(assetId: String?) {
    selectedAssetId = assetId
  }
}
