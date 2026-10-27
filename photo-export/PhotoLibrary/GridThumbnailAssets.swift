import Foundation
import SwiftUI

/// Retains the grid's current preheat window; cells retain their own resolved sources.
@MainActor
final class GridThumbnailAssets {
  private let service: any PhotoLibraryService
  private var window: [ThumbnailAsset] = []
  private var isActive = true
  private var preheatTask: Task<Void, Never>?
  private var pendingWindow: [AssetDescriptor]?

  init(service: any PhotoLibraryService) { self.service = service }

  func reset() {
    isActive = true
    _ = scheduleWindow([])
  }

  @discardableResult
  func deactivate() -> Task<Void, Never> {
    isActive = false
    return scheduleWindow([])
  }

  func handle(
    for id: String, revision: Int, isCurrent: @escaping @MainActor () -> Bool
  ) async -> ThumbnailAsset? {
    guard isActive, !Task.isCancelled, isCurrent() else { return nil }
    if let handle = window.first(where: {
      $0.descriptor.id == id && $0.contentRevision == revision
    }) {
      return handle
    }
    let handles = await service.resolveThumbnailAssets(ids: [id])
    guard isActive, !Task.isCancelled, isCurrent(),
      let handle = handles.first(where: { $0.descriptor.id == id })
    else { return nil }
    return handle.withRevision(revision)
  }

  func updateWindow(_ assets: [AssetDescriptor]) async {
    await scheduleWindow(Array(assets.prefix(500))).value
  }

  /// Serial transfers balance registrations even when a lookup finishes after disappearance.
  private func scheduleWindow(_ assets: [AssetDescriptor]) -> Task<Void, Never> {
    pendingWindow = assets
    if let preheatTask { return preheatTask }
    let task = Task { [self] in
      while let assets = pendingWindow {
        pendingWindow = nil
        let handles = await service.resolveThumbnailAssets(ids: assets.map(\.id))
        let next = isActive ? handles : []
        await service.preheatThumbnailAssets(start: next, stop: window)
        window = next
      }
      preheatTask = nil
    }
    preheatTask = task
    return task
  }
}

private struct GridThumbnailAssetsKey: EnvironmentKey {
  static let defaultValue: GridThumbnailAssets? = nil
}

extension EnvironmentValues {
  var gridThumbnailAssets: GridThumbnailAssets? {
    get { self[GridThumbnailAssetsKey.self] }
    set { self[GridThumbnailAssetsKey.self] = newValue }
  }
}
