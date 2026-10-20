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

  // No init-service test, unlike the grid models: the loader holds no service.

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
