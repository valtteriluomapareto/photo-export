import CoreGraphics
import Foundation

/// Bounded `CGImage` cache for thumbnail decode results. Caller is
/// responsible for quantizing `quantizedSize`. Concurrent requests for the
/// same key share one decode and one PhotoKit request, ref-counted: the
/// shared decode is cancelled only when every waiter cancels. `clear()`
/// discards stored entries and prevents in-flight decodes started before
/// the call from landing in the cleared cache.
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

    let task: Task<CGImage?, Never>
    if var entry = inFlight[key] {
      entry.waiterCount += 1
      inFlight[key] = entry
      task = entry.task
    } else {
      let gen = generation
      task = Task<CGImage?, Never> { [weak self] in
        guard let self else { return nil }
        let result = await self.decode(key)
        // Skip the store if `clear()` arrived during the decode — the
        // decoded bytes may not match the post-mutation library state.
        if let result, self.generation == gen {
          let box = ImageBox(image: result)
          self.storage.setObject(box, forKey: KeyBox(key), cost: box.cost)
        }
        self.inFlight.removeValue(forKey: key)
        return result
      }
      inFlight[key] = InFlight(task: task, waiterCount: 1)
    }

    return await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.releaseWaiter(key: key)
      }
    }
  }

  func clear() {
    storage.removeAllObjects()
    generation &+= 1
  }

  private func releaseWaiter(key: Key) {
    guard var entry = inFlight[key] else { return }
    entry.waiterCount -= 1
    if entry.waiterCount <= 0 {
      entry.task.cancel()
      inFlight.removeValue(forKey: key)
    } else {
      inFlight[key] = entry
    }
  }

  private struct InFlight {
    let task: Task<CGImage?, Never>
    var waiterCount: Int
  }

  private let decode: Decode
  private let storage: NSCache<KeyBox, ImageBox>
  private var inFlight: [Key: InFlight] = [:]
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
