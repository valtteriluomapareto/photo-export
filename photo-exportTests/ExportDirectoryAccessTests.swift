import Foundation
import Testing

@testable import Photo_Export

/// Export runs through the real directory resolver: the main-thread filesystem budget, a
/// directory deleted during a write, the missing-directory retry, and stage cleanup before the
/// destination scope closes.
@Suite(.timeLimit(.minutes(2)))
@MainActor
struct ExportDirectoryAccessTests {

  private func makeManagerAndRoot(fileSystem: any FileSystemService) async throws
    -> (ExportDestinationManager, URL)
  {
    let dir = TestScratch.directory("ExportDirectoryAccess")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let mgr = ExportDestinationManager(
      skipRestore: true, userDefaults: TestScratch.defaults("DestinationManager"),
      bookmarkSaver: { _ in true }, validationScopeAcquirer: { _ in true },
      validationScopeReleaser: { _ in }, fileSystem: fileSystem)
    await mgr.persistSelectionAndWait(dir)
    return (mgr, dir)
  }

  /// Keeps resolution on the real manager while scratch URLs need no security bookmark.
  private final class ScratchDestination: ExportDestination {
    let manager: ExportDestinationManager
    init(_ manager: ExportDestinationManager) { self.manager = manager }
    var selectedFolderURL: URL? { manager.selectedFolderURL }
    var canExportNow: Bool { manager.canExportNow }
    var canImportNow: Bool { manager.canImportNow }
    func beginScopedAccess() -> URL? { selectedFolderURL }
    func endScopedAccess(for url: URL) {}
    func waitForValidation() async { await manager.waitForValidation() }
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

  @Test func steadyExportUsesAtMostThreeMainThreadFilesystemCallsPerAsset() async throws {
    let files = FakeFileSystem()
    let (destination, _) = try await makeManagerAndRoot(fileSystem: files)
    let photos = FakePhotoLibraryService()
    let writer = FakeAssetResourceWriter()
    let checkpoint = AsyncCheckpoint()
    writer.checkpoint = checkpoint
    let records = ExportRecordStore(
      baseDirectoryURL: TestScratch.directory("DirectoryCountRecords"))
    await records.configureAndWait(for: "count")
    let manager = ExportManager(
      photoLibraryService: photos, exportDestination: ScratchDestination(destination),
      exportRecordStore: records,
      collectionExportRecordStore: CollectionExportRecordStore(
        baseDirectoryURL: TestScratch.directory("DirectoryCountCollections")),
      assetResourceWriter: writer, fileSystem: files,
      userDefaults: TestScratch.defaults("DirectoryCount"))
    let assets = (0..<3).map {
      TestAssetFactory.makeAsset(
        id: "directory-count-\($0)",
        creationDate: Calendar.current.date(from: DateComponents(year: 2025, month: 2, day: 1)))
    }
    photos.assetsByYearMonth["2025-2"] = assets
    for asset in assets {
      photos.resourcesByAssetId[asset.id] = [
        TestAssetFactory.makeResource(originalFilename: "\(asset.id).JPG")
      ]
    }
    manager.startExportMonth(year: 2025, month: 2)
    await checkpoint.waitForEnter(count: 1)
    // The first asset warms the directory cache. Each next checkpoint brackets one
    // commit/cleanup and the next asset's identity, physical-path and filename probes.
    var start = files.calls.count
    for index in 2...3 {
      await checkpoint.release()
      await checkpoint.waitForEnter(count: index)
      let phase = Array(files.calls.dropFirst(start))
      #expect(phase.filter(\.onMainThread).count <= 3)
      #expect(phase.contains { !$0.onMainThread })
      start = files.calls.count
    }
    await checkpoint.releaseAll()
    await manager.waitForQueueDrained()
    #expect(
      assets.allSatisfy { records.exportInfo(assetId: $0.id)?.variants[.original]?.status == .done }
    )
  }

  @Test func directoryDeletedDuringStageWriteIsNotRecreated() async throws {
    let files = FakeFileSystem()
    let (destination, _) = try await makeManagerAndRoot(fileSystem: files)
    let photos = FakePhotoLibraryService()
    let writer = FakeAssetResourceWriter()
    let records = ExportRecordStore(baseDirectoryURL: TestScratch.directory("DeletedStageRecords"))
    await records.configureAndWait(for: "deleted")
    let manager = ExportManager(
      photoLibraryService: photos, exportDestination: ScratchDestination(destination),
      exportRecordStore: records,
      collectionExportRecordStore: CollectionExportRecordStore(
        baseDirectoryURL: TestScratch.directory("DeletedStageCollections")),
      assetResourceWriter: writer, fileSystem: files,
      userDefaults: TestScratch.defaults("DeletedStage"))
    let asset = TestAssetFactory.makeAsset(
      id: "deleted-stage",
      creationDate: Calendar.current.date(from: DateComponents(year: 2025, month: 2, day: 1)))
    photos.assetsByYearMonth["2025-2"] = [asset]
    photos.resourcesByAssetId[asset.id] = [TestAssetFactory.makeResource()]
    writer.writeHook = { url in
      try FileManager.default.removeItem(at: url.deletingLastPathComponent())
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
    }
    manager.startExportMonth(year: 2025, month: 2)
    await manager.waitForQueueDrained()
    #expect(writer.writeCalls.count == 1)
    let stage = try #require(writer.writeCalls.first?.url)
    #expect(!FileManager.default.fileExists(atPath: stage.deletingLastPathComponent().path))
    #expect(records.exportInfo(assetId: asset.id)?.variants[.original]?.status == .failed)
  }

  @Test(arguments: [ENOENT, ENOTDIR], [false, true])
  func missingDirectoryProducerIsRetriedOnlyOnce(code: Int32, succeedsOnRetry: Bool) async throws {
    let harness = await ExportManagerHarness(label: "DirectoryRetry")
    let asset = TestAssetFactory.makeAsset(
      id: "retry",
      creationDate: Calendar.current.date(from: DateComponents(year: 2025, month: 2, day: 1)))
    harness.photoLib.assetsByYearMonth["2025-2"] = [asset]
    harness.photoLib.resourcesByAssetId[asset.id] = [TestAssetFactory.makeResource()]
    let writer = harness.writer
    writer.writeHook = { _ in
      if !succeedsOnRetry || writer.writeCalls.count == 1 {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
      }
    }
    harness.manager.startExportMonth(year: 2025, month: 2)
    await harness.manager.waitForQueueDrained()
    #expect(harness.writer.writeCalls.count == 2)
    #expect(harness.dest.revalidationCount == 1)
    #expect(
      harness.store.exportInfo(assetId: asset.id)?.variants[.original]?.status
        == (succeedsOnRetry ? .done : .failed))
  }

  private final class CleanupGate: @unchecked Sendable {
    let entered = AsyncCheckpoint()
    private let releaseSignal = DispatchSemaphore(value: 0)
    func hold() {
      Task { await entered.enter() }
      releaseSignal.wait()
    }
    func release() { releaseSignal.signal() }
  }

  enum CleanupOutcome: CaseIterable { case success, failure, cancellation }

  @Test(arguments: CleanupOutcome.allCases)
  func stageCleanupFinishesBeforeDestinationScopeCloses(outcome: CleanupOutcome) async throws {
    let harness = await ExportManagerHarness(label: "DirectoryCleanup")
    let asset = TestAssetFactory.makeAsset(
      id: "cleanup",
      creationDate: Calendar.current.date(from: DateComponents(year: 2025, month: 2, day: 1)))
    harness.photoLib.assetsByYearMonth["2025-2"] = [asset]
    harness.photoLib.resourcesByAssetId[asset.id] = [TestAssetFactory.makeResource()]
    let writerGate = AsyncCheckpoint()
    harness.writer.checkpoint = writerGate
    let cleanup = CleanupGate()
    harness.fileSystem.existsHook = { path in
      if URL(fileURLWithPath: path).lastPathComponent.hasPrefix(".photo-export-") {
        if pthread_main_np() != 0 {
          Issue.record("Stage cleanup must run off the main thread")
          Task { await cleanup.entered.enter() }
        } else {
          cleanup.hold()
        }
      }
    }
    defer { cleanup.release() }
    harness.manager.startExportMonth(year: 2025, month: 2)
    await writerGate.waitForEnter(count: 1)
    let running = try #require(harness.manager.currentTask)
    if outcome == .failure { harness.writer.writeError = CocoaError(.fileWriteNoPermission) }
    if outcome == .cancellation { harness.manager.cancelAndClear() }
    await writerGate.releaseAll()
    await cleanup.entered.waitForEnter(count: 1)
    #expect(harness.dest.endScopedAccessCount == 0)
    cleanup.release()
    await cleanup.entered.releaseAll()
    _ = await running.value
    #expect(harness.dest.beginScopedAccessCount == harness.dest.endScopedAccessCount)
  }
}
