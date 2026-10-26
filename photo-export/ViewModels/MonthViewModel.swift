import AppKit
import Combine
import Foundation
import Observation
import Photos
import SwiftUI

/// Owns the asset list for a single scope (timeline month, favorites, album)
/// and the `PHCachingImageManager` preheat lifecycle. Thumbnail loading
/// itself lives on the cell.
@Observable
@MainActor
final class MonthViewModel {
  private(set) var assets: [AssetDescriptor] = []
  var isLoading: Bool = false
  var errorMessage: String?

  // Selection is tracked via id to avoid retaining assets strongly across updates
  var selectedAssetId: String?

  @ObservationIgnored private let photoLibraryService: any PhotoLibraryService
  @ObservationIgnored let thumbnailAssets: GridThumbnailAssets
  @ObservationIgnored private var visibleAssetIDs: [String]?
  @ObservationIgnored private var assetIndices: [String: Int] = [:]

  /// Bounds initial warm-up and visible-window padding even in an unusually large viewport.
  private let cachingWindowSize: Int = 500

  /// Per-batch chunk handed to `fetchAssetsProgressive`. Bigger batches stutter
  /// the main actor on each commit; smaller batches add per-batch overhead
  /// without measurable UI benefit.
  private let progressiveBatchSize: Int = 200

  /// The displayed scope and its request owner. Scope alone cannot distinguish
  /// two overlapping requests for the same scope, including A → B → A navigation.
  @ObservationIgnored private var currentScope: PhotoFetchScope?
  @ObservationIgnored private var requestGeneration: UInt64 = 0
  @ObservationIgnored private var requestIsCurrent: @MainActor () -> Bool = { true }
  // isLoading ends at the first batch; only a complete snapshot proves absence.
  private(set) var hasCompleteSnapshot = false

  struct SelectionUpdate {
    let asset: AssetDescriptor?
  }

  // Emit after committing both selection and assets so consumers see a coherent snapshot.
  // The payloadless event is not another owner of selection or asset data.
  @ObservationIgnored private let selectionChanges = PassthroughSubject<Void, Never>()
  var selectionUpdates: AnyPublisher<Void, Never> { selectionChanges.eraseToAnyPublisher() }

  private func ownsRequest(_ generation: UInt64, scope: PhotoFetchScope) -> Bool {
    !Task.isCancelled && requestGeneration == generation && currentScope == scope
      && requestIsCurrent()
  }

  init(photoLibraryService: any PhotoLibraryService) {
    self.photoLibraryService = photoLibraryService
    thumbnailAssets = GridThumbnailAssets(service: photoLibraryService)
  }

  /// A disappearing grid relinquishes both its requests and preheat registrations.
  /// Reloading on appearance activates the scope again; late responses stay stale.
  @discardableResult
  func deactivate() -> Task<Void, Never> {
    requestGeneration &+= 1
    currentScope = nil
    hasCompleteSnapshot = false
    let stopped = stopPreheating()
    isLoading = false
    return stopped
  }

  @discardableResult
  private func stopPreheating() -> Task<Void, Never> {
    return thumbnailAssets.deactivate()
  }

  func updateVisibleAssetIDs(_ ids: [String]) async {
    guard currentScope != nil else { return }
    visibleAssetIDs = ids
    let window = cachingWindow(in: assets, indices: assetIndices)
    await thumbnailAssets.updateWindow(window)
  }

  private func cachingWindow(in assets: [AssetDescriptor], indices: [String: Int])
    -> [AssetDescriptor]
  {
    guard let visibleAssetIDs else { return Array(assets.prefix(cachingWindowSize)) }
    let visible = visibleAssetIDs.compactMap { indices[$0] }
    guard let first = visible.min(), let last = visible.max() else { return [] }
    let start = max(0, first - 24)
    let end = min(assets.count, min(last + 25, start + cachingWindowSize))
    return Array(assets[start..<end])
  }

  /// Timeline-scope wrapper kept for the existing `MonthContentView` call site.
  func loadAssets(
    forYear year: Int, month: Int, isCurrent: @escaping @MainActor () -> Bool = { true }
  ) async {
    await loadAssets(for: .timeline(year: year, month: month), isCurrent: isCurrent)
  }

  /// Scope-based loader used by both timeline and collection grids. A `nil` scope clears
  /// the view model (used when `LibrarySelection` is nil — e.g. before any collection is
  /// selected).
  func loadAssets(
    for scope: PhotoFetchScope?, isCurrent: @escaping @MainActor () -> Bool = { true }
  ) async {
    guard !Task.isCancelled, isCurrent() else { return }
    requestIsCurrent = isCurrent
    // Claim ownership before the first await, even when navigating back to a
    // scope whose older request is still in flight.
    requestGeneration &+= 1
    let generation = requestGeneration
    currentScope = scope
    hasCompleteSnapshot = false
    isLoading = true
    errorMessage = nil
    stopPreheating()
    thumbnailAssets.reset()
    visibleAssetIDs = nil
    assetIndices = [:]
    assets = []
    selectedAssetId = nil

    guard let scope else {
      await thumbnailAssets.updateWindow([])
      isLoading = false
      return
    }

    let stream = photoLibraryService.fetchAssetsProgressive(
      in: scope, mediaType: nil, batchSize: progressiveBatchSize)
    do {
      for try await batch in stream {
        guard ownsRequest(generation, scope: scope) else { return }
        let wasEmpty = assets.isEmpty
        let start = assets.count
        assets.append(contentsOf: batch)
        for index in start..<assets.count { assetIndices[assets[index].id] = index }
        if wasEmpty {
          isLoading = false
          if selectedAssetId == nil, let first = batch.first { selectedAssetId = first.id }
        }
        selectionChanges.send()
      }
    } catch {
      guard ownsRequest(generation, scope: scope) else { return }
      errorMessage = error.localizedDescription
      isLoading = false
      return
    }
    guard ownsRequest(generation, scope: scope) else { return }
    hasCompleteSnapshot = true
    isLoading = false

    // Preheat the windowed prefix once the full asset list has settled.
    let window = cachingWindow(in: assets, indices: assetIndices)
    await thumbnailAssets.updateWindow(window)
    guard ownsRequest(generation, scope: scope) else { return }
    selectionChanges.send()
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
  func refresh(for scope: PhotoFetchScope?, isCurrent: @escaping @MainActor () -> Bool = { true })
    async
  {
    guard !Task.isCancelled, isCurrent(), let scope, currentScope == scope else { return }
    requestIsCurrent = isCurrent
    requestGeneration &+= 1
    let generation = requestGeneration
    var collected: [AssetDescriptor] = []
    let stream = photoLibraryService.fetchAssetsProgressive(
      in: scope, mediaType: nil, batchSize: progressiveBatchSize)
    do {
      for try await batch in stream {
        guard ownsRequest(generation, scope: scope) else { return }
        collected.append(contentsOf: batch)
      }
    } catch {
      guard ownsRequest(generation, scope: scope) else { return }
      errorMessage = error.localizedDescription
      isLoading = false
      return
    }
    guard ownsRequest(generation, scope: scope) else { return }

    let indices = Dictionary(
      uniqueKeysWithValues: collected.enumerated().map { ($0.element.id, $0.offset) })
    let window = cachingWindow(in: collected, indices: indices)
    await thumbnailAssets.updateWindow(window)
    guard ownsRequest(generation, scope: scope) else { return }
    assetIndices = indices
    hasCompleteSnapshot = true
    if assets != collected { assets = collected }
    errorMessage = nil
    isLoading = false
    if !collected.contains(where: { $0.id == selectedAssetId }) {
      selectedAssetId = collected.first?.id
    }
    selectionChanges.send()
  }

  /// Returns a selection only when the requested view scope still owns the
  /// model and the selected asset is present in its current snapshot.
  func selectedAsset(for scope: PhotoFetchScope) -> AssetDescriptor? {
    guard currentScope == scope, let selectedAssetId else { return nil }
    return assets.first { $0.id == selectedAssetId }
  }

  /// Nil means this pane has no authoritative update. A snapshot containing a nil
  /// asset means an owned, completed empty scope and deliberately clears details.
  /// The binding may be ahead of the model (a click during a held refresh/load).
  func selectionUpdate(
    for scope: PhotoFetchScope, preferredAssetId: String?
  ) -> SelectionUpdate? {
    guard currentScope == scope else { return nil }
    let selected: AssetDescriptor?
    if let preferredAssetId, let preferred = assets.first(where: { $0.id == preferredAssetId }) {
      selected = preferred
    } else {
      // A later progressive batch may still contain the bound selection.
      guard hasCompleteSnapshot || (preferredAssetId == nil && !assets.isEmpty) else { return nil }
      selected =
        preferredAssetId == nil ? (selectedAsset(for: scope) ?? assets.first) : assets.first
    }
    return SelectionUpdate(asset: selected)
  }

  func select(assetId: String?) {
    selectedAssetId = assetId
  }
}

/// Selection is read by tiles and details without invalidating the window's layout owner.
@Observable
@MainActor
final class AssetSelectionModel {
  var asset: AssetDescriptor?
}
