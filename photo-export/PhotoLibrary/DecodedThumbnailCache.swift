import CoreGraphics
import Foundation

/// Bounded `CGImage` cache for thumbnail decode results. Caller is
/// responsible for quantizing `quantizedSize`. Concurrent requests for the
/// same key share one decode. `clear()` discards stored entries and arranges
/// for in-flight decodes started before the call to *not* land in the
/// cleared cache.
@MainActor
final class DecodedThumbnailCache {
  struct Key: Hashable, Sendable {
    let assetId: String
    let quantizedSize: CGSize
    let deliveryMode: ThumbnailDeliveryMode
  }

  typealias Decode = @MainActor (Key) async -> CGImage?

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

  func cached(for key: Key) -> CGImage? {
    storage.object(forKey: KeyBox(key))?.image
  }

  func image(for key: Key) async -> CGImage? {
    if let existing = cached(for: key) { return existing }
    if let inFlight = inFlight[key] { return await inFlight.value }
    let gen = generation
    let task = Task<CGImage?, Never> { [weak self] in
      guard let self else { return nil }
      let result = await self.decode(key)
      // Skip the store if a `clear()` arrived while we were decoding — the
      // decoded bytes may no longer match the post-mutation library state.
      if let result, self.generation == gen {
        let box = ImageBox(image: result)
        self.storage.setObject(box, forKey: KeyBox(key), cost: box.cost)
      }
      self.inFlight.removeValue(forKey: key)
      return result
    }
    inFlight[key] = task
    return await task.value
  }

  func clear() {
    storage.removeAllObjects()
    generation &+= 1
  }

  private let decode: Decode
  private let storage: NSCache<KeyBox, ImageBox>
  private var inFlight: [Key: Task<CGImage?, Never>] = [:]
  private var generation: Int = 0
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
