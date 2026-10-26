import CoreGraphics
import Foundation
import Testing

@testable import Photo_Export

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct DecodedThumbnailCacheTests {

  // MARK: - Test helpers

  /// Synthesizes a deterministic `CGImage` of `size` pixels filled with `gray`.
  nonisolated private static func makeCGImage(width: Int = 16, height: Int = 16, gray: UInt8 = 128)
    -> CGImage
  {
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

  nonisolated private static func currentThreadIsMain() -> Bool { Thread.isMainThread }

  private func key(
    id: String = "a",
    size: CGSize = CGSize(width: 200, height: 200),
    delivery: ThumbnailDeliveryMode = .fast
  ) -> DecodedThumbnailCache.Key {
    .init(assetId: id, quantizedSize: size, deliveryMode: delivery)
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
    let (a, b, c) = await (first, second, third)

    let count = await decodeCount.value
    #expect(count == 1)
    // Identity check: all three callers receive the same decoded CGImage, not
    // three serial decodes that happened to return equal-looking values.
    #expect(a != nil)
    #expect(a === b)
    #expect(b === c)
  }

  // MARK: - Delivery-mode separation

  @Test func bothDeliveryModesDecodeOnceThenReuseHighQuality() async {
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

  @Test func contentRevisionsKeepSameAssetDecodesSeparate() async {
    let decodedKeys = DecodedKeysRecorder()
    let cache = DecodedThumbnailCache(decode: { key in
      await decodedKeys.append(key)
      return Self.makeCGImage(gray: key.contentRevision == 0 ? 32 : 224)
    })
    let original = key()
    let edited = DecodedThumbnailCache.Key(
      assetId: original.assetId, quantizedSize: original.quantizedSize,
      deliveryMode: original.deliveryMode, contentRevision: 1)
    let oldImage = await cache.image(for: original)
    let newImage = await cache.image(for: edited)

    #expect(original.contentRevision == 0)
    #expect(await decodedKeys.values.map(\.contentRevision) == [0, 1])
    #expect(oldImage !== newImage)
    #expect(cache.cached(for: edited) === newImage)
    #expect(await cache.image(for: edited) === newImage)
    #expect(
      await decodedKeys.values.map(\.contentRevision) == [0, 1],
      "A warm edited revision should not decode again")
  }

  @Test func cacheProviderRunsOffMain() async {
    let image = Self.makeCGImage()
    let threads = DecodeThreadRecorder()
    let cache = DecodedThumbnailCache { _ in
      let isMainThread = Self.currentThreadIsMain()
      await threads.record(isMainThread)
      return image
    }
    #expect(await cache.image(for: key()) === image)
    #expect(await threads.values == [false])
  }

  @Test func highQualityReplacesMatchingFastEntry() async {
    let fast = Self.makeCGImage(gray: 32)
    let highQuality = Self.makeCGImage(gray: 224)
    let keys = DecodedKeysRecorder()
    let cache = DecodedThumbnailCache { key in
      await keys.append(key)
      return key.deliveryMode == .fast ? fast : highQuality
    }
    #expect(await cache.image(for: key()) === fast)
    #expect(await cache.image(for: key(delivery: .highQuality)) === highQuality)
    #expect(cache.cached(for: key()) == nil)
    #expect(await cache.image(for: key()) === highQuality)
    #expect(await keys.values.count == 2)
  }

  @Test func lateFastCompletionCannotRestoreEntryAfterHighQuality() async throws {
    let fast = Self.makeCGImage(gray: 32)
    let highQuality = Self.makeCGImage(gray: 224)
    let gate = AsyncCheckpoint()
    let cache = DecodedThumbnailCache { key in
      if key.deliveryMode == .fast {
        await gate.enter()
        return fast
      }
      return highQuality
    }
    let pending = Task { await cache.image(for: key()) }
    try await withCleanup {
      try #require(await gate.waitForEnter(count: 1))
      #expect(await cache.image(for: key(delivery: .highQuality)) === highQuality)
      await gate.releaseAll()
      _ = await pending.value
      #expect(cache.cached(for: key()) == nil)
      #expect(await cache.image(for: key()) === highQuality)
    } cleanup: {
      await gate.releaseAll()
      _ = await pending.value
    }
  }

  @Test func memoryBudgetStaysBounded() {
    let gibibyte: UInt64 = 1024 * 1024 * 1024
    let cases: [(UInt64, Int)] = [
      (0, 32), (2 * gibibyte, 32), (8 * gibibyte, 128), (64 * gibibyte, 256),
    ]
    for (physicalMemory, expectedMiB) in cases {
      #expect(
        DecodedThumbnailCache.memoryBudget(physicalMemory: physicalMemory)
          == expectedMiB * 1024 * 1024)
    }
  }

  @Test(arguments: ["asset", "revision", "size"])
  func highQualityKeepsOtherFastKeysIndependent(difference: String) async {
    let image = Self.makeCGImage()
    let cache = DecodedThumbnailCache { _ in image }
    let other = DecodedThumbnailCache.Key(
      assetId: difference == "asset" ? "other" : "a",
      quantizedSize: difference == "size"
        ? CGSize(width: 320, height: 320) : CGSize(width: 200, height: 200),
      deliveryMode: .fast, contentRevision: difference == "revision" ? 1 : 0)
    _ = await cache.image(for: other)
    _ = await cache.image(for: key(delivery: .highQuality))
    #expect(cache.cached(for: other) === image)
  }

  #if DEBUG
    @Test func endingFirstGridKeepsTheOtherThumbnailWaiterAlive() async throws {
      let service = FakePhotoLibraryService()
      let asset = TestAssetFactory.makeAsset(id: "shared-grid-image")
      service.favoritesAssets = [asset]
      let image = Self.makeCGImage()
      let gate = AsyncCheckpoint()
      let cancelled = LockedBox(false)
      service.decodedThumbnailOverride = { _, _, _ in
        await withTaskCancellationHandler {
          await gate.enter()
          return image
        } onCancel: {
          cancelled.mutate { $0 = true }
        }
      }
      let library = PhotoLibraryManager(overrideService: service)
      let firstMap = GridThumbnailAssets(service: library)
      let secondMap = GridThumbnailAssets(service: library)
      await firstMap.updateWindow([asset])
      await secondMap.updateWindow([asset])
      let source = try #require(
        await firstMap.handle(for: asset.id, revision: 0, isCurrent: { true }))
      let other = try #require(
        await secondMap.handle(for: asset.id, revision: 0, isCurrent: { true }))
      let cacheKey = DecodedThumbnailCache.Key(
        assetId: asset.id, quantizedSize: ThumbnailRequestSpec.gridSize, deliveryMode: .highQuality)
      let first = Task {
        await library.decodedThumbnail(
          for: source, quantizedSize: ThumbnailRequestSpec.gridSize, deliveryMode: .highQuality)
      }
      let second = Task {
        await library.decodedThumbnail(
          for: other, quantizedSize: ThumbnailRequestSpec.gridSize, deliveryMode: .highQuality)
      }
      try await withCleanup {
        try #require(await gate.waitForEnter(count: 1))
        try #require(
          await observe { library.decodedThumbnailCache.waiterCount(for: cacheKey) == 2 })
        first.cancel()
        await firstMap.deactivate().value
        try #require(
          await observe { library.decodedThumbnailCache.waiterCount(for: cacheKey) == 1 })
        #expect(!cancelled.value)
        await gate.releaseAll()
        #expect(await first.value == nil)
        #expect(await second.value === image)
        #expect(service.decodedThumbnailCalls.count == 1)
      } cleanup: {
        await gate.releaseAll()
        _ = await first.value
        _ = await second.value
        await firstMap.deactivate().value
        await secondMap.deactivate().value
      }
    }
  #endif

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

  @Test func concurrentCallersAllSeeNilWhenDecodeReturnsNil() async {
    let cache = DecodedThumbnailCache(decode: { _ in
      try? await Task.sleep(for: .milliseconds(20))
      return nil
    })

    async let first = cache.image(for: key())
    async let second = cache.image(for: key())
    let (a, b) = await (first, second)
    #expect(a == nil)
    #expect(b == nil)
    #expect(cache.cached(for: key()) == nil)
  }

  // MARK: - In-flight + clear race

  // MARK: - Cancellation propagation

  @Test func cancellingOnlyWaiterCancelsTheUnderlyingDecode() async throws {
    let decodeEntered = AsyncCheckpoint()
    let cancelled = AsyncStream<Void>.makeStream()
    var cancellation = cancelled.stream.makeAsyncIterator()
    let cache = DecodedThumbnailCache(decode: { _ in
      await withTaskCancellationHandler {
        await decodeEntered.enter()
        return Self.makeCGImage()
      } onCancel: {
        cancelled.continuation.yield(())
      }
    })
    let task = Task { await cache.image(for: key()) }
    try await withCleanup {
      try #require(await decodeEntered.waitForEnter(count: 1))
      task.cancel()
      // Keep physical work held until the last-waiter cancellation reaches its provider.
      try #require(await cancellation.next() != nil)
    } cleanup: {
      await decodeEntered.releaseAll()
      _ = await task.value
      cancelled.continuation.finish()
    }
  }

  @Test func cancellingOneOfTwoWaitersDoesNotCancelDecode() async {
    let decodeEntered = AsyncCheckpoint()
    let decodeWasCancelled = CancellationFlag()
    let cache = DecodedThumbnailCache(decode: { _ in
      await withTaskCancellationHandler {
        await decodeEntered.enter()
        return Self.makeCGImage()
      } onCancel: {
        Task { await decodeWasCancelled.set() }
      }
    })

    let firstWaiter = Task { @MainActor in
      _ = await cache.image(for: key())
    }
    // Wait until the first waiter has registered the in-flight slot and the
    // decode is suspended on the gate.
    await decodeEntered.waitForEnter(count: 1)
    let secondWaiter = Task { @MainActor in
      await cache.image(for: key())
    }
    // Let the second waiter reach `await task.value` (i.e. take its ref-count
    // slot) before the first cancels.
    await Task.yield()
    await Task.yield()
    firstWaiter.cancel()
    // Give the cancellation a turn to land — releaseWaiter is scheduled via a
    // Task hop, so yield twice before asserting it didn't cascade into the
    // inner decode.
    await Task.yield()
    await Task.yield()
    #expect(await decodeWasCancelled.value == false)
    // Release the gate so the inner decode (and both waiters) can complete.
    // Must happen *before* awaiting firstWaiter.value — firstWaiter is still
    // suspended on `await task.value`, which won't resolve until the inner
    // decode returns.
    await decodeEntered.releaseAll()
    let secondResult = await secondWaiter.value
    _ = await firstWaiter.value
    #expect(secondResult != nil)
    #expect(await decodeWasCancelled.value == false)
  }

  /// After `clear()`, a new request for the same key must start a fresh
  /// decode — not join the pre-clear in-flight task and receive its stale
  /// image. The generation guard prevents the cache from *storing* the
  /// stale result, but without dropping the in-flight slot a joining caller
  /// would still receive it.
  @Test func clearMidFlightForcesFreshDecodeForNewCallers() async {
    let decodeEntered = AsyncCheckpoint()
    let cache = DecodedThumbnailCache(decode: { _ in
      await decodeEntered.enter()
      return Self.makeCGImage()
    })

    // First caller starts the in-flight decode.
    let firstCaller = Task { @MainActor in
      _ = await cache.image(for: key())
    }
    await decodeEntered.waitForEnter(count: 1)

    // Library mutation lands. Clear must invalidate the in-flight slot so
    // a follower starts fresh.
    cache.clear()

    let secondCaller = Task { @MainActor in
      _ = await cache.image(for: key())
    }
    // A fresh decode means the checkpoint is entered a second time. If the
    // second caller had joined the original task, the count would stay at 1
    // and `waitForEnter(count: 2)` would hang.
    await decodeEntered.waitForEnter(count: 2)

    await decodeEntered.releaseAll()
    _ = await firstCaller.value
    _ = await secondCaller.value
  }

  @Test func clearMidFlightDropsStaleDecodeFromCache() async {
    let decodeEntered = AsyncCheckpoint()
    let cache = DecodedThumbnailCache(decode: { _ in
      await decodeEntered.enter()
      return Self.makeCGImage()
    })

    async let loadResult = cache.image(for: key())
    await decodeEntered.waitForEnter(count: 1)
    cache.clear()
    await decodeEntered.releaseAll()
    let decoded = await loadResult

    // The caller still receives its image, but a cleared generation cannot refill the cache.
    #expect(decoded != nil)
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

/// Actor-isolated flag for cancellation observation tests.
private actor CancellationFlag {
  private(set) var value: Bool = false
  func set() { value = true }
}

private actor DecodeThreadRecorder {
  private(set) var values: [Bool] = []
  func record(_ isMainThread: Bool) { values.append(isMainThread) }
}
