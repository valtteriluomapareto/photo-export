import Darwin
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
    try await writer.writeResource(
      resources[0], forAssetId: "asset", to: root.appendingPathComponent("fallback"))
    await writer.close()
    #expect(fetches.value == 1)
    #expect(enumerations.value == 1)
    #expect(
      writes.value == [
        "0:original.jpg", "1:edited.jpg", "2:original.mov", "3:edited.mov", "0:original.jpg",
      ])
    #expect(workerChecks.value.count == 7)
    #expect(workerChecks.value.allSatisfy { $0 })
  }

  @Test func replacementJobGetsFreshHandlesAndOldCloseCannotAffectIt() async throws {
    let fetches = LockedBox(0)
    let writes = LockedBox<[Int]>([])
    let resource = descriptors()[0]
    let owner = ProductionPhotoKitResourceOwner(
      backend: .init { id in
        fetches.mutate { $0 += 1 }
        let identity = fetches.value
        return .init(descriptor: TestAssetFactory.makeAsset(id: id)) {
          [
            .init(descriptor: resource) { _, completion in
              writes.mutate { $0.append(identity) }
              completion(nil)
            }
          ]
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
      try await replacement.writeResource(
        .init(type: .video, originalFilename: resource.originalFilename), forAssetId: "same",
        to: url)
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
    let owner = ProductionPhotoKitResourceOwner(
      backend: .init { id in
        let lifetime = Lifetime(released)
        return .init(descriptor: TestAssetFactory.makeAsset(id: id)) {
          [
            .init(descriptor: resource) { [lifetime] _, completion in
              _ = lifetime
              callback.mutate { $0 = completion }
              Task { await entered.enter() }
            }
          ]
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
      guard case .failure = result else {
        Issue.record("The physical error must be preserved")
        return
      }
    } else {
      guard case .success = result else {
        Issue.record("Cancellation must still await physical success")
        return
      }
    }
    #expect(released.value == 1)
    #expect(returned.value)
    await entered.releaseAll()
  }

  @MainActor
  @Test(arguments: ["paired", "reuse-fallback", "edited-fallback"])
  func exportJobUsesResolvedWriterThroughVariantsAndFallbacks(route: String) async throws {
    let fetches = LockedBox(0)
    let enumerations = LockedBox(0)
    let writes = LockedBox<[String]>([])
    let released = LockedBox(0)
    let date = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 15))
    let asset = TestAssetFactory.makeAsset(
      id: "session-export", creationDate: date, hasAdjustments: route != "reuse-fallback",
      isLivePhoto: route == "paired")
    let resources = route == "paired" ? descriptors() : [descriptors()[0]]
    let owner = ProductionPhotoKitResourceOwner(
      backend: .init { _ in
        fetches.mutate { $0 += 1 }
        let lifetime = Lifetime(released)
        return .init(descriptor: asset) {
          enumerations.mutate { $0 += 1 }
          return resources.map { descriptor in
            .init(descriptor: descriptor) { [lifetime] url, completion in
              _ = lifetime
              writes.mutate { $0.append(descriptor.originalFilename) }
              do {
                try Data("job".utf8).write(to: url)
                completion(nil)
              } catch { completion(error) }
            }
          }
        }
      })
    let reader = ProductionPhotoKitReader(resourceOwner: owner)
    let h = await ExportManagerHarness(label: "JobResourceSession", photoKitReader: reader)
    defer {
      h.manager.cancelAndClear()
      h.store.drainSynchronously()
      h.collectionStore.drainSynchronously()
      h.dest.cleanup()
      try? FileManager.default.removeItem(at: h.storeRoot)
    }
    h.photoLib.assetsByYearMonth["2026-1"] = [asset]
    h.photoLib.favoritesAssets = [asset]
    h.manager.livePhotosPairedExport = route == "paired"
    h.manager.versionSelection = route == "paired" ? .editedWithOriginals : .edited
    if route == "reuse-fallback" {
      _ = try h.dest.urlForRelativeDirectory("2026/01/", createIfNeeded: true)
      h.store.markVariantExported(
        assetId: asset.id, variant: .original, year: 2026, month: 1, relPath: "2026/01/",
        filename: "missing.jpg", exportedAt: Date())
      h.manager.startExportFavorites()
    } else {
      h.manager.startExportMonth(year: 2026, month: 1)
    }
    await h.manager.waitForQueueDrained()
    #expect(h.writer.writeCalls.isEmpty, "The job must use its captured production resource owner")
    #expect(fetches.value == 1)
    #expect(enumerations.value == 1)
    #expect(writes.value.count == (route == "paired" ? 4 : 1))
    #expect(released.value == 1, "The drained job must have awaited resource release")
    if route == "reuse-fallback" {
      #expect(h.fileSystem.copyCalls.count == 1)
    } else {
      #expect(h.fileSystem.moveCalls.count == (route == "paired" ? 4 : 1))
    }
  }

  @MainActor
  @Test(arguments: [Int32(0), ENOENT, EIO])
  func heicResourceWriteFailureStillExportsTheOriginal(errorCode: Int32) async throws {
    let asset = TestAssetFactory.makeAsset(
      id: "heic-source-error",
      creationDate: Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 15))!,
      hasAdjustments: true, originalUTI: "public.heic")
    let original = ResourceDescriptor(type: .photo, originalFilename: "ORIGINAL.HEIC")
    let edited = ResourceDescriptor(type: .fullSizePhoto, originalFilename: "EDITED.HEIC")
    let writes = LockedBox<[URL]>([])
    let owner = ProductionPhotoKitResourceOwner(
      backend: .init { _ in
        .init(descriptor: asset) {
          [original, edited].map { resource in
            .init(descriptor: resource) { url, completion in
              writes.mutate { $0.append(url) }
              if resource.type == .fullSizePhoto && errorCode != 0 {
                completion(NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode)))
              } else {
                do {
                  try Data("source".utf8).write(to: url)
                  completion(nil)
                } catch { completion(error) }
              }
            }
          }
        }
      })
    let converter = FakeImageConverter()
    let h = await ExportManagerHarness(
      label: "HEICResourceFailure", photoKitReader: ProductionPhotoKitReader(resourceOwner: owner),
      imageConverter: converter)
    defer {
      h.manager.cancelAndClear()
      h.store.drainSynchronously()
      h.collectionStore.drainSynchronously()
      h.dest.cleanup()
      try? FileManager.default.removeItem(at: h.storeRoot)
    }
    h.photoLib.assetsByYearMonth["2026-1"] = [asset]
    h.manager.versionSelection = .edited
    h.manager.convertHEICToJPEG = true
    h.manager.startExportMonth(year: 2026, month: 1)
    await h.manager.waitForQueueDrained()
    let record = try #require(h.store.exportInfo(assetId: asset.id))
    if errorCode == 0 {
      #expect(record.variants[.edited]?.status == .done)
      #expect(record.variants[.original] == nil)
      #expect(converter.convertCalls.count == 1)
      #expect(writes.value.count == 1)
    } else {
      #expect(record.variants[.edited]?.reason == .editedUnavailableOriginalBackedUp)
      #expect(record.variants[.original]?.status == .done)
      #expect(record.variants[.original]?.filename == "ORIGINAL_orig.HEIC")
      #expect(converter.convertCalls.isEmpty)
      #expect(writes.value.count == 2)
    }
    #expect(h.store.isExported(asset: asset, selection: .edited, livePhotosPaired: false))
    #expect(!FileManager.default.fileExists(atPath: try #require(writes.value.first).path))
    #expect(h.writer.writeCalls.isEmpty)
  }

  private struct HeldReader: PhotoKitReading {
    let base: ProductionPhotoKitReader
    let checkpoint: AsyncCheckpoint?
    func readAsset(id: String, livePhotosPaired: Bool) async -> PhotoKitAssetSnapshot? {
      let snapshot = await base.readAsset(id: id, livePhotosPaired: livePhotosPaired)
      if let checkpoint { await checkpoint.enter() }
      return snapshot
    }
  }

  @MainActor
  @Test(arguments: ["already-done", "stale-metadata", "write-failed"])
  func terminalJobPathsReleaseResolvedHandles(route: String) async throws {
    let released = LockedBox(0)
    let writes = LockedBox(0)
    let gate = AsyncCheckpoint()
    let resource = descriptors()[0]
    let asset = TestAssetFactory.makeAsset(id: "terminal-job")
    let owner = ProductionPhotoKitResourceOwner(
      backend: .init { _ in
        let lifetime = Lifetime(released)
        return .init(descriptor: asset) {
          [
            .init(descriptor: resource) { [lifetime] _, completion in
              _ = lifetime
              writes.mutate { $0 += 1 }
              completion(NSError(domain: "test.resource", code: 9))
            }
          ]
        }
      })
    let reader = HeldReader(
      base: ProductionPhotoKitReader(resourceOwner: owner),
      checkpoint: route == "stale-metadata" ? gate : nil)
    let h = await ExportManagerHarness(label: "ResourceSessionTerminal", photoKitReader: reader)
    defer {
      h.manager.cancelAndClear()
      h.store.drainSynchronously()
      h.collectionStore.drainSynchronously()
      h.dest.cleanup()
      try? FileManager.default.removeItem(at: h.storeRoot)
    }
    if route == "already-done" {
      h.store.markVariantExported(
        assetId: asset.id, variant: .original, year: 2026, month: 1, relPath: "2026/01/",
        filename: "original.jpg", exportedAt: Date())
    }
    let generation = h.manager.generation
    let job = ExportManager.ExportJob(
      assetLocalIdentifier: asset.id, placement: .timeline(year: 2026, month: 1),
      selection: .edited)
    let task = Task { await h.manager.performExport(job: job, generation: generation) }
    if route == "stale-metadata" {
      try #require(await gate.waitForEnter(count: 1))
      h.manager.cancelAndClear()
      await gate.releaseAll()
    }
    await task.value
    #expect(released.value == 1)
    #expect(writes.value == (route == "write-failed" ? 1 : 0))
    #expect(h.writer.writeCalls.isEmpty)
    #expect(h.fileSystem.moveCalls.isEmpty)
    #expect(h.dest.beginScopedAccessCount == h.dest.endScopedAccessCount)
    await gate.releaseAll()
  }

}
