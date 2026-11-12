import AppKit

/// Cover loading has one ordered, bounded path. Cancellation returns no publishable value.
enum CoverTileContent {
  case idle, loading, empty, failed
  case images([CGImage])

  var isIdle: Bool {
    if case .idle = self { return true }
    return false
  }

  var previewHint: String? {
    switch self {
    case .idle, .loading: return "Loading preview"
    case .failed: return "Couldn't load preview"
    case .images, .empty: return nil
    }
  }

  @MainActor
  static func load(
    scope: PhotoFetchScope, service: any PhotoLibraryService, side: CGFloat, displayScale: CGFloat
  ) async -> Self? {
    do {
      let assets = try await service.coverAssets(in: scope, limit: 4)
      try Task.checkCancellation()
      let ids = assets.prefix(4).map(\.id)
      guard !ids.isEmpty else { return .empty }
      let pixelSide = side * max(displayScale, 1)
      let size = CGSize(width: pixelSide, height: pixelSide)
      let images = await withTaskGroup(of: (Int, CGImage?).self) { group in
        for (index, id) in ids.enumerated() {
          group.addTask {
            (
              index,
              await service.decodedThumbnail(
                for: id, quantizedSize: size, deliveryMode: .highQuality)
            )
          }
        }
        var result: [(Int, CGImage)] = []
        for await (index, image) in group {
          if let image { result.append((index, image)) }
        }
        return result.sorted { $0.0 < $1.0 }.map(\.1)
      }
      try Task.checkCancellation()
      return images.isEmpty ? .failed : .images(images)
    } catch is CancellationError {
      return nil
    } catch {
      return Task.isCancelled ? nil : .failed
    }
  }
}
