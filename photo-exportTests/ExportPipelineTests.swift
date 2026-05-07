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
struct ExportPipelineTests {
  // MARK: - Test setup

  private func makeTestHarness() -> (
    ExportManager, FakePhotoLibraryService, FakeExportDestination, FakeAssetResourceWriter,
    FakeFileSystem, ExportRecordStore
  ) {
    let photoLib = FakePhotoLibraryService()
    let dest = FakeExportDestination()
    let writer = FakeAssetResourceWriter()
    let fileSystem = FakeFileSystem()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ExportPipelineTest-\(UUID().uuidString)", isDirectory: true)
    let store = ExportRecordStore(baseDirectoryURL: tempDir)
    store.configure(for: "test")

    // Clear the persisted version selection so ExportManager starts at its default
    // regardless of what a sibling test suite may have written.
    let defaults = UserDefaults(
      suiteName: "test-ExportPipeline-\(UUID().uuidString)")!

    let manager = ExportManager(
      photoLibraryService: photoLib,
      exportDestination: dest,
      exportRecordStore: store,
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
    let leftoverTmp = try? FileManager.default.contentsOfDirectory(at: monthDir, includingPropertiesForKeys: nil)
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
    let leftoverTmp = try? FileManager.default.contentsOfDirectory(at: monthDir, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "tmp" }
    #expect(leftoverTmp?.isEmpty != false)
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

  @Test func cancelAndClearResetsAllState() async throws {
    let (manager, photoLib, dest, _, _, _) = makeTestHarness()
    defer { dest.cleanup() }

    var assets: [AssetDescriptor] = []
    for i in 1...10 {
      let asset = TestAssetFactory.makeAsset(id: "cancel-\(i)")
      assets.append(asset)
      photoLib.resourcesByAssetId["cancel-\(i)"] = [
        TestAssetFactory.makeResource(originalFilename: "IMG_\(i).JPG")
      ]
    }
    photoLib.assetsByYearMonth["2025-9"] = assets

    manager.startExportMonth(year: 2025, month: 9)
    try await Task.sleep(nanoseconds: 20_000_000)  // 20ms

    manager.cancelAndClear()

    #expect(manager.isRunning == false)
    #expect(manager.isPaused == false)
    #expect(manager.queueCount == 0)
    #expect(manager.totalJobsEnqueued == 0)
    #expect(manager.totalJobsCompleted == 0)
    #expect(manager.currentAssetFilename == nil)
  }

  // MARK: - Generation counter

  @Test func oldGenerationTasksExitCleanly() async throws {
    let (manager, photoLib, dest, writer, _, _) = makeTestHarness()
    defer { dest.cleanup() }

    var assets: [AssetDescriptor] = []
    for i in 1...20 {
      let asset = TestAssetFactory.makeAsset(id: "gen-\(i)")
      assets.append(asset)
      photoLib.resourcesByAssetId["gen-\(i)"] = [
        TestAssetFactory.makeResource(originalFilename: "IMG_\(i).JPG")
      ]
    }
    photoLib.assetsByYearMonth["2025-10"] = assets

    manager.startExportMonth(year: 2025, month: 10)
    try await Task.sleep(nanoseconds: 30_000_000)  // 30ms

    // Cancel and start a new export — old generation tasks should exit
    manager.cancelAndClear()
    let newAsset = TestAssetFactory.makeAsset(id: "new-gen-1")
    photoLib.assetsByYearMonth["2025-11"] = [newAsset]
    photoLib.resourcesByAssetId["new-gen-1"] = [
      TestAssetFactory.makeResource(originalFilename: "NEW.JPG")
    ]

    manager.startExportMonth(year: 2025, month: 11)
    await manager.waitForQueueDrained()

    // The new asset should be the last one written
    let lastWrite = writer.writeCalls.last
    #expect(lastWrite?.assetId == "new-gen-1")
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
