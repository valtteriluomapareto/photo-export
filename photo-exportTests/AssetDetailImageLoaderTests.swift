import AppKit
import Foundation
import Testing

@testable import Photo_Export

@MainActor
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
}
