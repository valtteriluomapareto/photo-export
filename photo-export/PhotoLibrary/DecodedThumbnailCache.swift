import CoreGraphics
import Foundation

/// Bounded `CGImage` cache for thumbnail decode results, owned by
/// `PhotoLibraryManager`. Replaces the unbounded per-scope NSImage
/// dictionaries that lived on `MonthViewModel` — the cell now reads through
/// the cache, and memory pressure is bounded by `NSCache.totalCostLimit` +
/// `countLimit` rather than scaling with the number of scopes the user has
/// visited.
///
/// Key shape: `(assetId, quantizedSize, contentMode, deliveryMode)`. The
/// caller is responsible for quantizing the size (typically to 64-px
/// buckets) so 199×199 and 201×201 share an entry. Fast and high-quality
/// renders live in distinct slots so the HQ upgrade pipeline still works.
///
/// Concurrent dedup: a second `image(for:)` for the same key while an
/// earlier load is in flight awaits the same `Task` rather than firing a
/// second PhotoKit request.
///
/// Library mutations call `clear()` (driven from
/// `PhotoLibraryManager.invalidateCache`), invalidating every entry.
@MainActor
final class DecodedThumbnailCache {
  /// Cache lookup key. `quantizedSize` carries pre-bucketed dimensions —
  /// the cache does not round; the caller does.
  struct Key: Hashable, Sendable {
    let assetId: String
    let quantizedSize: CGSize
    let contentMode: ThumbnailContentMode
    let deliveryMode: ThumbnailDeliveryMode
  }

  typealias Decode = @MainActor (Key) async -> CGImage?

  /// Construct with an injected decode function so tests can supply a
  /// deterministic synchronous map without touching PhotoKit.
  init(
    decode: @escaping Decode,
    totalCostLimit: Int = 64 * 1024 * 1024,
    countLimit: Int = 512
  ) {
    self.decode = decode
    self.storage = NSCache<KeyBox, ImageBox>()
    self.storage.totalCostLimit = totalCostLimit
    self.storage.countLimit = countLimit
  }

  /// Synchronous probe. Returns the cached image for `key` or `nil` if the
  /// entry is absent or has been evicted. Safe to call from a SwiftUI body.
  func cached(for key: Key) -> CGImage? {
    storage.object(forKey: KeyBox(key))?.image
  }

  /// Async load. Returns the cached image, awaits an in-flight load for the
  /// same key, or starts a new decode. The first caller's decode result is
  /// shared with every concurrent waiter.
  func image(for key: Key) async -> CGImage? {
    if let existing = cached(for: key) { return existing }
    if let inFlight = inFlight[key] { return await inFlight.value }
    let task = Task<CGImage?, Never> { [weak self] in
      guard let self else { return nil }
      let result = await self.decode(key)
      if let result {
        let box = ImageBox(image: result)
        self.storage.setObject(box, forKey: KeyBox(key), cost: box.cost)
      }
      self.inFlight.removeValue(forKey: key)
      return result
    }
    inFlight[key] = task
    return await task.value
  }

  /// Drops every entry. Called from `PhotoLibraryManager.invalidateCache`
  /// after a `PHPhotoLibraryChangeObserver` callback so stale renders don't
  /// survive a library mutation. In-flight loads continue and will land in
  /// the fresh cache slot they re-key.
  func clear() {
    storage.removeAllObjects()
  }

  private let decode: Decode
  private let storage: NSCache<KeyBox, ImageBox>
  private var inFlight: [Key: Task<CGImage?, Never>] = [:]
}

enum ThumbnailContentMode: String, Hashable, Sendable {
  case aspectFill
  case aspectFit
}

enum ThumbnailDeliveryMode: String, Hashable, Sendable {
  case fast
  case highQuality
}

private final class KeyBox: NSObject {
  let key: DecodedThumbnailCache.Key
  init(_ key: DecodedThumbnailCache.Key) {
    self.key = key
  }
  override var hash: Int { key.hashValue }
  override func isEqual(_ object: Any?) -> Bool {
    guard let other = object as? KeyBox else { return false }
    return key == other.key
  }
}

private final class ImageBox: NSObject {
  let image: CGImage
  let cost: Int
  init(image: CGImage) {
    self.image = image
    self.cost = image.bytesPerRow * image.height
  }
}
