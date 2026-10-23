import Foundation
import Photos
import Testing

@testable import Photo_Export

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct PhotoKitReaderTests {
  @Test func completedJobAvoidsMainActorMetadataServiceCalls() async throws {
    let asset = makeAsset()
    let resources = [ResourceDescriptor(type: .photo, originalFilename: "READER.JPG", fileSize: 12)]
    let io = RecordingDestinationIO()
    let calls = LockedBox<[String]>([])
    let reader = ProductionPhotoKitReader(io: io) { id, _ in
      calls.mutate { $0.append(id) }
      return PhotoKitAssetSnapshot(descriptor: asset, resources: resources)
    }
    let h = ExportManagerHarness(label: "ExportPhotoKitReader", photoKitReader: reader)
    defer {
      h.manager.cancelAndClear()
      h.store.drainSynchronously()
      h.collectionStore.drainSynchronously()
      h.dest.cleanup()
      try? FileManager.default.removeItem(at: h.storeRoot)
    }
    h.photoLib.assetsByYearMonth["2025-4"] = [asset]
    h.photoLib.resourcesByAssetId[asset.id] = resources
    h.manager.startExportMonth(year: 2025, month: 4)
    await h.manager.waitForQueueDrained()
    #expect(h.writer.writeCalls.count == 1, "The completed job is the positive control")
    #expect(h.store.exportInfo(assetId: asset.id)?.variants[.original]?.status == .done)
    #expect(h.photoLib.descriptorFetchCalls.isEmpty)
    #expect(h.photoLib.resourcesCallCounts.isEmpty)
    #expect(calls.value == [asset.id])
    #expect(!io.workerChecks.value.isEmpty)
    #expect(io.workerChecks.value.allSatisfy { $0 })
    #expect(!h.fileSystem.calls.isEmpty)
    #expect(h.fileSystem.calls.allSatisfy { !$0.onMainThread })
  }

  private func makeAsset() -> AssetDescriptor {
    TestAssetFactory.makeAsset(
      id: "reader-asset",
      creationDate: Calendar.current.date(from: DateComponents(year: 2025, month: 4, day: 15)))
  }

  private final class Gate: @unchecked Sendable {
    let entered = AsyncCheckpoint()
    private let semaphore = DispatchSemaphore(value: 0)
    func hold() {
      Task { await entered.enter() }
      semaphore.wait()
    }
    func release() { semaphore.signal() }
  }

  @Test func productionReaderSerializesLeavesAndWaitsForPhysicalCompletion() async throws {
    let gate = Gate()
    let io = RecordingDestinationIO()
    let order = LockedBox<[String]>([])
    let returned = LockedBox(false)
    let asset = makeAsset()
    let reader = ProductionPhotoKitReader(io: io) { id, _ in
      order.mutate { $0.append(id) }
      if id == "held" {
        gate.hold()
        order.mutate { $0.append("physical completion") }
      }
      return PhotoKitAssetSnapshot(descriptor: asset, resources: [])
    }
    let first = Task {
      let value = await reader.readAsset(id: "held", livePhotosPaired: false)
      returned.mutate { $0 = true }
      return value
    }
    defer { gate.release() }
    try #require(await gate.entered.waitForEnter(count: 1))
    let second = Task { await reader.readAsset(id: "second", livePhotosPaired: false) }
    try #require(await eventually("second reader leaf admitted") { io.submissions.value == 2 })
    first.cancel()
    #expect(order.value == ["held"])
    #expect(!returned.value)
    gate.release()
    #expect(await first.value?.descriptor == asset)
    #expect(await second.value?.descriptor == asset)
    #expect(order.value == ["held", "physical completion", "second"])
    #expect(returned.value)
    #expect(io.workerChecks.value == [true, true])
    await gate.entered.releaseAll()
  }

  enum Invalidation: CaseIterable { case cancel, root, history }

  @Test(arguments: Invalidation.allCases)
  func heldReaderCannotAuthorizeChangedExport(invalidation: Invalidation) async throws {
    let gate = Gate()
    let asset = makeAsset()
    let reader = ProductionPhotoKitReader { _, _ in
      gate.hold()
      return PhotoKitAssetSnapshot(
        descriptor: asset,
        resources: [.init(type: .photo, originalFilename: "READER.JPG", fileSize: 12)])
    }
    let h = ExportManagerHarness(label: "HeldPhotoKitReader", photoKitReader: reader)
    try await withCleanup {
      h.photoLib.assetsByYearMonth["2025-4"] = [asset]
      h.manager.startExportMonth(year: 2025, month: 4)
      try #require(await gate.entered.waitForEnter(count: 1))
      let old = try #require(h.manager.currentTask)
      #expect(h.dest.beginScopedAccessCount == 0)
      switch invalidation {
      case .cancel: h.manager.cancelAndClear()
      case .root: h.dest.selectedFolderURL = h.dest.rootURL.appendingPathComponent("replacement")
      case .history:
        h.store.configure(for: "replacement")
        h.collectionStore.configure(for: "replacement")
      }
      gate.release()
      await old.value
      #expect(h.dest.beginScopedAccessCount == 0)
      #expect(h.writer.writeCalls.isEmpty)
      #expect(h.fileSystem.calls.isEmpty)
      #expect(h.store.exportInfo(assetId: asset.id) == nil)
      #expect(h.dest.beginScopedAccessCount == h.dest.endScopedAccessCount)
    } cleanup: {
      gate.release()
      h.manager.cancelAndClear()
      h.store.drainSynchronously()
      h.collectionStore.drainSynchronously()
      h.dest.cleanup()
      try? FileManager.default.removeItem(at: h.storeRoot)
      await gate.entered.releaseAll()
    }
  }

  @Test func publicUTIsFollowOriginalResourceSelection() {
    let asset = makeAsset()
    let cases: [([ResourceDescriptor], String)] = [
      (
        [
          .init(
            type: .fullSizePhoto, originalFilename: "edit.JPG", uniformTypeIdentifier: "public.jpeg"
          ),
          .init(type: .photo, originalFilename: "orig.HEIC", uniformTypeIdentifier: "public.heic"),
        ], "public.heic"
      ),
      (
        [
          .init(
            type: .alternatePhoto, originalFilename: "alt.JPG", uniformTypeIdentifier: "public.jpeg"
          ),
          .init(
            type: .photo, originalFilename: "orig.DNG", uniformTypeIdentifier: "com.adobe.raw-image"
          ),
        ], "com.adobe.raw-image"
      ),
      (
        [
          .init(
            type: .alternatePhoto, originalFilename: "orig.DNG",
            uniformTypeIdentifier: "com.adobe.raw-image")
        ], "com.adobe.raw-image"
      ),
      (
        [.init(type: .photo, originalFilename: "orig.HEIF", uniformTypeIdentifier: "public.heif")],
        "public.heif"
      ),
    ]
    for (resources, expected) in cases {
      let value = PhotoKitAssetSnapshot.mapping(
        asset, resources: resources, livePhotosPaired: false)
      #expect(value.descriptor.originalUTI == expected)
      #expect(value.resources == resources)
      #expect(
        ResourceSelection.selectProducer(
          variant: .original, from: value.resources,
          descriptor: value.descriptor)
          == .resource(
            ResourceSelection.selectOriginalResource(from: resources, mediaType: .image)!))
    }
    let video = TestAssetFactory.makeAsset(id: "video", mediaType: .video)
    let resources = [
      ResourceDescriptor(
        type: .fullSizeVideo, originalFilename: "edit.MOV", uniformTypeIdentifier: "edited.video"),
      ResourceDescriptor(
        type: .video, originalFilename: "orig.MOV",
        uniformTypeIdentifier: "com.apple.quicktime-movie"),
    ]
    #expect(
      PhotoKitAssetSnapshot.mapping(
        video, resources: resources,
        livePhotosPaired: true
      ).descriptor.originalUTI == "com.apple.quicktime-movie")
  }

  @Test func livePhotoResourceFallbackKeepsItsToggleAndMediaKind() {
    for type: PHAssetResourceType in [.pairedVideo, .fullSizePairedVideo] {
      let resources = [ResourceDescriptor(type: type, originalFilename: "motion.MOV")]
      #expect(
        PhotoKitAssetSnapshot.mapping(
          makeAsset(), resources: resources,
          livePhotosPaired: true
        ).descriptor.isLivePhoto)
      #expect(
        !PhotoKitAssetSnapshot.mapping(
          makeAsset(), resources: resources,
          livePhotosPaired: false
        ).descriptor.isLivePhoto)
      let video = TestAssetFactory.makeAsset(id: "video", mediaType: .video)
      #expect(
        !PhotoKitAssetSnapshot.mapping(
          video, resources: resources,
          livePhotosPaired: true
        ).descriptor.isLivePhoto)
    }
    let live = TestAssetFactory.makeAsset(id: "live", isLivePhoto: true)
    #expect(
      PhotoKitAssetSnapshot.mapping(live, resources: [], livePhotosPaired: false).descriptor
        .isLivePhoto)
  }

  @Test func resourceSizeMappingPreservesKnownPositiveAndUnknownValues() {
    func resource(_ value: Any?) -> ResourceDescriptor {
      ProductionPhotoKitReader.resourceDescriptor(
        type: .pairedVideo, filename: "motion.MOV", uniformTypeIdentifier: "public.movie",
        sizeValue: value)
    }
    #expect(resource(Int64(12)).fileSize == 12)
    #expect(resource(NSNumber(value: 19)).fileSize == 19)
    for unknown: Any? in [nil, Int64(0), Int64(-1), "12"] {
      #expect(resource(unknown).fileSize == nil)
    }
    #expect(resource(Int64(12)).uniformTypeIdentifier == "public.movie")
  }
}
