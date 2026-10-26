import CoreGraphics
import Foundation

/// Bounded `CGImage` cache for thumbnail decode results. Concurrent
/// requests for the same key share one decode, ref-counted so the shared
/// decode is cancelled only when every waiter has cancelled. `clear()`
/// discards stored entries and prevents in-flight decodes started before
/// the call from landing in the cleared cache.
@MainActor
final class DecodedThumbnailCache {
  struct Key: Hashable, Sendable {
    let assetId: String
    let quantizedSize: CGSize
    let deliveryMode: ThumbnailDeliveryMode
    let contentRevision: Int

    init(
      assetId: String, quantizedSize: CGSize, deliveryMode: ThumbnailDeliveryMode,
      contentRevision: Int = 0
    ) {
      self.assetId = assetId
      self.quantizedSize = quantizedSize
      self.deliveryMode = deliveryMode
      self.contentRevision = contentRevision
    }
  }

  typealias Decode = @Sendable (Key) async -> CGImage?

  init(
    decode: @escaping Decode,
    totalCostLimit: Int = memoryBudget(physicalMemory: ProcessInfo.processInfo.physicalMemory),
    countLimit: Int? = nil
  ) {
    self.decode = decode
    self.storage = NSCache<KeyBox, ImageBox>()
    self.storage.totalCostLimit = totalCostLimit
    self.storage.countLimit = countLimit ?? max(1, totalCostLimit / (256 * 256 * 4))
  }

  nonisolated static func memoryBudget(physicalMemory: UInt64) -> Int {
    Int(min(256 * 1024 * 1024, max(32 * 1024 * 1024, physicalMemory / 64)))
  }

  private func highQualityKey(for key: Key) -> Key {
    Key(
      assetId: key.assetId, quantizedSize: key.quantizedSize,
      deliveryMode: .highQuality, contentRevision: key.contentRevision)
  }

  private func fastKey(for key: Key) -> Key {
    Key(
      assetId: key.assetId, quantizedSize: key.quantizedSize,
      deliveryMode: .fast, contentRevision: key.contentRevision)
  }

  func cached(for key: Key) -> CGImage? {
    storage.object(forKey: KeyBox(key))?.image
  }

  func image(for key: Key, decode: Decode? = nil) async -> CGImage? {
    if key.deliveryMode == .fast, let highQuality = cached(for: highQualityKey(for: key)) {
      return highQuality
    }
    if let existing = cached(for: key) { return existing }

    let task: Task<CGImage?, Never>
    let entryId: Int
    if var entry = inFlight[key] {
      entry.waiterCount += 1
      inFlight[key] = entry
      task = entry.task
      entryId = entry.entryId
    } else {
      nextEntryId &+= 1
      entryId = nextEntryId
      let gen = generation
      let provider = decode ?? self.decode
      task = Task<CGImage?, Never> { [weak self] in
        guard let self else { return nil }
        var result = await provider(key)
        if self.generation == gen, !Task.isCancelled,
          self.inFlight[key]?.entryId == entryId
        {
          if key.deliveryMode == .fast,
            let highQuality = self.cached(for: self.highQualityKey(for: key))
          {
            result = highQuality
          } else if let result {
            let box = ImageBox(image: result)
            self.storage.setObject(box, forKey: KeyBox(key), cost: box.cost)
            if key.deliveryMode == .highQuality {
              self.storage.removeObject(forKey: KeyBox(self.fastKey(for: key)))
            }
          }
        }
        // Only retire the slot if it's still ours. A cancel-hop scheduled
        // earlier may have already cancelled-and-removed this entry, in
        // which case a fresh InFlight could now occupy the key.
        if self.inFlight[key]?.entryId == entryId {
          self.inFlight.removeValue(forKey: key)
        }
        return result
      }
      inFlight[key] = InFlight(task: task, entryId: entryId, waiterCount: 1)
    }

    return await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.releaseWaiter(key: key, entryId: entryId)
      }
    }
  }

  #if DEBUG
    func waiterCount(for key: Key) -> Int { inFlight[key]?.waiterCount ?? 0 }
  #endif

  func clear() {
    storage.removeAllObjects()
    // Cancel and forget in-flight decodes so a caller arriving after `clear`
    // can't join a stale task and receive its pre-clear image.
    for (_, entry) in inFlight {
      entry.task.cancel()
    }
    inFlight.removeAll()
    generation &+= 1
  }

  private func releaseWaiter(key: Key, entryId: Int) {
    guard var entry = inFlight[key], entry.entryId == entryId else { return }
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
    /// Disambiguates this `InFlight` instance from any later one occupying
    /// the same key slot, so a late cancel-hop can't decrement a fresh
    /// entry it never joined.
    let entryId: Int
    var waiterCount: Int
  }

  private let decode: Decode
  private let storage: NSCache<KeyBox, ImageBox>
  private var inFlight: [Key: InFlight] = [:]
  private var nextEntryId: Int = 0
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
