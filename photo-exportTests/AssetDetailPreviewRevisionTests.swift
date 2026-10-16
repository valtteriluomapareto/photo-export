import AppKit
import SwiftUI
import Testing

@testable import Photo_Export

@MainActor
@Suite(.serialized)
struct AssetDetailPreviewRevisionTests {
  enum Change: CaseIterable { case known, unknown, overflow, coalesced }

  private static func image(_ color: NSColor) -> NSImage {
    let context = CGContext(
      data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(color.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
    return NSImage(cgImage: context.makeImage()!, size: NSSize(width: 32, height: 32))
  }

  @MainActor
  private final class Fixture {
    let service = FakePhotoLibraryService()
    let manager: PhotoLibraryManager
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let timeline: ExportRecordStore
    let collections: CollectionExportRecordStore
    let window: NSWindow
    let replacement = AsyncCheckpoint()
    let counter = BodyInvalidationCounter()
    var requests = 0
    var currentImage = image(.red)

    init() {
      manager = PhotoLibraryManager(overrideService: service)
      timeline = ExportRecordStore(baseDirectoryURL: root)
      collections = CollectionExportRecordStore(baseDirectoryURL: root)
      timeline.configure(for: "test")
      collections.configure(for: "test")
      let hosted = NSHostingView(
        rootView: AssetDetailView(
          asset: TestAssetFactory.makeAsset(id: "A"), placement: .timeline(year: 2025, month: 1)
        )
        .environmentObject(manager).environmentObject(timeline).environmentObject(collections)
        .environment(\.bodyInvalidationCounter, counter))
      window = NSWindow(
        contentRect: NSRect(x: -10_000, y: -10_000, width: 360, height: 540),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = hosted
      service.fullImageRequestOverride = { [weak self] _ in
        guard let self else { throw CancellationError() }
        requests += 1
        let image = currentImage
        if requests == 2 { await replacement.enter() }
        return image
      }
    }

    func show() { window.orderFront(nil) }

    func close() {
      window.orderOut(nil)
      window.contentView = nil
      window.close()
      Task { await replacement.releaseAll() }
      timeline.flushForTesting()
      collections.flushForTesting()
      try? FileManager.default.removeItem(at: root)
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
      return expected.redComponent > expected.blueComponent
        ? actual.redComponent > actual.blueComponent + 0.4
        : actual.blueComponent > actual.redComponent + 0.4
    }

    func invalidate(_ change: Change) {
      switch change {
      case .known: manager.invalidateCache(changedThumbnailAssetIDs: ["A"])
      case .unknown: manager.invalidateCache()
      case .overflow:
        manager.invalidateCache(changedThumbnailAssetIDs: Set((0..<1000).map { "changed-\($0)" }))
      case .coalesced:
        manager.invalidateCache(changedThumbnailAssetIDs: ["A"])
        manager.invalidateCache(changedThumbnailAssetIDs: ["B"])
      }
    }
  }

  private func observe(_ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(3))
    while !condition(), clock.now < deadline, !Task.isCancelled {
      try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
  }

  @Test(.timeLimit(.minutes(1)), arguments: Change.allCases)
  func mountedSameIDEditAndRevertRefreshPixelsWithoutBlanking(change: Change) async throws {
    let f = Fixture()
    defer { f.close() }
    f.show()
    let initial = await observe { f.shows(.red) }
    try #require(initial)
    f.currentImage = Self.image(.blue)
    f.invalidate(change)
    let restarted = await observe { f.requests == 2 }
    // Old code never starts the next request. Bound the baseline failure before
    // awaiting its gate, so the regression cannot strand the runner.
    try #require(restarted, "The selected content revision must restart the mounted preview task")
    await f.replacement.waitForEnter(count: 1)
    #expect(f.shows(.red), "Keep the current image while replacement bytes are pending")
    await f.replacement.releaseAll()
    let updated = await observe { f.shows(.blue) }
    #expect(updated)
    f.currentImage = Self.image(.red)
    f.manager.invalidateCache(changedThumbnailAssetIDs: ["A"])
    let reverted = await observe { f.requests == 3 && f.shows(.red) }
    #expect(reverted)
  }

  @Test(.timeLimit(.minutes(1)))
  func unrelatedKnownEditRendersWithoutReloadingSelectedImage() async throws {
    let f = Fixture()
    defer { f.close() }
    f.show()
    let initial = await observe { f.shows(.red) }
    try #require(initial)
    let before = f.counter.count(for: "asset-detail-body")
    f.manager.invalidateCache(changedThumbnailAssetIDs: ["B"])
    let rendered = await observe { f.counter.count(for: "asset-detail-body") > before }
    try #require(rendered)
    // Acknowledged render settling is a negative-control barrier, not the race gate.
    try await Task.sleep(for: .milliseconds(30))
    #expect(f.requests == 1)
    #expect(f.shows(.red))
  }

  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func supersededRevisionCannotPublishBeforeReplacementTaskStarts(fails: Bool) async {
    let loader = AssetDetailImageLoader()
    let service = FakePhotoLibraryService()
    let gate = AsyncCheckpoint()
    var revision = 0
    service.fullImageRequestOverride = { _ in
      await gate.enter()
      if fails { throw CocoaError(.fileReadUnknown) }
      return Self.image(.red)
    }
    let captured = revision
    let old = Task {
      await loader.load(for: "A", using: service, isCurrent: { revision == captured })
    }
    await gate.waitForEnter(count: 1)
    revision += 1
    await gate.releaseAll()
    await old.value  // No new load or Task cancellation to mask a missing revision guard.
    #expect(loader.state.image == nil)
    #expect(loader.state.errorMessage == nil)
    loader.clear()
  }

  @Test(.timeLimit(.minutes(1)))
  func alreadyStaleCallCannotInvalidateAnActiveRequest() async {
    let loader = AssetDetailImageLoader()
    let service = FakePhotoLibraryService()
    let gate = AsyncCheckpoint()
    let red = Self.image(.red)
    var calls = 0
    service.fullImageRequestOverride = { id in
      calls += 1
      if id == "A" { await gate.enter() }
      return red
    }
    let active = Task { await loader.load(for: "A", using: service) }
    await gate.waitForEnter(count: 1)
    await loader.load(for: "stale", using: service, isCurrent: { false })
    #expect(calls == 1)
    #expect(loader.state.assetId == "A")
    #expect(loader.state.isLoading)
    await gate.releaseAll()
    await active.value
    #expect(loader.state.image === red)
  }

  @Test(.timeLimit(.minutes(1)))
  func currentReplacementRetainsImageThenShowsFailureAndCanRecover() async throws {
    let loader = AssetDetailImageLoader()
    let service = FakePhotoLibraryService()
    let gate = AsyncCheckpoint()
    let red = Self.image(.red)
    let blue = Self.image(.blue)
    service.fullImagesByAssetId["A"] = red
    await loader.load(for: "A", using: service)
    service.fullImageRequestOverride = { _ in
      await gate.enter()
      throw NSError(
        domain: "Preview", code: 1, userInfo: [NSLocalizedDescriptionKey: "Preview offline"])
    }
    let replacement = Task { await loader.load(for: "A", using: service) }
    await gate.waitForEnter(count: 1)
    #expect(loader.state.image === red)
    #expect(loader.state.isLoading)
    await gate.releaseAll()
    await replacement.value
    #expect(loader.state.image == nil, "Current error must not be hidden under a retained image")
    #expect(loader.state.errorMessage?.contains("Preview offline") == true)
    #expect(!loader.state.isLoading)
    service.fullImageRequestOverride = { _ in blue }
    await loader.load(for: "A", using: service)
    #expect(loader.state.image === blue)
    #expect(loader.state.errorMessage == nil)
  }
}
