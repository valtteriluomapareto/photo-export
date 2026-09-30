import AppKit
import SwiftUI
import Testing

@testable import Photo_Export

/// Tests actual rendered pixels while the same cell remains mounted. Clearing
/// the manager cache alone cannot prove that SwiftUI restarts a cell's task.
@MainActor
@Suite(.serialized)
struct ThumbnailViewLifecycleTests {
  private static let targetSize = CGSize(width: 256, height: 256)

  private static func image(_ color: NSColor) -> CGImage {
    let context = CGContext(
      data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(color.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
    return context.makeImage()!
  }

  @MainActor
  private final class Fixture {
    let service = FakePhotoLibraryService()
    let manager: PhotoLibraryManager
    let window: NSWindow
    var lastColorDescription = "no pixel"

    init() {
      manager = PhotoLibraryManager(overrideService: service)
      let hosted = NSHostingView(
        rootView: ThumbnailView(
          asset: TestAssetFactory.makeAsset(id: "asset-A"),
          isSelected: false, isExported: true
        )
        .frame(width: 100, height: 100)
        .environmentObject(manager))
      window = NSWindow(
        contentRect: NSRect(x: -10_000, y: -10_000, width: 100, height: 100),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = hosted
    }

    func show() { window.orderFront(nil) }

    func close() {
      window.orderOut(nil)
      window.contentView = nil
      window.close()
      manager.decodedThumbnailCache.clear()
    }

    func shows(_ color: NSColor) -> Bool {
      guard let view = window.contentView else { return false }
      view.layoutSubtreeIfNeeded()
      guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
      view.cacheDisplay(in: view.bounds, to: bitmap)
      guard
        let actual = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?
          .usingColorSpace(.sRGB),
        let expected = color.usingColorSpace(.sRGB)
      else { return false }
      lastColorDescription = "actual \(actual), expected \(expected)"
      // AppKit tone-maps HDR snapshots even for solid sRGB fixtures. Compare
      // their clearly distinct red/blue channels rather than exact RGB values.
      if expected.redComponent > expected.blueComponent {
        return actual.redComponent > actual.blueComponent + 0.4
      }
      return actual.blueComponent > actual.redComponent + 0.4
    }
  }

  /// This is only a bound on SwiftUI render scheduling, not a delay used to
  /// arrange a race. Provider checkpoints control in-flight completion order.
  private func observe(_ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(15))
    while !condition(), !Task.isCancelled, clock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
  }

  @Test(.timeLimit(.minutes(2)), arguments: [false, true])
  func libraryInvalidationRefreshesMountedSameIDThumbnail(knownChangedID: Bool) async throws {
    let fixture = Fixture()
    var currentImage = Self.image(.red)
    fixture.service.decodedThumbnailOverride = { _, _, _ in currentImage }
    defer { fixture.close() }
    fixture.show()
    let initialLoaded = await observe {
      fixture.manager.cachedDecodedThumbnail(
        for: "asset-A", quantizedSize: Self.targetSize, deliveryMode: .highQuality) != nil
        && fixture.shows(.red)
    }
    #expect(!fixture.service.decodedThumbnailCalls.isEmpty)
    #expect(
      fixture.manager.cachedDecodedThumbnail(
        for: "asset-A", quantizedSize: Self.targetSize, deliveryMode: .highQuality) != nil)
    try #require(initialLoaded, "\(fixture.lastColorDescription)")
    let requestsBeforeChange = fixture.service.decodedThumbnailCalls.count

    currentImage = Self.image(.blue)
    fixture.manager.invalidateCache(changedThumbnailAssetIDs: knownChangedID ? ["asset-A"] : nil)

    let refreshed = await observe { fixture.shows(.blue) }
    #expect(
      refreshed, "A mounted cell must display the edited image without navigation or remounting")
    #expect(fixture.service.decodedThumbnailCalls.count > requestsBeforeChange)
  }

  @Test(.timeLimit(.minutes(2)), arguments: [ThumbnailDeliveryMode.fast, .highQuality])
  func latePreEditDecodeCannotReplaceMountedImageOrCurrentCache(oldDelivery: ThumbnailDeliveryMode)
    async throws
  {
    let fixture = Fixture()
    let red = Self.image(.red)
    let blue = Self.image(.blue)
    let oldDecode = AsyncCheckpoint()
    let observerStarted = AsyncCheckpoint()
    var edited = false
    fixture.service.decodedThumbnailOverride = { _, _, delivery in
      if !edited, delivery == oldDelivery {
        await oldDecode.enter()
        // Deliberately ignore cancellation, like a late PhotoKit completion.
        return red
      }
      return edited ? blue : red
    }
    defer {
      fixture.close()
      Task {
        await oldDecode.releaseAll()
        await observerStarted.releaseAll()
      }
    }
    fixture.show()
    await oldDecode.waitForEnter(count: 1)
    // Join the cell's already-blocked decode so the test can await its actual
    // completion after the edit, rather than checking before the old response.
    let oldObserver = Task { @MainActor in
      Task { await observerStarted.enter() }
      return await fixture.manager.decodedThumbnail(
        for: "asset-A", quantizedSize: Self.targetSize, deliveryMode: oldDelivery)
    }
    await observerStarted.waitForEnter(count: 1)

    edited = true
    fixture.manager.invalidateCache(changedThumbnailAssetIDs: ["asset-A"])
    let refreshed = await observe {
      fixture.shows(.blue)
        && fixture.manager.cachedDecodedThumbnail(
          for: "asset-A", quantizedSize: Self.targetSize, deliveryMode: .highQuality) === blue
    }
    try #require(refreshed, "\(fixture.lastColorDescription)")
    await oldDecode.releaseAll()
    #expect(
      await oldObserver.value == nil,
      "An obsolete decode must not return image bytes to its waiters")
    #expect(fixture.shows(.blue))
    #expect(
      fixture.manager.cachedDecodedThumbnail(
        for: "asset-A", quantizedSize: Self.targetSize, deliveryMode: oldDelivery) === blue)
  }

  @Test(.timeLimit(.minutes(1)))
  func replacementKeepsExistingImageWhileFreshDecodeIsPending() async throws {
    let fixture = Fixture()
    let red = Self.image(.red)
    let blue = Self.image(.blue)
    let replacement = AsyncCheckpoint()
    var edited = false
    fixture.service.decodedThumbnailOverride = { _, _, _ in
      if edited {
        await replacement.enter()
        return blue
      }
      return red
    }
    defer {
      fixture.close()
      Task { await replacement.releaseAll() }
    }
    fixture.show()
    let initialLoaded = await observe {
      fixture.shows(.red)
        && fixture.manager.cachedDecodedThumbnail(
          for: "asset-A", quantizedSize: Self.targetSize, deliveryMode: .highQuality) === red
    }
    try #require(initialLoaded)

    edited = true
    fixture.manager.invalidateCache(changedThumbnailAssetIDs: ["asset-A"])
    await replacement.waitForEnter(count: 1)
    #expect(fixture.shows(.red), "Content invalidation must not blank the mounted cell")
    await replacement.releaseAll()
    let refreshed = await observe { fixture.shows(.blue) }
    #expect(refreshed)
  }

  @Test(.timeLimit(.minutes(1)))
  func coalescedChangesStillRefreshEarlierAffectedAsset() async throws {
    let fixture = Fixture()
    var currentImage = Self.image(.red)
    fixture.service.decodedThumbnailOverride = { _, _, _ in currentImage }
    defer { fixture.close() }
    fixture.show()
    let initialLoaded = await observe {
      fixture.shows(.red)
        && fixture.manager.cachedDecodedThumbnail(
          for: "asset-A", quantizedSize: Self.targetSize, deliveryMode: .highQuality) != nil
    }
    try #require(initialLoaded)

    currentImage = Self.image(.blue)
    fixture.manager.invalidateCache(changedThumbnailAssetIDs: ["asset-A"])
    let revisedA = fixture.manager.thumbnailContentRevision(for: "asset-A")
    // Both changes happen before SwiftUI can render; the second must not erase
    // the first asset's content revision.
    fixture.manager.invalidateCache(changedThumbnailAssetIDs: ["asset-B"])
    #expect(fixture.manager.thumbnailContentRevision(for: "asset-A") == revisedA)
    let refreshed = await observe { fixture.shows(.blue) }
    #expect(refreshed)
  }

  @Test func unrelatedChangePreservesWarmCacheAndTaskIdentity() async {
    let fixture = Fixture()
    let red = Self.image(.red)
    fixture.service.decodedThumbnailOverride = { _, _, _ in red }
    defer { fixture.close() }
    for delivery in [ThumbnailDeliveryMode.fast, .highQuality] {
      _ = await fixture.manager.decodedThumbnail(
        for: "asset-A", quantizedSize: Self.targetSize, deliveryMode: delivery)
    }
    let oldRevision = fixture.manager.thumbnailContentRevision(for: "asset-A")
    let requestsBefore = fixture.service.decodedThumbnailCalls.count
    fixture.manager.invalidateCache(changedThumbnailAssetIDs: ["asset-B"])
    #expect(fixture.manager.thumbnailContentRevision(for: "asset-A") == oldRevision)
    for delivery in [ThumbnailDeliveryMode.fast, .highQuality] {
      #expect(
        fixture.manager.cachedDecodedThumbnail(
          for: "asset-A", quantizedSize: Self.targetSize, deliveryMode: delivery) === red)
      let warm = await fixture.manager.decodedThumbnail(
        for: "asset-A", quantizedSize: Self.targetSize, deliveryMode: delivery)
      #expect(warm === red)
    }
    #expect(fixture.service.decodedThumbnailCalls.count == requestsBefore)
  }

  @Test func revisionTrackingOverflowFallsBackToGlobalInvalidation() async {
    let fixture = Fixture()
    let red = Self.image(.red)
    fixture.service.decodedThumbnailOverride = { _, _, _ in red }
    defer { fixture.close() }
    _ = await fixture.manager.decodedThumbnail(
      for: "asset-A", quantizedSize: Self.targetSize, deliveryMode: .fast)
    let oldRevision = fixture.manager.thumbnailContentRevision(for: "asset-A")

    fixture.manager.invalidateCache(
      changedThumbnailAssetIDs: Set((0..<1_000).map { "changed-\($0)" }))

    #expect(fixture.manager.thumbnailContentRevision(for: "asset-A") != oldRevision)
    #expect(
      fixture.manager.cachedDecodedThumbnail(
        for: "asset-A", quantizedSize: Self.targetSize, deliveryMode: .fast) == nil)
  }

  @Test(.timeLimit(.minutes(1)))
  func failedReplacementExposesFailureTileAndCanRecover() async throws {
    let fixture = Fixture()
    let red = Self.image(.red)
    var currentImage: CGImage? = red
    fixture.service.decodedThumbnailOverride = { _, _, _ in currentImage }
    defer { fixture.close() }
    fixture.show()
    let initialLoaded = await observe {
      fixture.shows(.red)
        && fixture.manager.cachedDecodedThumbnail(
          for: "asset-A", quantizedSize: Self.targetSize, deliveryMode: .highQuality) === red
    }
    try #require(initialLoaded)
    let requestsBefore = fixture.service.decodedThumbnailCalls.count

    currentImage = nil
    fixture.manager.invalidateCache(changedThumbnailAssetIDs: ["asset-A"])
    let failureVisible = await observe {
      fixture.service.decodedThumbnailCalls.count >= requestsBefore + 2
        && !fixture.shows(.red)
    }
    #expect(
      failureVisible,
      "After both replacement decodes fail, the obsolete image must yield to the failure/Retry tile"
    )

    currentImage = Self.image(.blue)
    fixture.manager.invalidateCache(changedThumbnailAssetIDs: ["asset-A"])
    let recovered = await observe { fixture.shows(.blue) }
    #expect(recovered)
  }
}
