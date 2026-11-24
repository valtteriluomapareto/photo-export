import Foundation
import Photos
import Synchronization

/// Owns a serial utility boundary for thumbnail resolution, requests and raster work.
final class ProductionThumbnailReader: ThumbnailReading {
  private let io: any DestinationIOExecuting
  private let backend: any PhotoKitThumbnailBackend
  private let registrations = Mutex(ThumbnailPreheatRegistrations<ThumbnailAsset>())

  init(
    io: any DestinationIOExecuting = DestinationIO(
      queue: DispatchQueue(label: "photo-export.thumbnails", qos: .utility)),
    backend: any PhotoKitThumbnailBackend = ProductionThumbnailBackend()
  ) {
    self.io = io
    self.backend = backend
  }

  func resolveAssets(ids: [String]) async -> [ThumbnailAsset] {
    guard !Task.isCancelled else { return [] }
    return await io.run { [backend] in autoreleasepool { backend.resolveAssets(ids: ids) } }
  }

  func coverThumbnails(in scope: PhotoFetchScope, limit: Int) async throws -> [ThumbnailAsset] {
    try Task.checkCancellation()
    let handles = await io.run { [backend] in
      autoreleasepool {
        let options = PhotoLibraryManager.fetchOptions(for: scope)
        options.fetchLimit = max(1, min(limit, 4))
        return Array(backend.coverAssets(in: scope, options: options).prefix(options.fetchLimit))
      }
    }
    try Task.checkCancellation()
    return handles
  }

  func preheat(start: [ThumbnailAsset], stop: [ThumbnailAsset]) async {
    await io.run { [self] in
      let spec = ThumbnailRequestSpec(size: ThumbnailRequestSpec.gridSize, delivery: .fast)
      let changes = registrations.withLock { registrations in
        let lookup = Dictionary(
          start.map { ($0.preheatKey, $0) }, uniquingKeysWith: { _, last in last })
        let starting = registrations.register(start.map(\.preheatKey)) { lookup[$0] }
        let stopping = registrations.release(stop.map(\.preheatKey))
        return (starting, stopping)
      }
      if !changes.1.isEmpty {
        backend.stopCaching(
          assets: changes.1, size: spec.size, mode: spec.contentMode, options: spec.options())
      }
      if !changes.0.isEmpty {
        backend.startCaching(
          assets: changes.0, size: spec.size, mode: spec.contentMode, options: spec.options())
      }
    }
  }

  func image(for asset: ThumbnailAsset, spec: ThumbnailRequestSpec) async -> CGImage? {
    let request = ThumbnailRequestState()
    let source: ThumbnailImageSource? = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        request.install(continuation)
        Task { [io, backend] in
          let id = await io.run {
            guard !request.isCancelled else { return PHInvalidImageRequestID }
            return backend.request(
              asset: asset, size: spec.size, mode: spec.contentMode, options: spec.options()
            ) { source in request.complete(source) }
          }
          if request.setID(id) { await io.run { backend.cancel(id) } }
        }
      }
    } onCancel: {
      let id = request.cancel()
      if let id { Task { [io, backend] in await io.run { backend.cancel(id) } } }
    }
    guard let source, !Task.isCancelled else { return nil }
    return await io.run { source.rasterize(size: spec.size) }
  }
}

/// Joins cancellation and synchronous PhotoKit callbacks without holding the lock while resuming.
private final class ThumbnailRequestState: Sendable {
  private struct State {
    var continuation: CheckedContinuation<ThumbnailImageSource?, Never>?
    var id: PHImageRequestID?
    var cancelled = false
    var finished = false
  }
  private let state = Mutex(State())
  var isCancelled: Bool { state.withLock { $0.cancelled } }

  func install(_ continuation: CheckedContinuation<ThumbnailImageSource?, Never>) {
    let resume = state.withLock { value in
      if value.cancelled { return true }
      value.continuation = continuation
      return false
    }
    if resume { continuation.resume(returning: nil) }
  }

  func complete(_ source: ThumbnailImageSource?) {
    let continuation = state.withLock {
      value -> CheckedContinuation<ThumbnailImageSource?, Never>? in
      guard !value.finished else { return nil }
      value.finished = true
      defer { value.continuation = nil }
      return value.continuation
    }
    continuation?.resume(returning: source)
  }

  func setID(_ id: PHImageRequestID) -> Bool {
    state.withLock {
      $0.id = id
      return $0.cancelled
    }
  }

  func cancel() -> PHImageRequestID? {
    let result = state.withLock { value in
      value.cancelled = true
      value.finished = true
      let continuation = value.continuation
      value.continuation = nil
      return (value.id, continuation)
    }
    result.1?.resume(returning: nil)
    return result.0
  }
}
