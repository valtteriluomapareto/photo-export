import Foundation
import Testing

@testable import Photo_Export

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct ExportPreparationTests {
  private final class LeafGate: @unchecked Sendable {
    let entered = AsyncCheckpoint()
    private let semaphore = DispatchSemaphore(value: 0)
    func hold() {
      Task { await entered.enter() }
      semaphore.wait()
    }
    func release() { semaphore.signal() }
  }

  private func admit(_ h: ExportManagerHarness, paired: Bool = false) {
    let asset = TestAssetFactory.makeAsset(
      id: "prepare",
      creationDate: Calendar.current.date(from: DateComponents(year: 2025, month: 4, day: 15)),
      hasAdjustments: paired)
    h.photoLib.assetsByYearMonth["2025-4"] = [asset]
    h.photoLib.resourcesByAssetId[asset.id] =
      [
        .init(type: .photo, originalFilename: "IMG.JPG", fileSize: 12)
      ] + (paired ? [.init(type: .fullSizePhoto, originalFilename: "IMG.JPG", fileSize: 12)] : [])
    h.manager.versionSelection = paired ? .editedWithOriginals : .edited
    h.manager.startExportMonth(year: 2025, month: 4)
  }

  private func cleanup(_ h: ExportManagerHarness) {
    h.manager.cancelAndClear()
    h.store.drainSynchronously()
    h.collectionStore.drainSynchronously()
    h.dest.cleanup()
    try? FileManager.default.removeItem(at: h.storeRoot)
  }

  @Test func progressPublicationCancellationPreventsPhysicalDispatch() async throws {
    let gate = LeafGate()
    let io = RecordingDestinationIO(beforeLeaf: { if $0 == 1 { gate.hold() } })
    let h = ExportManagerHarness(label: "CancelDuringFilename", destinationIOFactory: { _ in io })
    defer {
      gate.release()
      cleanup(h)
    }
    admit(h)
    try #require(await gate.entered.waitForEnter(count: 1))
    let old = try #require(h.manager.currentTask)
    var cancelled = false
    let probe = ObservationProbe(
      {
        _ = h.manager.currentAssetFilename
      },
      onChange: {
        guard !cancelled else { return }
        cancelled = true
        h.manager.cancelAndClear()
      })
    defer { probe.stop() }
    gate.release()
    await old.value
    #expect(cancelled)
    #expect(h.writer.writeCalls.isEmpty)
    #expect(h.manager.renderActivity == nil)
    #expect(h.fileSystem.moveCalls.isEmpty)
    #expect(h.store.exportInfo(assetId: "prepare") == nil)
    #expect(h.dest.beginScopedAccessCount == h.dest.endScopedAccessCount)
  }

  @Test(arguments: [false, true])
  func firstMarkRefusesClaimMadeByFilenameSubscriber(paired: Bool) async throws {
    let gate = LeafGate()
    let io = RecordingDestinationIO(beforeLeaf: { if $0 == 1 { gate.hold() } })
    let h = ExportManagerHarness(label: "FirstMarkClaim", destinationIOFactory: { _ in io })
    defer {
      gate.release()
      cleanup(h)
    }
    admit(h, paired: paired)
    try #require(await gate.entered.waitForEnter(count: 1))
    var claimed = false
    let name = paired ? "IMG_orig.JPG" : "IMG.JPG"
    let probe = ObservationProbe(
      { _ = h.manager.currentAssetFilename },
      onChange: {
        guard !claimed else { return }
        claimed = true
        h.store.markVariantExported(
          assetId: "other", variant: .original, year: 2025, month: 4,
          relPath: "2025/04/", filename: name, exportedAt: Date())
      })
    defer { probe.stop() }
    gate.release()
    await h.manager.waitForQueueDrained()
    #expect(claimed)
    #expect(!h.writer.writeCalls.contains { $0.resource.type == .photo })
    #expect(h.store.exportInfo(assetId: "other")?.variants[.original]?.filename == name)
    #expect(h.store.exportInfo(assetId: "prepare")?.variants[.original]?.status == .failed)
    #expect(h.store.exportInfo(assetId: "prepare")?.variants[.original]?.filename != name)
  }

  @Test func remappedMarkRechecksAfterFilenamePublication() async throws {
    let h = ExportManagerHarness(label: "RemappedMarkClaim")
    let written = AsyncCheckpoint()
    h.writer.afterWriteCheckpoint = written
    try await withCleanup {
      admit(h)
      try #require(await written.waitForEnter(count: 1))
      let directory = try h.dest.urlForRelativeDirectory("2025/04/", createIfNeeded: false)
      let planted = directory.appendingPathComponent("IMG.JPG")
      let bytes = Data("planted-after-probe".utf8)
      try bytes.write(to: planted)
      var claimed = false
      let probe = ObservationProbe(
        { _ = h.manager.currentAssetFilename },
        onChange: {
          guard !claimed else { return }
          claimed = true
          h.store.markVariantExported(
            assetId: "other", variant: .original, year: 2025, month: 4,
            relPath: "2025/04/", filename: "IMG (1).JPG", exportedAt: Date())
        })
      defer { probe.stop() }
      await written.releaseAll()
      await h.manager.waitForQueueDrained()
      #expect(claimed)
      #expect(try Data(contentsOf: planted) == bytes)
      #expect(h.store.exportInfo(assetId: "other")?.variants[.original]?.filename == "IMG (1).JPG")
      #expect(
        h.store.exportInfo(assetId: "prepare")?.variants[.original]?.filename == "IMG (2).JPG")
      #expect(
        !FileManager.default.fileExists(
          atPath: directory.appendingPathComponent("IMG (1).JPG").path))
    } cleanup: {
      await written.releaseAll()
      cleanup(h)
    }
  }

  private final class ScratchDestination: ExportDestination {
    let manager: ExportDestinationManager
    var opened: [URL] = []
    var closed: [URL] = []
    var validationWaits = 0
    init(_ manager: ExportDestinationManager) { self.manager = manager }
    var selectedFolderURL: URL? { manager.selectedFolderURL }
    var canExportNow: Bool { manager.canExportNow }
    var canImportNow: Bool { manager.canImportNow }
    func beginScopedAccess() -> URL? {
      if let selectedFolderURL { opened.append(selectedFolderURL) }
      return selectedFolderURL
    }
    func endScopedAccess(for url: URL) { closed.append(url) }
    func waitForValidation() async {
      validationWaits += 1
      await manager.waitForValidation()
    }
    func resetDirectoryResolution() { manager.resetDirectoryResolution() }
    func prepareDirectoryResolution(generation: Int) {
      manager.prepareDirectoryResolution(generation: generation)
    }
    func revalidateDirectory(_ path: String) throws { try manager.revalidateDirectory(path) }
    func captureDirectoryAccess(generation: Int) throws -> any ExportDirectoryResolving {
      try manager.captureDirectoryAccess(generation: generation)
    }
    func urlForRelativeDirectory(_ path: String, createIfNeeded: Bool) throws -> URL {
      try manager.urlForRelativeDirectory(path, createIfNeeded: createIfNeeded)
    }
    func urlForMonth(year: Int, month: Int, createIfNeeded: Bool) throws -> URL {
      try manager.urlForMonth(year: year, month: month, createIfNeeded: createIfNeeded)
    }
  }

  @MainActor
  private final class PreparationFixture {
    let root = TestScratch.directory("CapturedPreparation")
    let recordsRoot = TestScratch.directory("CapturedPreparationRecords")
    let files = FakeFileSystem()
    let photos = FakePhotoLibraryService()
    let writer = FakeAssetResourceWriter()
    let timeline: ExportRecordStore
    let collections: CollectionExportRecordStore
    let destination: ScratchDestination
    let manager: ExportManager
    init(
      io: any DestinationIOExecuting,
      validationProbe: any DestinationValidationProbing = ProductionDestinationValidationProbe()
    ) async throws {
      let first = root.appendingPathComponent("A")
      try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
      let realDestination = ExportDestinationManager(
        skipRestore: true, userDefaults: TestScratch.defaults("CapturedPreparationDestination"),
        validationScopeAcquirer: { _ in true }, validationScopeReleaser: { _ in },
        fileSystem: files, validationProbe: validationProbe)
      realDestination.setSelectedFolderForTesting(first)
      destination = ScratchDestination(realDestination)
      timeline = ExportRecordStore(baseDirectoryURL: recordsRoot)
      collections = CollectionExportRecordStore(baseDirectoryURL: recordsRoot)
      await timeline.configureAndWait(for: "A")
      await collections.configureAndWait(for: "A")
      manager = ExportManager(
        photoLibraryService: photos, exportDestination: destination,
        exportRecordStore: timeline, collectionExportRecordStore: collections,
        assetResourceWriter: writer, fileSystem: files,
        destinationIOFactory: { _ in io }, userDefaults: TestScratch.defaults("CapturedPreparation")
      )
      let asset = TestAssetFactory.makeAsset(
        id: "prepare",
        creationDate: Calendar.current.date(from: DateComponents(year: 2025, month: 4, day: 15)))
      photos.assetsByYearMonth["2025-4"] = [asset]
      photos.resourcesByAssetId[asset.id] = [.init(type: .photo, originalFilename: "IMG.JPG")]
    }
    func cleanup() {
      manager.cancelAndClear()
      timeline.drainSynchronously()
      collections.drainSynchronously()
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: recordsRoot)
    }
  }

  private final class HeldValidation: DestinationValidationProbing {
    let gate = LeafGate()
    func inspect(_ url: URL) -> DestinationValidationResult {
      gate.hold()
      return DestinationValidationResult(
        isAvailable: true, isWritable: true, status: .ready,
        fingerprint: .makeLow(
          volumeRootPath: nil,
          relativePathFromVolumeRoot: url.path, standardizedPath: url.path))
    }
  }

  @Test func queuedJobWaitsForCurrentValidationWithoutReportingDestinationFailure() async throws {
    let probe = HeldValidation()
    let f = try await PreparationFixture(io: RecordingDestinationIO(), validationProbe: probe)
    defer {
      probe.gate.release()
      f.cleanup()
    }
    f.manager.queueCoordinator.pause()
    f.manager.startExportMonth(year: 2025, month: 4)
    try #require(await eventually("job queued behind pause") { f.manager.pendingJobs.count == 1 })
    let identity = f.destination.manager.identity
    f.destination.manager.revalidate()
    try #require(await probe.gate.entered.waitForEnter(count: 1))
    #expect(f.destination.manager.isAvailable)
    #expect(f.destination.manager.identity == identity)
    #expect(!f.destination.manager.canExportNow)
    f.manager.resume()
    try #require(
      await eventually("queued job reached validation") {
        f.destination.validationWaits > 0 || !f.manager.isProcessing
      })
    #expect(f.destination.validationWaits == 1)
    #expect(f.writer.writeCalls.isEmpty)
    #expect(f.files.calls.isEmpty)
    #expect(f.destination.opened.isEmpty)
    probe.gate.release()
    await f.manager.waitForQueueDrained()
    #expect(f.timeline.exportInfo(assetId: "prepare")?.variants[.original]?.status == .done)
    #expect(f.destination.opened == f.destination.closed)
  }

  @Test func preparationFilesystemCallsUseCapturedWorker() async throws {
    let io = RecordingDestinationIO()
    let f = try await PreparationFixture(io: io)
    defer { f.cleanup() }
    f.manager.startExportMonth(year: 2025, month: 4)
    await f.manager.waitForQueueDrained()
    #expect(f.timeline.exportInfo(assetId: "prepare")?.variants[.original]?.status == .done)
    #expect(f.files.calls.contains { $0.operation == "openDirectory" && !$0.onMainThread })
    #expect(f.files.calls.allSatisfy { !$0.onMainThread })
    #expect(io.workerChecks.value.allSatisfy { $0 })
    #expect(f.destination.opened == f.destination.closed)
  }

  @Test func destinationReplacementDuringPrepareCannotDispatchOrBorrowNewScope() async throws {
    let gate = LeafGate()
    let io = RecordingDestinationIO(beforeLeaf: { if $0 == 1 { gate.hold() } })
    let f = try await PreparationFixture(io: io)
    defer {
      gate.release()
      f.cleanup()
    }
    f.manager.startExportMonth(year: 2025, month: 4)
    try #require(await gate.entered.waitForEnter(count: 1))
    let old = try #require(f.manager.currentTask)
    let first = try #require(f.destination.selectedFolderURL)
    f.manager.interruptForDestinationUnavailable()
    let second = f.root.appendingPathComponent("B")
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    f.destination.manager.setSelectedFolderForTesting(second)
    await f.timeline.configureAndWait(for: "B")
    await f.collections.configureAndWait(for: "B")
    #expect(f.destination.closed.isEmpty)
    gate.release()
    await old.value
    #expect(f.writer.writeCalls.isEmpty)
    #expect(f.files.moveCalls.isEmpty)
    #expect(f.destination.closed == [first])
    #expect(try FileManager.default.contentsOfDirectory(atPath: second.path).isEmpty)
    #expect(f.timeline.exportInfo(assetId: "prepare") == nil)
  }
}
