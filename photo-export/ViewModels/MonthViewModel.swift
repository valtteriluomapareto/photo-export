import AppKit
import Foundation
import Photos
import SwiftUI

/// Owns the asset list for a single scope (timeline month, favorites, album).
/// Thumbnail rendering is now cell-driven via `ThumbnailView.task(id:)` against
/// `PhotoLibraryManager.decodedThumbnail`; this view model only manages the
/// asset array and the `PHCachingImageManager` preheat lifecycle.
@MainActor
final class MonthViewModel: ObservableObject {
  @Published private(set) var assets: [AssetDescriptor] = []
  @Published var isLoading: Bool = false
  @Published var errorMessage: String?

  // Selection is tracked via id to avoid retaining assets strongly across updates
  @Published var selectedAssetId: String?

  private let photoLibraryService: any PhotoLibraryService

  // Track cached assets to manage PHCachingImageManager preheating
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
    // Claim the scope *before* the first await so a parallel `refresh(for:)` that's
    // mid-fetch sees the new scope and discards its result instead of overwriting.
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

    do {
      let scopedAssets = try await photoLibraryService.fetchAssets(in: scope, mediaType: nil)
      assets = scopedAssets
      photoLibraryService.startCachingThumbnails(for: scopedAssets)
      cachedAssets = scopedAssets
      isLoading = false

      if let first = scopedAssets.first {
        selectedAssetId = first.id
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
  /// Unlike `loadAssets(for:)`, this path *does not* blank `assets` before fetching.
  /// SwiftUI's `ForEach(viewModel.assets)` diffs the new array against the old one:
  /// assets that still exist keep their position and their cells keep their loaded
  /// thumbnails, assets that disappeared drop out, and newly-added assets show as
  /// "loading" until each cell's `.task` fills its tile. The visible grid never
  /// flashes empty.
  ///
  /// **Scope race.** The trigger is an orphan `Task { await refresh(...) }` fired from
  /// `.onChange(of: libraryRevision)`; if the user navigates mid-fetch, the resumed
  /// refresh would otherwise overwrite the new scope's state. We guard against that by
  /// comparing the requested `scope` against `currentScope` (which `loadAssets` claims
  /// synchronously) right before writing — a mismatch means a navigation happened
  /// during the await and the fetch result is no longer relevant.
  ///
  /// `scope == nil` is a no-op — there's nothing to refresh against.
  func refresh(for scope: PhotoFetchScope?) async {
    guard let scope else { return }
    do {
      let newAssets = try await photoLibraryService.fetchAssets(in: scope, mediaType: nil)
      guard currentScope == scope else { return }
      let newIds = Set(newAssets.map(\.id))
      let removed = cachedAssets.filter { !newIds.contains($0.id) }
      let added = newAssets.filter { asset in
        !cachedAssets.contains(where: { $0.id == asset.id })
      }

      if !removed.isEmpty {
        photoLibraryService.stopCachingThumbnails(for: removed)
      }
      if !added.isEmpty {
        photoLibraryService.startCachingThumbnails(for: added)
      }
      cachedAssets = newAssets
      assets = newAssets
    } catch {
      guard currentScope == scope else { return }
      errorMessage = error.localizedDescription
    }
  }

  func select(assetId: String?) {
    selectedAssetId = assetId
  }
}
