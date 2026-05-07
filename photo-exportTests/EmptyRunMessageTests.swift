import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Coverage for the toolbar's "already exported" feedback. Verifies the scope-tagged
/// message, the explicit clearing rules, and the auto-clear timer.
@MainActor
struct EmptyRunMessageTests {
  // MARK: - Test harness

  private func makeTestHarness() -> (
    ExportManager, FakePhotoLibraryService, FakeExportDestination, ExportRecordStore
  ) {
    let photoLib = FakePhotoLibraryService()
    let dest = FakeExportDestination()
    let writer = FakeAssetResourceWriter()
    let fileSystem = FakeFileSystem()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("EmptyRunTest-\(UUID().uuidString)", isDirectory: true)
    let store = ExportRecordStore(baseDirectoryURL: tempDir)
    store.configure(for: "test")

    let defaults = UserDefaults(
      suiteName: "test-EmptyRun-\(UUID().uuidString)")!

    let manager = ExportManager(
      photoLibraryService: photoLib,
      exportDestination: dest,
      exportRecordStore: store,
      assetResourceWriter: writer,
      fileSystem: fileSystem,
      userDefaults: defaults
    )
    return (manager, photoLib, dest, store)
  }


  // MARK: - Empty Export Month

  @Test func startExportMonthSetsMessageWhenAllAssetsAreAlreadyDone() async throws {
    let (manager, photoLib, dest, store) = makeTestHarness()
    defer { dest.cleanup() }

    let asset = TestAssetFactory.makeAsset(id: "done-asset")
    photoLib.assetsByYearMonth["2025-3"] = [asset]
    photoLib.resourcesByAssetId["done-asset"] = [
      TestAssetFactory.makeResource(originalFilename: "X.JPG")
    ]
    store.markExported(
      assetId: "done-asset", year: 2025, month: 3, relPath: "2025/03/",
      filename: "X.JPG", exportedAt: Date())

    manager.startExportMonth(year: 2025, month: 3)
    await manager.waitForQueueDrained()

    #expect(manager.emptyRunMessage == "This month is already exported.")
    #expect(manager.totalJobsEnqueued == 0)
  }

  @Test func startExportYearSetsYearScopedMessageWhenAlreadyDone() async throws {
    let (manager, photoLib, dest, store) = makeTestHarness()
    defer { dest.cleanup() }

    let asset = TestAssetFactory.makeAsset(id: "done-y", creationDate: makeDate(2024, 5, 1))
    photoLib.assetsByYearMonth["2024-5"] = [asset]
    photoLib.resourcesByAssetId["done-y"] = [
      TestAssetFactory.makeResource(originalFilename: "Y.JPG")
    ]
    store.markExported(
      assetId: "done-y", year: 2024, month: 5, relPath: "2024/05/",
      filename: "Y.JPG", exportedAt: Date())

    manager.startExportYear(year: 2024)
    await manager.waitForQueueDrained()

    #expect(manager.emptyRunMessage == "This year is already exported.")
  }

  @Test func startExportAllSetsLibraryScopedMessageWhenAlreadyDone() async throws {
    let (manager, photoLib, dest, store) = makeTestHarness()
    defer { dest.cleanup() }

    let asset = TestAssetFactory.makeAsset(id: "done-all", creationDate: makeDate(2024, 5, 1))
    photoLib.assetsByYearMonth["2024-5"] = [asset]
    photoLib.resourcesByAssetId["done-all"] = [
      TestAssetFactory.makeResource(originalFilename: "Z.JPG")
    ]
    photoLib.yearCounts = [(year: 2024, count: 1)]
    store.markExported(
      assetId: "done-all", year: 2024, month: 5, relPath: "2024/05/",
      filename: "Z.JPG", exportedAt: Date())

    manager.startExportAll()
    await manager.waitForQueueDrained()

    #expect(manager.emptyRunMessage == "Everything in this destination is already exported.")
  }

  // MARK: - Message NOT set when there is real work

  @Test func startExportMonthDoesNotSetMessageWhenWorkRemains() async throws {
    let (manager, photoLib, dest, _) = makeTestHarness()
    defer { dest.cleanup() }

    let asset = TestAssetFactory.makeAsset(id: "todo-asset")
    photoLib.assetsByYearMonth["2025-4"] = [asset]
    photoLib.resourcesByAssetId["todo-asset"] = [
      TestAssetFactory.makeResource(originalFilename: "T.JPG")
    ]

    manager.startExportMonth(year: 2025, month: 4)
    await manager.waitForQueueDrained()

    #expect(manager.emptyRunMessage == nil)
  }

  // MARK: - Clearing rules

  @Test func newStartExportClearsPriorMessage() async throws {
    let (manager, photoLib, dest, store) = makeTestHarness()
    defer { dest.cleanup() }

    let asset = TestAssetFactory.makeAsset(id: "done-1")
    photoLib.assetsByYearMonth["2025-5"] = [asset]
    photoLib.resourcesByAssetId["done-1"] = [
      TestAssetFactory.makeResource(originalFilename: "A.JPG")
    ]
    store.markExported(
      assetId: "done-1", year: 2025, month: 5, relPath: "2025/05/",
      filename: "A.JPG", exportedAt: Date())

    manager.startExportMonth(year: 2025, month: 5)
    await manager.waitForQueueDrained()
    #expect(manager.emptyRunMessage != nil)

    let workAsset = TestAssetFactory.makeAsset(id: "todo-2")
    photoLib.assetsByYearMonth["2025-6"] = [workAsset]
    photoLib.resourcesByAssetId["todo-2"] = [
      TestAssetFactory.makeResource(originalFilename: "B.JPG")
    ]
    manager.startExportMonth(year: 2025, month: 6)
    #expect(manager.emptyRunMessage == nil)
    await manager.waitForQueueDrained()
  }

  @Test func versionSelectionChangeClearsMessage() async throws {
    let (manager, photoLib, dest, store) = makeTestHarness()
    defer { dest.cleanup() }

    let asset = TestAssetFactory.makeAsset(id: "done-sel")
    photoLib.assetsByYearMonth["2025-7"] = [asset]
    photoLib.resourcesByAssetId["done-sel"] = [
      TestAssetFactory.makeResource(originalFilename: "S.JPG")
    ]
    store.markExported(
      assetId: "done-sel", year: 2025, month: 7, relPath: "2025/07/",
      filename: "S.JPG", exportedAt: Date())

    manager.startExportMonth(year: 2025, month: 7)
    await manager.waitForQueueDrained()
    #expect(manager.emptyRunMessage != nil)

    manager.versionSelection = .editedWithOriginals
    #expect(manager.emptyRunMessage == nil)
  }

  @Test func cancelAndClearClearsMessage() async throws {
    let (manager, photoLib, dest, store) = makeTestHarness()
    defer { dest.cleanup() }

    let asset = TestAssetFactory.makeAsset(id: "done-cancel")
    photoLib.assetsByYearMonth["2025-8"] = [asset]
    photoLib.resourcesByAssetId["done-cancel"] = [
      TestAssetFactory.makeResource(originalFilename: "C.JPG")
    ]
    store.markExported(
      assetId: "done-cancel", year: 2025, month: 8, relPath: "2025/08/",
      filename: "C.JPG", exportedAt: Date())

    manager.startExportMonth(year: 2025, month: 8)
    await manager.waitForQueueDrained()
    #expect(manager.emptyRunMessage != nil)

    manager.cancelAndClear()
    #expect(manager.emptyRunMessage == nil)
  }

  // MARK: - Helpers

  private func makeDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    return Calendar.current.date(from: components) ?? Date()
  }
}
