import AppKit
import Foundation
import Testing

@testable import Photo_Export

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct AssetDetailImageLoaderTests {
  @Test(arguments: [false, true], [false, true])
  func lateSuccessOrFailureCannotReplaceNewerPreview(oldFails: Bool, sameAsset: Bool) async {
    let loader = AssetDetailImageLoader()
    let service = FakePhotoLibraryService()
    let oldGate = AsyncCheckpoint()
    let newImage = NSImage(size: NSSize(width: 20, height: 20))
    var requestCount = 0
    service.fullImageRequestOverride = { _ in
      requestCount += 1
      if requestCount == 1 {
        await oldGate.enter()
        if oldFails { throw NSError(domain: "OldRequest", code: 1) }
        return NSImage(size: NSSize(width: 10, height: 10))
      }
      return newImage
    }
    let old = Task { await loader.load(for: "A", using: service) }
    await oldGate.waitForEnter(count: 1)
    let newId = sameAsset ? "A" : "B"
    await loader.load(for: newId, using: service)
    await oldGate.releaseAll()
    await old.value  // Provider deliberately ignores cancellation.
    #expect(loader.state.assetId == newId)
    #expect(loader.state.image === newImage)
    #expect(loader.state.errorMessage == nil)
    #expect(!loader.state.isLoading)
  }

  @Test(arguments: [false, true])
  func obsoleteCompletionCannotStopNewRequestSpinner(oldFails: Bool) async {
    let loader = AssetDetailImageLoader()
    let service = FakePhotoLibraryService()
    let oldGate = AsyncCheckpoint()
    let newGate = AsyncCheckpoint()
    service.fullImageRequestOverride = { id in
      await (id == "A" ? oldGate : newGate).enter()
      if id == "A", oldFails { throw NSError(domain: "OldRequest", code: 1) }
      return NSImage(size: NSSize(width: 10, height: 10))
    }
    let old = Task { await loader.load(for: "A", using: service) }
    await oldGate.waitForEnter(count: 1)
    let new = Task { await loader.load(for: "B", using: service) }
    await newGate.waitForEnter(count: 1)
    await oldGate.releaseAll()
    await old.value
    #expect(loader.state.assetId == "B")
    #expect(loader.state.isLoading)
    #expect(loader.state.image == nil)
    #expect(loader.state.errorMessage == nil)
    await newGate.releaseAll()
    await new.value
  }

  @Test(arguments: [false, true])
  func cancelledLoadCannotCommitImageOrError(fails: Bool) async {
    let loader = AssetDetailImageLoader()
    let service = FakePhotoLibraryService()
    let gate = AsyncCheckpoint()
    service.fullImageRequestOverride = { _ in
      await gate.enter()
      if fails { throw NSError(domain: "CancelledProvider", code: 1) }
      return NSImage(size: NSSize(width: 10, height: 10))
    }
    let task = Task { await loader.load(for: "A", using: service) }
    await gate.waitForEnter(count: 1)
    task.cancel()
    await gate.releaseAll()
    await task.value
    #expect(loader.state.image == nil)
    #expect(loader.state.errorMessage == nil)
    #expect(!loader.state.isLoading)
  }

  @Test func clearingSelectionInvalidatesOutstandingRequest() async {
    let loader = AssetDetailImageLoader()
    let service = FakePhotoLibraryService()
    let gate = AsyncCheckpoint()
    service.fullImageRequestOverride = { _ in
      await gate.enter()
      return NSImage(size: NSSize(width: 10, height: 10))
    }
    let task = Task { await loader.load(for: "A", using: service) }
    await gate.waitForEnter(count: 1)
    loader.clear()
    await gate.releaseAll()
    await task.value
    #expect(loader.state.assetId == nil)
    #expect(loader.state.image == nil)
    #expect(!loader.state.isLoading)
  }

  @Test func newSelectionDoesNotDisplayPriorImageBeforeTaskStarts() async {
    let loader = AssetDetailImageLoader()
    let service = FakePhotoLibraryService()
    service.fullImagesByAssetId["A"] = NSImage(size: NSSize(width: 10, height: 10))
    await loader.load(for: "A", using: service)
    #expect(loader.state(for: "A").image != nil)
    #expect(loader.state(for: "B").image == nil)
    #expect(loader.state(for: "B").isLoading)
    await loader.load(for: nil, using: service)
    #expect(loader.state.assetId == nil)
    #expect(!loader.state.isLoading)
  }

  @Test func degradedPreviewIsDisplayedBeforeFinalAndLateCallbacksAreIgnored() async {
    let loader = AssetDetailImageLoader()
    let service = FakePhotoLibraryService()
    let gate = AsyncCheckpoint()
    let degraded = NSImage(size: NSSize(width: 20, height: 20))
    let final = NSImage(size: NSSize(width: 40, height: 40))
    var callback: (@MainActor (NSImage) -> Void)?
    service.previewOverride = { _, _, onDegraded in
      callback = onDegraded
      onDegraded(degraded)
      await gate.enter()
      return final
    }
    let task = Task { await loader.load(for: "A", using: service) }
    await gate.waitForEnter(count: 1)
    #expect(loader.state.image === degraded)
    #expect(loader.state.isLoading)
    await gate.releaseAll()
    await task.value
    callback?(degraded)
    #expect(loader.state.image === final)
    #expect(!loader.state.isLoading)
  }

  @Test(arguments: [false, true])
  func cancelledOrRevisedDegradedCallbackCannotPublish(revised: Bool) async {
    let loader = AssetDetailImageLoader()
    let service = FakePhotoLibraryService()
    let gate = AsyncCheckpoint()
    let late = NSImage(size: NSSize(width: 20, height: 20))
    var callback: (@MainActor (NSImage) -> Void)?
    service.previewOverride = { _, _, onDegraded in
      callback = onDegraded
      await gate.enter()
      return late
    }
    var revision = 0
    let task = Task { await loader.load(for: "A", using: service, isCurrent: { revision == 0 }) }
    await gate.waitForEnter(count: 1)
    let probe = ObservationProbe { _ = loader.state }
    if revised { revision += 1 } else { task.cancel() }
    callback?(late)
    #expect(probe.changeCount == 0)
    #expect(loader.state.image == nil)
    loader.clear()
    callback?(late)
    #expect(loader.state.image == nil)
    await gate.releaseAll()
    await task.value
  }

  @Test(arguments: [CGSize(width: 8000, height: 6000), CGSize(width: 300, height: 600)])
  func previewSizePreservesPaneAspectAndCapsLongestEdge(points: CGSize) {
    let size = AssetDetailView.previewPixelSize(points: points, scale: 2)
    #expect(max(size.width, size.height) <= 2560)
    #expect(abs(size.width / size.height - points.width / points.height) < 0.002)
    if points.width < 1000 { #expect(size == CGSize(width: 600, height: 1200)) }
  }

  @Test func screenshotPreviewReturnsSyntheticPixelsAtRequestedSize() async throws {
    let service = ScreenshotPhotoLibraryService()
    let size = CGSize(width: 400, height: 300)
    let image = try await service.requestPreview(
      for: "detail-preview-placeholder", pixelSize: size, onDegraded: { _ in })
    #expect(image.size == size)
    #expect(image.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil)
  }

  @Test func cachedThumbnailIsVisibleWhilePreviewIsPending() async {
    let loader = AssetDetailImageLoader()
    let service = FakePhotoLibraryService()
    let cached = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
      NSColor.red.setFill()
      rect.fill()
      return true
    }
    service.thumbnailsByAssetId["A"] = cached
    let gate = AsyncCheckpoint()
    service.fullImageRequestOverride = { _ in
      await gate.enter()
      return NSImage(size: NSSize(width: 40, height: 40))
    }
    let task = Task { await loader.load(for: "A", using: service) }
    await gate.waitForEnter(count: 1)
    #expect(loader.state.image != nil)
    #expect(loader.state.isLoading)
    await gate.releaseAll()
    await task.value
  }

  @Test func currentFailureIsVisibleButCancellationIsNot() async {
    let loader = AssetDetailImageLoader()
    let service = FakePhotoLibraryService()
    service.requestFullImageError = NSError(
      domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
      userInfo: [NSLocalizedDescriptionKey: "The internet connection is offline."])
    await loader.load(for: "A", using: service)
    #expect(loader.state.errorMessage?.contains("offline") == true)
    #expect(!loader.state.isLoading)
    service.requestFullImageError = CancellationError()
    await loader.load(for: "A", using: service)
    #expect(loader.state.errorMessage == nil)
    #expect(!loader.state.isLoading)
  }

  /// `AssetDetailView` renders `state(for:)`, so each step of a load re-renders it: the
  /// spinner, the image, and clearing on disappear.
  @Test func detailReadersAreNotifiedForEachPreviewStep() async {
    let loader = AssetDetailImageLoader()
    let service = FakePhotoLibraryService()
    service.fullImagesByAssetId["A"] = NSImage(size: NSSize(width: 10, height: 10))
    let probe = ObservationProbe { _ = loader.state(for: "A") }
    await loader.load(for: "A", using: service)
    #expect(probe.changeCount == 2)
    loader.clear()
    #expect(probe.changeCount == 3)
  }

  /// A response the newer request superseded writes nothing, so it does not re-render the
  /// detail view; the request token itself is not view state.
  @Test func supersededResponseDoesNotNotifyDetailReaders() async {
    let loader = AssetDetailImageLoader()
    let service = FakePhotoLibraryService()
    let oldGate = AsyncCheckpoint()
    service.fullImageRequestOverride = { id in
      if id == "A" { await oldGate.enter() }
      return NSImage(size: NSSize(width: 10, height: 10))
    }
    let old = Task { await loader.load(for: "A", using: service) }
    await oldGate.waitForEnter(count: 1)
    await loader.load(for: "B", using: service)
    let probe = ObservationProbe { _ = loader.state(for: "B") }
    await oldGate.releaseAll()
    await old.value
    #expect(probe.changeCount == 0)
    #expect(loader.state.assetId == "B")
  }
}
