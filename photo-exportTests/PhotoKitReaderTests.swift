import AppKit
import Foundation
import Photos
import SwiftUI
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

  @Test(arguments: [false, true])
  func blockedThumbnailRequestOnlyBlocksMetadataOnSharedExecutor(sharedExecutor: Bool) async throws
  {
    let gate = Gate()
    let io = RecordingDestinationIO()
    let asset = makeAsset()
    let backend = FakeThumbnailBackend(assets: [asset])
    let thumbnailOnMetadataWorker = LockedBox(false)
    backend.requestOverride.mutate {
      $0 = {
        thumbnailOnMetadataWorker.mutate { $0 = io.isOnWorker }
        gate.hold()
      }
    }
    let returned = LockedBox(false)
    let reader = ProductionPhotoKitReader(io: io) { _, _ in
      PhotoKitAssetSnapshot(descriptor: asset, resources: [])
    }
    let thumbnails: any ThumbnailReading
    if sharedExecutor {
      thumbnails = ProductionThumbnailReader(io: io, backend: backend)
    } else {
      thumbnails = ProductionThumbnailReader(backend: backend)
    }
    let thumbnail = Task {
      await thumbnails.image(
        for: .synthetic(asset),
        spec: .init(size: ThumbnailRequestSpec.gridSize, delivery: .highQuality))
    }
    try await withCleanup {
      try #require(await gate.entered.waitForEnter(count: 1))
      #expect(thumbnailOnMetadataWorker.value == sharedExecutor)
      // Release a broken production composition after recording red, so it cannot deadlock the test.
      if !sharedExecutor && thumbnailOnMetadataWorker.value { gate.release() }
      let submittedBeforeMetadata = io.submissions.value
      let metadata = Task {
        let snapshot = await reader.readAsset(id: asset.id, livePhotosPaired: false)
        returned.mutate { $0 = true }
        return snapshot
      }
      try #require(
        await eventually("metadata read admitted") {
          io.submissions.value > submittedBeforeMetadata
        })
      if sharedExecutor {
        #expect(!returned.value, "The held request occupies the shared serial executor")
      } else {
        #expect(
          await eventually("metadata returns while thumbnail request is blocked") { returned.value }
        )
      }
      gate.release()
      #expect(await metadata.value?.descriptor == asset)
      #expect(await thumbnail.value != nil)
    } cleanup: {
      gate.release()
      await gate.entered.releaseAll()
      _ = await thumbnail.value
    }
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
  @Test func thumbnailPreheatAndRequestsUseTheSameOptionsOffMain() async throws {
    let backend = FakeThumbnailBackend(assets: [makeAsset()])
    let reader = ProductionThumbnailReader(backend: backend)
    let handles = await reader.resolveAssets(ids: ["reader-asset"])
    let handle = try #require(handles.first)
    await reader.preheat(start: handles, stop: [])
    for mode in [ThumbnailDeliveryMode.fast, .highQuality] {
      let image = await reader.image(
        for: handle, spec: .init(size: CGSize(width: 256, height: 256), delivery: mode))
      #expect(image?.width == 256)
      #expect(image?.height == 256)
      #expect(image?.colorSpace?.name == CGColorSpace.sRGB)
      let pixels = try #require(image?.dataProvider?.data)
      let bytes = try #require(CFDataGetBytePtr(pixels))
      let offset = 128 * (try #require(image).bytesPerRow) + 128 * 4
      #expect(Array(UnsafeBufferPointer(start: bytes + offset, count: 4)) == [255, 0, 0, 255])
    }
    await reader.preheat(start: [], stop: handles)
    let calls = backend.calls.value
    let requests = calls.filter { $0.action == "request" }.map(\.options)
    #expect(requests.count == 2, "Visible cells still upgrade to high quality")
    for action in ["start", "stop"] {
      let options = calls.filter { $0.action == action }.map(\.options)
      #expect(options.count == 1, "Preheat only the format displayed first")
      #expect(options.first == requests.first, "Preheat matches the first visible request")
    }
    #expect(!calls.isEmpty && calls.allSatisfy { !$0.onMain })
  }

  @Test func overlappingThumbnailWindowsKeepTheirOwnRegistrations() async throws {
    let backend = FakeThumbnailBackend(assets: [makeAsset()])
    let reader = ProductionThumbnailReader(backend: backend)
    let handles = await reader.resolveAssets(ids: ["reader-asset"])
    try #require(!handles.isEmpty)
    await reader.preheat(start: handles, stop: [])
    await reader.preheat(start: handles, stop: [])
    #expect(backend.calls.value.filter { $0.action == "start" }.count == 1)
    await reader.preheat(start: [], stop: handles)
    #expect(backend.calls.value.filter { $0.action == "stop" }.isEmpty)
    await reader.preheat(start: [], stop: handles)
    #expect(backend.calls.value.filter { $0.action == "stop" }.count == 1)
  }

  @Test func coverQuerySetsLimitBeforeBackgroundFetchAndPreservesOrder() async throws {
    let assets = (0..<10).map { TestAssetFactory.makeAsset(id: "cover-\($0)") }
    let backend = FakeThumbnailBackend(assets: assets)
    let reader = ProductionThumbnailReader(backend: backend)
    let covers = try await reader.coverThumbnails(in: .timeline(year: 2025, month: 4), limit: 4)
    #expect(covers.map(\.descriptor.id) == Array(assets.prefix(4)).map(\.id))
    let query = try #require(backend.queries.value.first)
    #expect(query.limit == 4)
    #expect(query.hasPredicate)
    #expect(query.sortKeys == ["creationDate"])
    #expect(!query.onMain)
    let album = try await reader.coverThumbnails(in: .album(collectionId: "album"), limit: 4)
    #expect(album.count == 4)
    #expect(backend.queries.value.count == 2)
  }

  @Test func obsoleteHandleResolutionCannotRegisterOldChangeSnapshots() async throws {
    let asset = makeAsset()
    let backend = FakeThumbnailBackend(assets: [asset])
    let reader = ProductionThumbnailReader(backend: backend)
    let service = FakePhotoLibraryService()
    let manager = PhotoLibraryManager(overrideService: service, thumbnailReader: reader)
    let gate = Gate()
    backend.resolveOverride.mutate { value in
      value = { _ in
        gate.hold()
        return [.synthetic(asset)]
      }
    }
    var registered: [ThumbnailAsset] = []
    manager.thumbnailRegistrationObserver = { registered.append($0) }
    let pending = Task { await manager.resolveThumbnailAssets(ids: [asset.id]) }
    try await withCleanup {
      try #require(await gate.entered.waitForEnter(count: 1))
      manager.invalidateCache(changedThumbnailAssetIDs: [asset.id])
      gate.release()
      #expect(await pending.value.isEmpty)
      #expect(registered.isEmpty)
      backend.resolveOverride.mutate { $0 = nil }
      let fresh = try #require(await manager.resolveThumbnailAssets(ids: [asset.id]).first)
      #expect(fresh.contentRevision == manager.thumbnailContentRevision(for: asset.id))
      let stale = ThumbnailAsset.synthetic(asset)
      #expect(
        await manager.decodedThumbnail(
          for: stale, quantizedSize: ThumbnailRequestSpec.gridSize, deliveryMode: .highQuality)
          == nil)
      #expect(registered.isEmpty)
      #expect(
        await manager.decodedThumbnail(
          for: fresh, quantizedSize: ThumbnailRequestSpec.gridSize, deliveryMode: .highQuality)
          != nil)
      #expect(registered.count == 1)
      #expect(registered.first === fresh)
    } cleanup: {
      gate.release()
      _ = await pending.value
      await gate.entered.releaseAll()
    }
  }

  @Test func resolvedGridHandleSurvivesExportDiscardingLegacyAssetCache() async throws {
    let asset = makeAsset()
    let backend = FakeThumbnailBackend(assets: [asset])
    let reader = ProductionThumbnailReader(backend: backend)
    let manager = PhotoLibraryManager(
      overrideService: FakePhotoLibraryService(), thumbnailReader: reader)
    let map = GridThumbnailAssets(service: manager)
    await map.updateWindow([asset])
    let first = try #require(await map.handle(for: asset.id, revision: 0, isCurrent: { true }))
    manager.forgetPHAssetCache()
    #expect(
      await manager.decodedThumbnail(
        for: first, quantizedSize: ThumbnailRequestSpec.gridSize, deliveryMode: .highQuality) != nil
    )
    await map.deactivate().value
  }

  @Test func screenshotThumbnailReaderStaysSyntheticForUnknownIdentifiers() async throws {
    let service = ScreenshotPhotoLibraryService()
    let year = try #require(try service.availableYears().first)
    let asset = try #require(
      try await service.fetchAssets(year: year, month: nil, mediaType: nil).first)
    let reader = service.thumbnailReader
    let handle = try #require(await reader.resolveAssets(ids: [asset.id]).first)
    #expect(handle.photoKitAsset == nil)
    #expect(
      await reader.image(
        for: handle, spec: .init(size: ThumbnailRequestSpec.gridSize, delivery: .highQuality))
        != nil)
    let unknown = await reader.resolveAssets(ids: ["unknown-synthetic-id"])
    #expect(unknown.allSatisfy { $0.photoKitAsset == nil })
    if let handle = unknown.first {
      #expect(
        await reader.image(
          for: handle,
          spec: .init(size: ThumbnailRequestSpec.gridSize, delivery: .highQuality)) != nil)
    }
  }

  @Test func mountedMonthAndAlbumCoversUseLimitedQueriesAndDecodedTargets() async throws {
    let assets = (0..<10).map { TestAssetFactory.makeAsset(id: "tile-cover-\($0)") }
    let backend = FakeThumbnailBackend(assets: assets)
    let reader = ProductionThumbnailReader(backend: backend)
    let library = PhotoLibraryManager(
      overrideService: FakePhotoLibraryService(), thumbnailReader: reader)
    let album = PhotoCollectionDescriptor(
      id: "album", localIdentifier: "album", title: "Album", kind: .album,
      pathComponents: [], children: [])
    let content = HStack {
      MonthTileView(
        year: 2025, month: 4, photoCount: 10, isFullyExported: false,
        photoLibraryService: library)
      FolderTileView(
        descriptor: album, photoCount: 10, albumCount: 0,
        isFullyExported: false, isSelected: false, photoLibraryService: library)
    }.environment(\.displayScale, 2)
    let window = HostedViewHarness.makeWindow(
      contentRect: NSRect(x: -10_000, y: -10_000, width: 500, height: 350), styleMask: [.borderless]
    )
    window.contentView = NSHostingView(rootView: content)
    defer {
      window.orderOut(nil)
      window.contentView = nil
      window.close()
    }
    window.orderFront(nil)
    try #require(
      await observe(in: window) {
        backend.queries.value.count == 2
          && backend.calls.value.filter { $0.action == "request" }.count == 8
      })
    #expect(backend.queries.value.allSatisfy { $0.limit == 4 && !$0.onMain })
    let requests = backend.calls.value.filter { $0.action == "request" }
    #expect(requests.filter { $0.options.size == CGSize(width: 360, height: 360) }.count == 4)
    #expect(requests.filter { $0.options.size == CGSize(width: 288, height: 288) }.count == 4)
    #expect(
      requests.allSatisfy {
        $0.options.delivery == .highQualityFormat && $0.options.resize == .exact
          && $0.options.network
      })
  }

}

// Preserve the protected screenshot tests while sharing the service-backed implementation.
typealias ScreenshotPhotoKitReader = PhotoLibraryServiceReader
