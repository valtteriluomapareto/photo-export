import CoreGraphics
import Foundation
import Testing

@testable import Photo_Export

@MainActor
struct DecodedThumbnailCacheTests {

  // MARK: - Test helpers

  /// Synthesizes a deterministic `CGImage` of `size` pixels filled with `gray`.
  private static func makeCGImage(width: Int = 16, height: Int = 16, gray: UInt8 = 128) -> CGImage {
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var bytes = [UInt8](repeating: gray, count: width * height * bytesPerPixel)
    return bytes.withUnsafeMutableBufferPointer { buffer -> CGImage in
      let context = CGContext(
        data: buffer.baseAddress,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )!
      return context.makeImage()!
    }
  }

  private func key(
    id: String = "a",
    size: CGSize = CGSize(width: 200, height: 200),
    mode: ThumbnailContentMode = .aspectFill,
    delivery: ThumbnailDeliveryMode = .fast
  ) -> DecodedThumbnailCache.Key {
    .init(assetId: id, quantizedSize: size, contentMode: mode, deliveryMode: delivery)
  }

  // MARK: - Concurrent deduplication

  @Test func concurrentRequestsForSameKeyShareOneDecode() async {
    let decodeCount = DecodeCounter()
    let cache = DecodedThumbnailCache(decode: { _ in
      await decodeCount.increment()
      // Brief await so two callers can both observe the in-flight slot.
      try? await Task.sleep(for: .milliseconds(20))
      return Self.makeCGImage()
    })

    async let first = cache.image(for: key())
    async let second = cache.image(for: key())
    async let third = cache.image(for: key())
    _ = await (first, second, third)

    let count = await decodeCount.value
    #expect(count == 1)
  }

  // MARK: - Delivery-mode separation

  @Test func fastAndHighQualityEntriesStaySeparate() async {
    let decodedKeys = DecodedKeysRecorder()
    let cache = DecodedThumbnailCache(decode: { key in
      await decodedKeys.append(key)
      return Self.makeCGImage()
    })

    _ = await cache.image(for: key(delivery: .fast))
    _ = await cache.image(for: key(delivery: .highQuality))
    _ = await cache.image(for: key(delivery: .fast))
    _ = await cache.image(for: key(delivery: .highQuality))

    let recorded = await decodedKeys.values
    // Both delivery modes were decoded exactly once; repeats hit the cache.
    #expect(recorded.count == 2)
    #expect(recorded.contains(key(delivery: .fast)))
    #expect(recorded.contains(key(delivery: .highQuality)))
  }

  // MARK: - Clear behavior

  @Test func clearForcesReDecodeOnNextRequest() async {
    let decodeCount = DecodeCounter()
    let cache = DecodedThumbnailCache(decode: { _ in
      await decodeCount.increment()
      return Self.makeCGImage()
    })

    _ = await cache.image(for: key())
    #expect(await decodeCount.value == 1)
    cache.clear()
    _ = await cache.image(for: key())
    #expect(await decodeCount.value == 2)
  }

  // MARK: - Count limit

  @Test func countLimitEvictsOldestEntries() async {
    let cache = DecodedThumbnailCache(
      decode: { _ in Self.makeCGImage() },
      totalCostLimit: 1 << 30,
      countLimit: 2)

    _ = await cache.image(for: key(id: "a"))
    _ = await cache.image(for: key(id: "b"))
    _ = await cache.image(for: key(id: "c"))

    // NSCache eviction is implementation-defined under count pressure, but at
    // least one of the earlier entries must have been evicted.
    let stillCachedCount = [
      cache.cached(for: key(id: "a")),
      cache.cached(for: key(id: "b")),
      cache.cached(for: key(id: "c")),
    ].compactMap { $0 }.count
    #expect(stillCachedCount <= 2)
    // The most recent entry must still be present.
    #expect(cache.cached(for: key(id: "c")) != nil)
  }

  // MARK: - Quantization

  @Test func quantizedKeysCollapseSimilarRequests() async {
    let decodeCount = DecodeCounter()
    let cache = DecodedThumbnailCache(decode: { _ in
      await decodeCount.increment()
      return Self.makeCGImage()
    })

    // Quantization is the caller's responsibility — once two requests carry
    // the same `quantizedSize`, the cache must treat them as the same entry.
    let bucketed = CGSize(width: 256, height: 256)
    _ = await cache.image(for: key(size: bucketed))
    _ = await cache.image(for: key(size: bucketed))

    // A different bucket counts as a different entry.
    _ = await cache.image(for: key(size: CGSize(width: 320, height: 320)))

    #expect(await decodeCount.value == 2)
  }

  // MARK: - Sync probe semantics

  @Test func cachedProbeReturnsNilBeforeFirstLoad() async {
    let cache = DecodedThumbnailCache(decode: { _ in Self.makeCGImage() })
    #expect(cache.cached(for: key()) == nil)
    _ = await cache.image(for: key())
    #expect(cache.cached(for: key()) != nil)
  }

  @Test func decodeReturningNilDoesNotPopulateCache() async {
    let cache = DecodedThumbnailCache(decode: { _ in nil })
    let result = await cache.image(for: key())
    #expect(result == nil)
    #expect(cache.cached(for: key()) == nil)
  }
}

/// Actor-isolated counter so concurrent decode callbacks don't race.
private actor DecodeCounter {
  private(set) var value: Int = 0
  func increment() { value += 1 }
}

/// Actor-isolated recorder for which keys hit decode().
private actor DecodedKeysRecorder {
  private(set) var values: [DecodedThumbnailCache.Key] = []
  func append(_ key: DecodedThumbnailCache.Key) { values.append(key) }
}
