import Foundation
import Photos
import Testing

@testable import Photo_Export

@Suite(.timeLimit(.minutes(2)))
struct PhotoKitResourceSessionTests {
  private final class Lifetime {
    let released: LockedBox<Int>
    init(_ released: LockedBox<Int>) { self.released = released }
    deinit { released.mutate { $0 += 1 } }
  }

  private func descriptors() -> [ResourceDescriptor] {
    [
      .init(type: .photo, originalFilename: "original.jpg", fileSize: 3),
      .init(type: .fullSizePhoto, originalFilename: "edited.jpg", fileSize: 3),
      .init(type: .pairedVideo, originalFilename: "original.mov", fileSize: 3),
      .init(type: .fullSizePairedVideo, originalFilename: "edited.mov", fileSize: 3),
    ]
  }

  @Test func oneResolutionServesAllVariantResourcesAndPreservesFirstMatchingHandle() async throws {
    let fetches = LockedBox(0)
    let enumerations = LockedBox(0)
    let writes = LockedBox<[String]>([])
    let workerChecks = LockedBox<[Bool]>([])
    let resources = descriptors()
    let queue = DispatchQueue(label: "test.resource-session")
    let key = DispatchSpecificKey<Bool>()
    queue.setSpecific(key: key, value: true)
    let owner = ProductionPhotoKitResourceOwner(
      queue: queue,
      backend: .init { id in
        fetches.mutate { $0 += 1 }
        workerChecks.mutate { $0.append(DispatchQueue.getSpecific(key: key) == true) }
        return .init(descriptor: TestAssetFactory.makeAsset(id: id)) {
          enumerations.mutate { $0 += 1 }
          workerChecks.mutate { $0.append(DispatchQueue.getSpecific(key: key) == true) }
          return (resources + [resources[0]]).enumerated().map { index, descriptor in
            .init(descriptor: descriptor) { url, completion in
              workerChecks.mutate { $0.append(DispatchQueue.getSpecific(key: key) == true) }
              writes.mutate { $0.append("\(index):\(descriptor.originalFilename)") }
              do {
                try Data("\(index)".utf8).write(to: url)
                completion(nil)
              } catch { completion(error) }
            }
          }
        }
      })
    let reader = ProductionPhotoKitReader(resourceOwner: owner)
    let snapshot = try #require(await reader.readAsset(id: "asset", livePhotosPaired: true))
    let writer = try #require(snapshot.resourceWriter)
    let root = TestScratch.directory("ResourceSessionVariants")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for (index, resource) in snapshot.resources.prefix(4).enumerated() {
      let url = root.appendingPathComponent("\(index)")
      try await writer.writeResource(resource, forAssetId: "asset", to: url)
      #expect(try String(contentsOf: url, encoding: .utf8) == "\(index)")
    }
    // A fallback resource write reuses the same snapshot and first matching handle.
    try await writer.writeResource(resources[0], forAssetId: "asset", to: root.appendingPathComponent("fallback"))
    await writer.close()
    #expect(fetches.value == 1)
    #expect(enumerations.value == 1)
    #expect(writes.value == ["0:original.jpg", "1:edited.jpg", "2:original.mov", "3:edited.mov", "0:original.jpg"])
    #expect(workerChecks.value.count == 7)
    #expect(workerChecks.value.allSatisfy { $0 })
  }

  @Test func replacementJobGetsFreshHandlesAndOldCloseCannotAffectIt() async throws {
    let fetches = LockedBox(0)
    let writes = LockedBox<[Int]>([])
    let resource = descriptors()[0]
    let owner = ProductionPhotoKitResourceOwner(backend: .init { id in
      fetches.mutate { $0 += 1 }
      let identity = fetches.value
      return .init(descriptor: TestAssetFactory.makeAsset(id: id)) {
        [.init(descriptor: resource) { _, completion in
          writes.mutate { $0.append(identity) }
          completion(nil)
        }]
      }
    })
    let reader = ProductionPhotoKitReader(resourceOwner: owner)
    let oldSnapshot = try #require(await reader.readAsset(id: "same", livePhotosPaired: false))
    let newSnapshot = try #require(await reader.readAsset(id: "same", livePhotosPaired: false))
    let old = try #require(oldSnapshot.resourceWriter)
    let replacement = try #require(newSnapshot.resourceWriter)
    await old.close()
    await old.close()
    let url = TestScratch.directory("ResourceSessionReplacement").appendingPathComponent("output")
    await #expect(throws: (any Error).self) {
      try await old.writeResource(resource, forAssetId: "same", to: url)
    }
    await #expect(throws: (any Error).self) {
      try await replacement.writeResource(resource, forAssetId: "other", to: url)
    }
    await #expect(throws: (any Error).self) {
      try await replacement.writeResource(.init(type: .video, originalFilename: resource.originalFilename), forAssetId: "same", to: url)
    }
    try await replacement.writeResource(resource, forAssetId: "same", to: url)
    await old.close()
    try await replacement.writeResource(resource, forAssetId: "same", to: url)
    await replacement.close()
    #expect(fetches.value == 2)
    #expect(writes.value == [2, 2])
  }

  @Test(arguments: [false, true])
  func canceledClosedSessionRetainsHandlesUntilPhysicalCallback(fails: Bool) async throws {
    let released = LockedBox(0)
    let returned = LockedBox(false)
    let callback = LockedBox<(@Sendable (Error?) -> Void)?>(nil)
    let entered = AsyncCheckpoint()
    let resource = descriptors()[0]
    let owner = ProductionPhotoKitResourceOwner(backend: .init { id in
      let lifetime = Lifetime(released)
      return .init(descriptor: TestAssetFactory.makeAsset(id: id)) {
        [.init(descriptor: resource) { [lifetime] _, completion in
          _ = lifetime
          callback.mutate { $0 = completion }
          Task { await entered.enter() }
        }]
      }
    })
    let snapshot = try #require(await owner.readAsset(id: "held", livePhotosPaired: false))
    let writer = try #require(snapshot.resourceWriter)
    let url = TestScratch.directory("ResourceSessionHeld").appendingPathComponent("held")
    let task = Task {
      defer { returned.mutate { $0 = true } }
      do {
        try await writer.writeResource(resource, forAssetId: "held", to: url)
        return Result<Void, Error>.success(())
      } catch { return Result<Void, Error>.failure(error) }
    }
    try #require(await entered.waitForEnter(count: 1))
    task.cancel()
    await writer.close()
    #expect(released.value == 0)
    #expect(!returned.value)
    let finish = try #require(callback.value)
    callback.mutate { $0 = nil }
    finish(fails ? NSError(domain: "test.resource", code: 9) : nil)
    let result = await task.value
    if fails {
      guard case .failure = result else { Issue.record("The physical error must be preserved"); return }
    } else {
      guard case .success = result else { Issue.record("Cancellation must still await physical success"); return }
    }
    #expect(released.value == 1)
    #expect(returned.value)
    await entered.releaseAll()
  }
}
