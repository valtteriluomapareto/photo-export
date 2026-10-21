import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Tests ExportManager control flow and error handling using protocol fakes.
///
/// These tests deliberately inject fakes for all dependencies (PhotoLibraryService,
/// ExportDestination, AssetResourceWriter, FileSystemService) to isolate ExportManager's
/// logic from the Photos framework and filesystem. This is by design: the real PhotoKit
/// integration (ProductionAssetResourceWriter, PHAssetResourceManager) cannot be exercised
/// in a hermetic test environment without a real Photos library. The production wiring is
/// validated by manual testing and the app's own usage; these tests cover the orchestration
/// layer that was previously untestable.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct ExportPipelineTests {
  // MARK: - Test setup

  private func makeTestHarness(
    storeRootURL: URL? = nil, userDefaults: UserDefaults? = nil,
    fileSystem: FakeFileSystem = FakeFileSystem()
  ) -> (
    ExportManager, FakePhotoLibraryService, FakeExportDestination, FakeAssetResourceWriter,
    FakeFileSystem, ExportRecordStore
  ) {
    let photoLib = FakePhotoLibraryService()
    let dest = FakeExportDestination()
    let writer = FakeAssetResourceWriter()
    let tempDir =
      storeRootURL ?? TestScratch.directory("ExportPipelineTest")
    let store = ExportRecordStore(baseDirectoryURL: tempDir)
    store.configure(for: "test")
    let collections = CollectionExportRecordStore(baseDirectoryURL: tempDir)
    collections.configure(for: "test")

    // Clear the persisted version selection so ExportManager starts at its default
    // regardless of what a sibling test suite may have written.
    let defaults = userDefaults ?? TestScratch.defaults("ExportPipeline")

    let manager = ExportManager(
      photoLibraryService: photoLib,
      exportDestination: dest,
      exportRecordStore: store,
      collectionExportRecordStore: collections,
      assetResourceWriter: writer,
      fileSystem: fileSystem,
      userDefaults: defaults
    )
    return (manager, photoLib, dest, writer, fileSystem, store)
  }

  // MARK: - Export happy path

  @Test func exportHappyPath() async throws {
    let (manager, photoLib, dest, writer, fileSystem, store) = makeTestHarness()
    defer { dest.cleanup() }

    let asset = TestAssetFactory.makeAsset(
      id: "asset-1", creationDate: Date(), mediaType: .image)
    let resource = TestAssetFactory.makeResource(
      type: .photo, originalFilename: "IMG_0001.JPG")

    photoLib.assetsByYearMonth["2025-6"] = [asset]
    photoLib.resourcesByAssetId["asset-1"] = [resource]

    manager.startExportMonth(year: 2025, month: 6)
    await manager.waitForQueueDrained()

    // Verify resource was written
    #expect(writer.writeCalls.count == 1)
    guard writer.writeCalls.count == 1 else { return }
    #expect(writer.writeCalls[0].assetId == "asset-1")

    // Verify file was moved to final location
    #expect(fileSystem.moveCalls.count == 1)

    // Verify timestamps were applied
    #expect(fileSystem.timestampCalls.count == 1)

    // Verify record marked as done
    #expect(store.isExported(assetId: "asset-1"))
    let record = store.exportInfo(assetId: "asset-1")
    #expect(record?.variants[.original]?.status == .done)
    #expect(record?.variants[.original]?.filename == "IMG_0001.JPG")
    #expect(record?.year == 2025)
    #expect(record?.month == 6)

    // Verify counters
    #expect(manager.totalJobsCompleted == 1)
    #expect(manager.isRunning == false)
    #expect(manager.queueCount == 0)
  }

  // MARK: - Missing asset descriptor

  @Test func missingAssetDescriptorRecordsFailure() async throws {
    let (manager, photoLib, dest, writer, _, store) = makeTestHarness()
    defer { dest.cleanup() }

    // Simulate an asset that exists at enqueue time but disappears before
    // the export job runs — e.g. the user deleted it from Photos in between.
    // fetchAssets (used during enqueue) still returns the asset, but
    // fetchAssetDescriptor (called when the export job runs) returns nil.
    let asset = TestAssetFactory.makeAsset(id: "vanishing-asset")
    let resource = TestAssetFactory.makeResource()
    photoLib.assetsByYearMonth["2025-1"] = [asset]
    photoLib.resourcesByAssetId["vanishing-asset"] = [resource]
    photoLib.missingAssetIds = ["vanishing-asset"]

    manager.startExportMonth(year: 2025, month: 1)
    await manager.waitForQueueDrained()

    // Should have recorded a failure
    let record = store.exportInfo(assetId: "vanishing-asset")
    #expect(record?.variants[.original]?.status == .failed)
    #expect(record?.variants[.original]?.lastError == "Asset not found")

    // Resource writer should not have been called
    #expect(writer.writeCalls.isEmpty)
  }

  // MARK: - No exportable resource

  @Test func noExportableResourceMarkedFailed() async throws {
    let (manager, photoLib, dest, writer, _, store) = makeTestHarness()
    defer { dest.cleanup() }

    let asset = TestAssetFactory.makeAsset(id: "no-resource-asset")
    photoLib.assetsByYearMonth["2025-3"] = [asset]
    photoLib.resourcesByAssetId["no-resource-asset"] = []  // No resources

    manager.startExportMonth(year: 2025, month: 3)
    await manager.waitForQueueDrained()

    let record = store.exportInfo(assetId: "no-resource-asset")
    #expect(record?.variants[.original]?.status == .failed)
    #expect(record?.variants[.original]?.lastError == "No exportable resource")
    #expect(writer.writeCalls.isEmpty)
  }

  // MARK: - Write failure

  @Test func writeFailureCleansUpAndMarksFailure() async throws {
    let (manager, photoLib, dest, writer, _, store) = makeTestHarness()
    defer { dest.cleanup() }

    let asset = TestAssetFactory.makeAsset(id: "write-fail-asset")
    let resource = TestAssetFactory.makeResource()
    photoLib.assetsByYearMonth["2025-4"] = [asset]
    photoLib.resourcesByAssetId["write-fail-asset"] = [resource]

    writer.writeError = NSError(
      domain: "Test", code: 42,
      userInfo: [NSLocalizedDescriptionKey: "Disk full"])
    writer.shouldCreateFile = false

    manager.startExportMonth(year: 2025, month: 4)
    await manager.waitForQueueDrained()

    let record = store.exportInfo(assetId: "write-fail-asset")
    #expect(record?.variants[.original]?.status == .failed)
    #expect(record?.variants[.original]?.lastError?.contains("Disk full") == true)

    // Verify no .tmp files left behind (defer cleanup should have run)
    let monthDir = try dest.urlForMonth(year: 2025, month: 4, createIfNeeded: false)
    let leftoverTmp = try? FileManager.default.contentsOfDirectory(
      at: monthDir, includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "tmp" }
    #expect(leftoverTmp?.isEmpty != false)
  }

  // MARK: - Atomic move failure

  @Test func moveFailureMarksFailureAndCleansUpTempFile() async throws {
    let (manager, photoLib, dest, _, fileSystem, store) = makeTestHarness()
    defer { dest.cleanup() }

    let asset = TestAssetFactory.makeAsset(id: "move-fail-asset")
    let resource = TestAssetFactory.makeResource()
    photoLib.assetsByYearMonth["2025-5"] = [asset]
    photoLib.resourcesByAssetId["move-fail-asset"] = [resource]

    fileSystem.moveError = NSError(
      domain: "Test", code: 99,
      userInfo: [NSLocalizedDescriptionKey: "Permission denied"])

    manager.startExportMonth(year: 2025, month: 5)
    await manager.waitForQueueDrained()

    let record = store.exportInfo(assetId: "move-fail-asset")
    #expect(record?.variants[.original]?.status == .failed)
    #expect(record?.variants[.original]?.lastError?.contains("Permission denied") == true)

    // Verify the .tmp file was cleaned up by the defer block
    let monthDir = try dest.urlForMonth(year: 2025, month: 5, createIfNeeded: false)
    let leftoverTmp = try? FileManager.default.contentsOfDirectory(
      at: monthDir, includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "tmp" }
    #expect(leftoverTmp?.isEmpty != false)
  }

  /// A file that appears at the final name after staging is never overwritten. The commit
  /// reports the collision, the export plans again, finds the third-party file different
  /// and commits to ` (1)`. The variant is re-marked in progress under the new name first.
  @Test func lateCollisionAtTheFinalNameKeepsTheExistingFile() async throws {
    let storeRoot = TestScratch.directory("ExportPipelineTest")
    let (manager, photoLib, dest, _, fileSystem, store) = makeTestHarness(storeRootURL: storeRoot)
    defer { dest.cleanup() }

    let asset = TestAssetFactory.makeAsset(
      id: "late-collision",
      creationDate: Calendar.current.date(from: DateComponents(year: 2025, month: 6, day: 15))!)
    let resource = TestAssetFactory.makeResource(originalFilename: "IMG_0001.JPG")
    photoLib.yearCounts = [(2025, 1)]
    photoLib.assetsByYearMonth["2025-6"] = [asset]
    photoLib.resourcesByAssetId[asset.id] = [resource]
    fileSystem.beforeMoveHook = { [fileSystem] _, destination in
      if destination.lastPathComponent == "IMG_0001.JPG" {
        fileSystem.beforeMoveHook = nil
        try Data("third-party".utf8).write(to: destination)
      }
    }

    // An Auto Export run, so a failure would carry the signature retry state uses.
    let summary = await manager.runExport(
      context: ExportRunContext(
        source: .autoSync, visibility: .background, scope: .timelineFullLibrary,
        selection: .edited))

    #expect(summary.failures.isEmpty)
    #expect(
      fileSystem.moveCalls.map(\.to.lastPathComponent) == ["IMG_0001.JPG", "IMG_0001 (1).JPG"])
    // The history log shows the variant re-marked under the new name before it committed.
    store.flushForTesting()
    let log = try String(
      contentsOf: storeRoot.appendingPathComponent("test")
        .appendingPathComponent(ExportRecordStore.Constants.logFileName),
      encoding: .utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let history = try log.split(separator: "\n").compactMap { line in
      try decoder.decode(ExportRecordMutation.self, from: Data(line.utf8)).record?
        .variants[.original].map { "\($0.status.rawValue) \($0.filename ?? "")" }
    }
    #expect(
      history == [
        "inProgress IMG_0001.JPG", "inProgress IMG_0001 (1).JPG", "done IMG_0001 (1).JPG",
      ])
    let variant = store.exportInfo(assetId: asset.id)?.variants[.original]
    #expect(variant?.status == .done)
    #expect(variant?.filename == "IMG_0001 (1).JPG")
    let monthDir = try dest.urlForMonth(year: 2025, month: 6, createIfNeeded: false)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: monthDir.path).sorted()
        == ["IMG_0001 (1).JPG", "IMG_0001.JPG"])
    #expect(
      try Data(contentsOf: monthDir.appendingPathComponent("IMG_0001.JPG"))
        == Data("third-party".utf8))
    #expect(
      try Data(contentsOf: monthDir.appendingPathComponent("IMG_0001 (1).JPG"))
        == FakeAssetResourceWriter.content(for: resource, assetId: asset.id))
    #expect(fileSystem.timestampCalls.map(\.url.lastPathComponent) == ["IMG_0001 (1).JPG"])
  }

  /// The exclusive rename itself reports the collision: the file that took the final name
  /// keeps its bytes and the export commits to ` (1)` with a second exclusive rename.
  @Test func exclusiveRenameCollisionAtTheFinalNameKeepsTheExistingFile() async throws {
    let renames = LockedBox<[(name: String, flags: UInt32)]>([])
    let commit = FileIOService(
      renamer: { source, destination, flags in
        renames.mutate { $0.append((destination.lastPathComponent, flags)) }
        guard destination.lastPathComponent == "IMG_0001.JPG" else {
          return FileIOService.systemRename(source, destination, flags)
        }
        try? Data("third-party".utf8).write(to: destination)
        return EEXIST
      },
      capability: { _ in true })
    let (manager, photoLib, dest, _, fileSystem, store) = makeTestHarness(
      fileSystem: FakeFileSystem(real: commit))
    defer { dest.cleanup() }

    let asset = TestAssetFactory.makeAsset(
      id: "exclusive-collision",
      creationDate: Calendar.current.date(from: DateComponents(year: 2025, month: 6, day: 15))!)
    photoLib.yearCounts = [(2025, 1)]
    photoLib.assetsByYearMonth["2025-6"] = [asset]
    photoLib.resourcesByAssetId[asset.id] = [
      TestAssetFactory.makeResource(originalFilename: "IMG_0001.JPG")
    ]

    let summary = await manager.runExport(
      context: ExportRunContext(
        source: .autoSync, visibility: .background, scope: .timelineFullLibrary,
        selection: .edited))

    #expect(renames.value.map(\.name) == ["IMG_0001.JPG", "IMG_0001 (1).JPG"])
    #expect(renames.value.map(\.flags) == [UInt32(RENAME_EXCL), UInt32(RENAME_EXCL)])
    #expect(summary.failures.isEmpty)
    #expect(
      store.exportInfo(assetId: asset.id)?.variants[.original]?.filename == "IMG_0001 (1).JPG")
    let monthDir = try dest.urlForMonth(year: 2025, month: 6, createIfNeeded: false)
    // The stage is gone; the file that took the final name is untouched.
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: monthDir.path).sorted()
        == ["IMG_0001 (1).JPG", "IMG_0001.JPG"])
    #expect(
      try Data(contentsOf: monthDir.appendingPathComponent("IMG_0001.JPG"))
        == Data("third-party".utf8))
    #expect(fileSystem.timestampCalls.map(\.url.lastPathComponent) == ["IMG_0001 (1).JPG"])
  }

  /// A name lost at every commit stops after the bounded number of plans. The variant fails
  /// with the collision signature and every file that took a name keeps its bytes.
  @Test func repeatedLateCollisionsFailAfterBoundedPlans() async throws {
    let renames = LockedBox<[String]>([])
    let commit = FileIOService(
      renamer: { _, destination, _ in
        renames.mutate { $0.append(destination.lastPathComponent) }
        try? Data("third-party".utf8).write(to: destination)
        return EEXIST
      },
      capability: { _ in true })
    let (manager, photoLib, dest, _, fileSystem, store) = makeTestHarness(
      fileSystem: FakeFileSystem(real: commit))
    defer { dest.cleanup() }

    let asset = TestAssetFactory.makeAsset(
      id: "always-taken",
      creationDate: Calendar.current.date(from: DateComponents(year: 2025, month: 6, day: 15))!)
    photoLib.yearCounts = [(2025, 1)]
    photoLib.assetsByYearMonth["2025-6"] = [asset]
    photoLib.resourcesByAssetId[asset.id] = [
      TestAssetFactory.makeResource(originalFilename: "IMG_0001.JPG")
    ]

    let summary = await manager.runExport(
      context: ExportRunContext(
        source: .autoSync, visibility: .background, scope: .timelineFullLibrary,
        selection: .edited))

    #expect(VariantExporter.maxCommitAttempts == 3)
    #expect(renames.value == ["IMG_0001.JPG", "IMG_0001 (1).JPG", "IMG_0001 (2).JPG"])
    #expect(summary.failures.map(\.errorSignature) == ["Export:2"])
    #expect(summary.failures.map(\.category) == [.destinationCollision])
    let variant = store.exportInfo(assetId: asset.id)?.variants[.original]
    #expect(variant?.status == .failed)
    #expect(variant?.lastError == "Destination already exists")
    let monthDir = try dest.urlForMonth(year: 2025, month: 6, createIfNeeded: false)
    let names = try FileManager.default.contentsOfDirectory(atPath: monthDir.path).sorted()
    #expect(names == ["IMG_0001 (1).JPG", "IMG_0001 (2).JPG", "IMG_0001.JPG"])
    for name in names {
      #expect(
        try Data(contentsOf: monthDir.appendingPathComponent(name)) == Data("third-party".utf8))
    }
    #expect(fileSystem.timestampCalls.isEmpty)
  }

  /// A paired original-side slot has one fixed name, so a file that takes it before the
  /// commit fails that variant with `Export:2` instead of moving the pair to ` (1)`.
  @Test func lateCollisionAtAPairedSlotStillFails() async throws {
    let (manager, photoLib, dest, _, fileSystem, store) = makeTestHarness()
    defer { dest.cleanup() }

    let asset = TestAssetFactory.makeAsset(
      id: "paired-collision",
      creationDate: Calendar.current.date(from: DateComponents(year: 2025, month: 6, day: 15))!,
      hasAdjustments: true)
    photoLib.yearCounts = [(2025, 1)]
    photoLib.assetsByYearMonth["2025-6"] = [asset]
    photoLib.resourcesByAssetId[asset.id] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.JPG"),
      TestAssetFactory.makeResource(type: .fullSizePhoto, originalFilename: "FullSizeRender.JPG"),
    ]
    fileSystem.beforeMoveHook = { _, destination in
      if destination.lastPathComponent == "IMG_0001_orig.JPG" {
        try Data("third-party".utf8).write(to: destination)
      }
    }

    let summary = await manager.runExport(
      context: ExportRunContext(
        source: .autoSync, visibility: .background, scope: .timelineFullLibrary,
        selection: .editedWithOriginals))

    #expect(summary.failures.map(\.errorSignature) == ["Export:2"])
    #expect(summary.failures.map(\.category) == [.destinationCollision])
    let variants = store.exportInfo(assetId: asset.id)?.variants
    #expect(variants?[.original]?.status == .failed)
    #expect(variants?[.original]?.lastError == "Destination already exists")
    #expect(variants?[.edited]?.status == .done)
    #expect(variants?[.edited]?.filename == "IMG_0001.JPG")
    #expect(
      fileSystem.moveCalls.map(\.to.lastPathComponent) == ["IMG_0001_orig.JPG", "IMG_0001.JPG"])
    let monthDir = try dest.urlForMonth(year: 2025, month: 6, createIfNeeded: false)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: monthDir.path).sorted()
        == ["IMG_0001.JPG", "IMG_0001_orig.JPG"])
    #expect(
      try Data(contentsOf: monthDir.appendingPathComponent("IMG_0001_orig.JPG"))
        == Data("third-party".utf8))
  }

  // MARK: - Pause/resume cycle

  @Test func pauseAndResumeBehavior() async throws {
    let (manager, photoLib, dest, _, _, _) = makeTestHarness()
    defer { dest.cleanup() }

    let asset1 = TestAssetFactory.makeAsset(id: "pause-1")
    let asset2 = TestAssetFactory.makeAsset(id: "pause-2")
    photoLib.assetsByYearMonth["2025-7"] = [asset1, asset2]
    photoLib.resourcesByAssetId["pause-1"] = [
      TestAssetFactory.makeResource(originalFilename: "IMG_1.JPG")
    ]
    photoLib.resourcesByAssetId["pause-2"] = [
      TestAssetFactory.makeResource(originalFilename: "IMG_2.JPG")
    ]

    manager.startExportMonth(year: 2025, month: 7)
    await manager.waitForQueueDrained()

    // After drain, verify all completed
    #expect(manager.totalJobsCompleted == 2)
    #expect(manager.isRunning == false)

    // Now test pause/resume on non-running manager (should be no-ops)
    manager.pause()
    #expect(manager.isPaused == false)  // Can't pause when not running
    manager.resume()
    #expect(manager.isPaused == false)  // Can't resume when not paused
  }

  // MARK: - Queue draining

  @Test func queueDrainsAllJobsInOrder() async throws {
    let (manager, photoLib, dest, writer, _, store) = makeTestHarness()
    defer { dest.cleanup() }

    // Enqueue assets across two months
    let asset1 = TestAssetFactory.makeAsset(id: "jan-1")
    let asset2 = TestAssetFactory.makeAsset(id: "feb-1")
    photoLib.assetsByYearMonth["2025-1"] = [asset1]
    photoLib.assetsByYearMonth["2025-2"] = [asset2]
    photoLib.resourcesByAssetId["jan-1"] = [
      TestAssetFactory.makeResource(originalFilename: "JAN.JPG")
    ]
    photoLib.resourcesByAssetId["feb-1"] = [
      TestAssetFactory.makeResource(originalFilename: "FEB.JPG")
    ]

    manager.startExportMonth(year: 2025, month: 1)
    manager.startExportMonth(year: 2025, month: 2)
    await manager.waitForQueueDrained()

    #expect(store.isExported(assetId: "jan-1"))
    #expect(store.isExported(assetId: "feb-1"))
    #expect(manager.totalJobsCompleted == 2)
    #expect(manager.isRunning == false)
  }

  // MARK: - Duplicate skipping

  @Test func alreadyExportedAssetNotReEnqueued() async throws {
    let (manager, photoLib, dest, writer, _, store) = makeTestHarness()
    defer { dest.cleanup() }

    let asset = TestAssetFactory.makeAsset(id: "already-done")
    let resource = TestAssetFactory.makeResource()
    photoLib.assetsByYearMonth["2025-8"] = [asset]
    photoLib.resourcesByAssetId["already-done"] = [resource]

    // Pre-mark as exported
    store.markExported(
      assetId: "already-done", year: 2025, month: 8, relPath: "2025/08/",
      filename: "IMG_0001.JPG", exportedAt: Date())

    manager.startExportMonth(year: 2025, month: 8)
    await manager.waitForQueueDrained()

    // Writer should not have been called — asset was already exported
    #expect(writer.writeCalls.isEmpty)
    #expect(manager.totalJobsEnqueued == 0)
  }

  // MARK: - Cancel and clear

  @Test(.timeLimit(.minutes(2))) func cancelAndClearResetsAllState() async throws {
    let root = TestScratch.directory("ExportPipeline")
    let suite = TestScratch.suiteName("cancel-reset")
    let (manager, photoLib, dest, writer, fileSystem, store) = makeTestHarness(
      storeRootURL: root, userDefaults: TestScratch.defaults(suiteName: suite))
    let gate = AsyncCheckpoint()
    writer.checkpoint = gate
    var tasks: [Task<Void, Never>] = []
    func cleanup() async {
      tasks += manager.currentPreparationTasks
      if let task = manager.currentTask { tasks.append(task) }
      manager.cancelAndClear()
      await gate.releaseAll()
      for task in tasks { await task.value }
      store.flushForTesting()
      try? FileManager.default.removeItem(at: root)
      dest.cleanup()
    }
    do {
      photoLib.assetsByYearMonth["2025-9"] = (1...3).map { index in
        let id = "cancel-\(index)"
        photoLib.resourcesByAssetId[id] = [
          TestAssetFactory.makeResource(originalFilename: "IMG_\(index).JPG")
        ]
        return TestAssetFactory.makeAsset(id: id)
      }
      manager.startExportMonth(year: 2025, month: 9)
      try #require(await gate.waitForEnter(count: 1))
      tasks.append(try #require(manager.currentTask))
      await gate.release()
      try #require(await gate.waitForEnter(count: 2))
      let oldTask = try #require(manager.currentTask)
      tasks.append(oldTask)
      manager.pause()
      try #require(manager.totalJobsEnqueued == 3)
      try #require(manager.totalJobsCompleted == 1)
      try #require(manager.pendingJobs.count == 1)
      try #require(manager.queueCount == 2)
      try #require(manager.isRunning && manager.isPaused)
      try #require(manager.currentAssetFilename == "IMG_2.JPG")
      let completed = try #require(store.exportInfo(assetId: "cancel-1"))
      let completedFile = try dest.urlForMonth(year: 2025, month: 9, createIfNeeded: false)
        .appendingPathComponent("IMG_1.JPG")
      let completedBytes = try Data(contentsOf: completedFile)

      manager.cancelAndClear()

      #expect(!manager.isRunning && !manager.isPaused)
      #expect(manager.pendingJobs.isEmpty && manager.queueCount == 0)
      #expect(manager.queuedCount(year: 2025, month: 9) == 0)
      #expect(manager.totalJobsEnqueued == 0 && manager.totalJobsCompleted == 0)
      #expect(manager.currentAssetFilename == nil && manager.currentJobAssetId == nil)
      #expect(store.exportInfo(assetId: "cancel-2")?.variants[.original] == nil)
      await gate.releaseAll()
      await oldTask.value
      #expect(manager.totalJobsCompleted == 0)
      #expect(store.exportInfo(assetId: "cancel-1") == completed)
      #expect(try Data(contentsOf: completedFile) == completedBytes)
      #expect(fileSystem.moveCalls.count == 1)
    } catch {
      await cleanup()
      throw error
    }
    await cleanup()
  }

  // MARK: - Generation counter

  @Test(.timeLimit(.minutes(2))) func oldGenerationTasksExitCleanly() async throws {
    let root = TestScratch.directory("ExportPipeline")
    let suite = TestScratch.suiteName("cancel-generation")
    let (manager, photoLib, dest, writer, fileSystem, store) = makeTestHarness(
      storeRootURL: root, userDefaults: TestScratch.defaults(suiteName: suite))
    let oldGate = AsyncCheckpoint()
    let newGate = AsyncCheckpoint()
    var tasks: [Task<Void, Never>] = []
    func cleanup() async {
      tasks += manager.currentPreparationTasks
      if let task = manager.currentTask { tasks.append(task) }
      manager.cancelAndClear()
      await oldGate.releaseAll()
      await newGate.releaseAll()
      for task in tasks { await task.value }
      store.flushForTesting()
      try? FileManager.default.removeItem(at: root)
      dest.cleanup()
    }
    do {
      photoLib.assetsByYearMonth["2025-10"] = (1...2).map { index in
        let id = "gen-\(index)"
        photoLib.resourcesByAssetId[id] = [
          TestAssetFactory.makeResource(originalFilename: "OLD_\(index).JPG")
        ]
        return TestAssetFactory.makeAsset(id: id)
      }
      writer.checkpoint = oldGate
      manager.startExportMonth(year: 2025, month: 10)
      try #require(await oldGate.waitForEnter(count: 1))
      let oldTask = try #require(manager.currentTask)
      tasks.append(oldTask)
      try #require(writer.writeCalls.count == 1)
      try #require(store.exportInfo(assetId: "gen-1")?.variants[.original]?.status == .inProgress)
      manager.cancelAndClear()

      photoLib.assetsByYearMonth["2025-11"] = [TestAssetFactory.makeAsset(id: "new-gen-1")]
      photoLib.resourcesByAssetId["new-gen-1"] = [
        TestAssetFactory.makeResource(originalFilename: "NEW.JPG")
      ]
      writer.checkpoint = newGate
      manager.startExportMonth(year: 2025, month: 11)
      try #require(await newGate.waitForEnter(count: 1))
      tasks.append(try #require(manager.currentTask))
      let newRecord = try #require(store.exportInfo(assetId: "new-gen-1"))

      await oldGate.releaseAll()
      await oldTask.value

      #expect(manager.isRunning)
      #expect(manager.totalJobsEnqueued == 1 && manager.totalJobsCompleted == 0)
      #expect(manager.queueCount == 1)
      #expect(manager.currentJobAssetId == "new-gen-1" && manager.currentAssetFilename == "NEW.JPG")
      #expect(store.exportInfo(assetId: "new-gen-1") == newRecord)
      #expect(store.exportInfo(assetId: "gen-1")?.variants[.original] == nil)
      #expect(store.exportInfo(assetId: "gen-2") == nil)
      #expect(fileSystem.moveCalls.isEmpty)
      #expect(writer.writeCalls.map(\.assetId) == ["gen-1", "new-gen-1"])

      await newGate.releaseAll()
      await manager.waitForQueueDrained()
      #expect(manager.totalJobsCompleted == 1)
      #expect(store.isExported(assetId: "new-gen-1"))
      #expect(fileSystem.moveCalls.count == 1)
      #expect(fileSystem.moveCalls.first?.to.lastPathComponent == "NEW.JPG")
    } catch {
      await cleanup()
      throw error
    }
    await cleanup()
  }

  // MARK: - Scoped access pairing

  @Test func scopedAccessAlwaysPaired() async throws {
    let (manager, photoLib, dest, _, _, _) = makeTestHarness()
    defer { dest.cleanup() }

    let asset = TestAssetFactory.makeAsset(id: "scope-test")
    let resource = TestAssetFactory.makeResource()
    photoLib.assetsByYearMonth["2025-12"] = [asset]
    photoLib.resourcesByAssetId["scope-test"] = [resource]

    manager.startExportMonth(year: 2025, month: 12)
    await manager.waitForQueueDrained()

    // Every beginScopedAccess should have a matching endScopedAccess
    #expect(dest.beginScopedAccessCount == dest.endScopedAccessCount)
    #expect(dest.beginScopedAccessCount > 0)
  }

  // MARK: - Resource type selection priority

  @Test func selectsPrimaryResourceInPriorityOrder() async throws {
    let (manager, photoLib, dest, writer, _, _) = makeTestHarness()
    defer { dest.cleanup() }

    let asset = TestAssetFactory.makeAsset(id: "priority-test")
    // Provide multiple resource types — photo should be preferred
    photoLib.assetsByYearMonth["2025-1"] = [asset]
    photoLib.resourcesByAssetId["priority-test"] = [
      ResourceDescriptor(type: .fullSizePhoto, originalFilename: "fullsize.JPG"),
      ResourceDescriptor(type: .video, originalFilename: "video.MOV"),
      ResourceDescriptor(type: .photo, originalFilename: "original.JPG"),
    ]

    manager.startExportMonth(year: 2025, month: 1)
    await manager.waitForQueueDrained()

    // Should have selected .photo type
    #expect(writer.writeCalls.count == 1)
    #expect(writer.writeCalls[0].resource.type == .photo)
    #expect(writer.writeCalls[0].resource.originalFilename == "original.JPG")
  }

  // MARK: - Multiple assets exported with correct filenames

  @Test func multipleAssetsGetCorrectFilenames() async throws {
    let (manager, photoLib, dest, _, _, store) = makeTestHarness()
    defer { dest.cleanup() }

    let asset1 = TestAssetFactory.makeAsset(id: "multi-1")
    let asset2 = TestAssetFactory.makeAsset(id: "multi-2")
    photoLib.assetsByYearMonth["2025-3"] = [asset1, asset2]
    photoLib.resourcesByAssetId["multi-1"] = [
      TestAssetFactory.makeResource(originalFilename: "IMG_001.JPG")
    ]
    photoLib.resourcesByAssetId["multi-2"] = [
      TestAssetFactory.makeResource(originalFilename: "IMG_002.JPG")
    ]

    manager.startExportMonth(year: 2025, month: 3)
    await manager.waitForQueueDrained()

    let rec1 = store.exportInfo(assetId: "multi-1")
    let rec2 = store.exportInfo(assetId: "multi-2")
    #expect(rec1?.variants[.original]?.filename == "IMG_001.JPG")
    #expect(rec2?.variants[.original]?.filename == "IMG_002.JPG")
    #expect(rec1?.relPath == "2025/03/")
    #expect(rec2?.relPath == "2025/03/")
  }
}
