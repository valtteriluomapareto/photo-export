import Foundation
import SwiftUI

/// Retains only the grid's preheat window; outstanding decodes retain their own source.
@MainActor
final class GridThumbnailAssets {
  private struct Entry {
    let handle: ThumbnailAsset
    let revision: Int
  }
  private let service: any PhotoLibraryService
  private var entries: [String: Entry] = [:]
  private var registered: [String: Entry] = [:]
  private var registeredOrder: [String] = []
  private var desired: Set<String> = []
  private var scopeGeneration = 0
  private var registeredScope = 0
  private var windowGeneration = 0
  private var isActive = true
  private var preheatTask: Task<Void, Never>?

  init(service: any PhotoLibraryService) { self.service = service }

  func reset() {
    scopeGeneration &+= 1
    isActive = true
    entries.removeAll()
    _ = scheduleWindow([])
  }

  @discardableResult
  func deactivate() -> Task<Void, Never> {
    scopeGeneration &+= 1
    isActive = false
    entries.removeAll()
    return scheduleWindow([])
  }

  func handle(
    for id: String, revision: Int, isCurrent: @escaping @MainActor () -> Bool
  ) async -> ThumbnailAsset? {
    guard isActive, !Task.isCancelled, isCurrent() else { return nil }
    if let entry = entries[id], entry.revision == revision { return entry.handle }
    let owner = scopeGeneration
    let handles = await service.resolveThumbnailAssets(ids: [id])
    guard owner == scopeGeneration, isActive, !Task.isCancelled, isCurrent(),
      let handle = handles.first(where: { $0.descriptor.id == id })
    else { return nil }
    let current = handle.withRevision(revision)
    if desired.contains(id) { entries[id] = Entry(handle: current, revision: revision) }
    return current
  }

  func updateWindow(_ assets: [AssetDescriptor]) async {
    await scheduleWindow(assets).value
  }

  /// The chain balances physical registrations even if a newer scope arrives during a lookup.
  private func scheduleWindow(_ assets: [AssetDescriptor]) -> Task<Void, Never> {
    windowGeneration &+= 1
    let window = windowGeneration
    let scope = scopeGeneration
    let assets = Array(assets.prefix(500))
    desired = Set(assets.map(\.id))
    entries = entries.filter { desired.contains($0.key) }
    let previous = preheatTask
    let task = Task { [self] in
      await previous?.value
      guard window == windowGeneration, scope == scopeGeneration else { return }
      let revisions = Dictionary(
        uniqueKeysWithValues: assets.map {
          ($0.id, service.thumbnailContentRevision(for: $0.id))
        })
      let missing = assets.filter { entries[$0.id]?.revision != revisions[$0.id] }
      let resolved = await service.resolveThumbnailAssets(ids: missing.map(\.id))
      guard window == windowGeneration, scope == scopeGeneration else { return }
      for handle in resolved {
        let id = handle.descriptor.id
        guard let revision = revisions[id], revision == service.thumbnailContentRevision(for: id)
        else { continue }
        entries[id] = Entry(handle: handle.withRevision(revision), revision: revision)
      }
      let next = isActive ? entries.filter { desired.contains($0.key) } : [:]
      let removed = registeredOrder.compactMap { id -> ThumbnailAsset? in
        guard let entry = registered[id],
          next[id]?.revision != entry.revision || registeredScope != scope
        else { return nil }
        return entry.handle
      }
      let added = assets.compactMap { asset -> ThumbnailAsset? in
        guard let entry = next[asset.id],
          registered[asset.id]?.revision != entry.revision || registeredScope != scope
        else { return nil }
        return entry.handle
      }
      await service.preheatThumbnailAssets(start: added, stop: removed)
      registered = next
      registeredOrder = assets.map(\.id).filter { next[$0] != nil }
      registeredScope = scope
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
