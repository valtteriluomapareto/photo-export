import Foundation
import Testing

@testable import Photo_Export

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct HistoryWriteFailureTests {
  private final class FailingLogIO: JSONLRecordLogIO, @unchecked Sendable {
    private let lock = NSLock()
    private var writes = 0
    private var failAfter: Int?
    private let production = ProductionJSONLRecordLogIO()

    func failAfterSuccessfulWrites(_ count: Int?) {
      lock.withLock { failAfter = count }
    }
    var successfulWrites: Int { lock.withLock { writes } }
    func readIfPresent(at url: URL) throws -> Data? { try production.readIfPresent(at: url) }
    func openForAppending(at url: URL) throws -> FileHandle {
      try production.openForAppending(at: url)
    }
    func write(_ data: Data, to handle: FileHandle) throws {
      try lock.withLock {
        if let failAfter, writes >= failAfter { throw CocoaError(.fileWriteOutOfSpace) }
        try production.write(data, to: handle)
        writes += 1
      }
    }
    func synchronize(_ handle: FileHandle) throws { try production.synchronize(handle) }
  }

  @MainActor
  private final class Fixture {
    let root = TestScratch.directory("HistoryWriteFailure")
    let photos = FakePhotoLibraryService()
    let destination = FakeExportDestination()
    let writer = FakeAssetResourceWriter()
    let io = FailingLogIO()
    let timeline: ExportRecordStore
    let collections: CollectionExportRecordStore
    let manager: ExportManager

    init(collectionFault: Bool = false) async {
      timeline = ExportRecordStore(
        baseDirectoryURL: root, recordLogIO: collectionFault ? ProductionJSONLRecordLogIO() : io)
      collections = CollectionExportRecordStore(
        baseDirectoryURL: root, recordLogIO: collectionFault ? io : ProductionJSONLRecordLogIO())
      await timeline.configureAndWait(for: "test")
      await collections.configureAndWait(for: "test")
      manager = ExportManager(
        photoLibraryService: photos, exportDestination: destination,
        exportRecordStore: timeline, collectionExportRecordStore: collections,
        assetResourceWriter: writer, fileSystem: FakeFileSystem(),
        userDefaults: TestScratch.defaults("HistoryWriteFailure"))
    }

    func cleanup() async {
      let tasks =
        manager.currentPreparationTasks
        + [manager.currentTask, manager.importTask].compactMap { $0 }
      io.failAfterSuccessfulWrites(nil)
      await writer.checkpoint?.releaseAll()
      manager.cancelImport()
      manager.cancelAndClear()
      for task in tasks { await task.value }
      await manager.waitForImportCompletion()
      await manager.waitForQueueDrained()
      timeline.drainSynchronously()
      collections.drainSynchronously()
      destination.cleanup()
      try? FileManager.default.removeItem(at: root)
    }
  }

  private func makeDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
  }

  @Test(arguments: [false, true])
  func importReportsMidAppendFailureWithSuccessfulControl(fail: Bool) async throws {
    let f = await Fixture()
    try await withCleanup {
      let date = makeDate(2025, 1, 15)
      let directory = try f.destination.urlForMonth(year: 2025, month: 1, createIfNeeded: true)
      let assets = (0..<256).map {
        TestAssetFactory.makeAsset(id: "import-\($0)", creationDate: date)
      }
      f.photos.assetsByYearMonth["2025-1"] = assets
      for asset in assets {
        let filename = "\(asset.id).JPG"
        f.photos.resourcesByAssetId[asset.id] = [
          TestAssetFactory.makeResource(originalFilename: filename)
        ]
        let url = directory.appendingPathComponent(filename)
        try Data("photo".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
      }
      if fail { f.io.failAfterSuccessfulWrites(1) }

      f.manager.startImport()
      await f.manager.waitForImportCompletion()

      #expect(!f.manager.isImporting)
      if fail {
        #expect(f.io.successfulWrites == 1, "The fault follows a real successful append")
        #expect(f.timeline.state == .persistenceFailed)
        #expect(f.manager.importResult == nil)
        #expect(f.manager.importError?.hasPrefix("Import failed: ") == true)
      } else {
        #expect(f.manager.importError == nil)
        #expect(f.manager.importStage == .done)
        #expect(f.manager.importResult?.matchedCount == assets.count)
        #expect(f.io.successfulWrites == assets.count)
        let reopened = ExportRecordStore(baseDirectoryURL: f.root)
        await reopened.configureAndWait(for: "test")
        #expect(assets.allSatisfy { reopened.exportInfo(assetId: $0.id) != nil })
        reopened.drainSynchronously()
      }
    } cleanup: {
      await f.cleanup()
    }
  }

  @Test(arguments: [false, true], [false, true])
  func reconcileCountsWholePruneDespiteAppendFailure(collection: Bool, fail: Bool) async throws {
    let f = await Fixture(collectionFault: collection)
    try await withCleanup {
      let count = 256
      let placement = ExportPlacement.favorites()
      if collection { f.collections.upsertPlacement(placement) }
      for index in 0..<count {
        if collection {
          f.collections.markVariantExported(
            assetId: "prune-\(index)", placement: placement, variant: .original,
            filename: "\(index).JPG", exportedAt: Date())
        } else {
          f.timeline.markExported(
            assetId: "prune-\(index)", year: 2025, month: 1, relPath: "2025/01/",
            filename: "\(index).JPG", exportedAt: Date())
        }
      }
      try await f.timeline.flush()
      try await f.collections.flush()
      let savedWrites = f.io.successfulWrites
      if fail { f.io.failAfterSuccessfulWrites(savedWrites + 1) }

      if collection {
        let summary = try await f.collections.reconcileAgainstFilesystem(at: f.destination.rootURL)
        #expect(summary.prunedRecords == count)
        #expect(summary.prunedVariants == count)
        #expect(f.collections.recordBodies.values.allSatisfy { $0.isEmpty })
      } else {
        let summary = try await f.timeline.reconcileAgainstFilesystem(at: f.destination.rootURL)
        #expect(summary.prunedRecords == count)
        #expect(summary.prunedVariants == count)
        #expect(f.timeline.recordsById.isEmpty)
      }
      if fail {
        await #expect(throws: (any Error).self) {
          if collection { try await f.collections.flush() } else { try await f.timeline.flush() }
        }
        #expect(f.io.successfulWrites == savedWrites + 1)
        #expect((collection ? f.collections.state : f.timeline.state) == .persistenceFailed)
      } else {
        if collection { try await f.collections.flush() } else { try await f.timeline.flush() }
        #expect(f.io.successfulWrites == savedWrites + count)
      }
    } cleanup: {
      await f.cleanup()
    }
  }

  @Test func autoExportRetainsVariantFailureWhenHistoryBecomesUnavailable() async throws {
    let f = await Fixture()
    try await withCleanup {
      let gate = AsyncCheckpoint()
      f.writer.checkpoint = gate
      f.writer.writeError = CocoaError(.fileReadUnknown)
      let asset = TestAssetFactory.makeAsset(
        id: "failed-variant", creationDate: makeDate(2025, 1, 15))
      f.photos.yearCounts = [(2025, 1)]
      f.photos.assetsByYearMonth["2025-1"] = [asset]
      f.photos.resourcesByAssetId[asset.id] = [
        TestAssetFactory.makeResource(originalFilename: "FAILED.JPG")
      ]
      let context = ExportRunContext(
        source: .autoSync, visibility: .background, scope: .timelineFullLibrary,
        selection: .edited)
      let run = Task { await f.manager.runExport(context: context) }
      await gate.waitForEnter(count: 1)
      try await f.timeline.flush()
      f.io.failAfterSuccessfulWrites(f.io.successfulWrites)
      f.timeline.markExported(
        assetId: "history-write-fault", year: 2025, month: 1, relPath: "2025/01/",
        filename: "HISTORY.JPG", exportedAt: Date())
      await #expect(throws: (any Error).self) { try await f.timeline.flush() }
      try #require(f.timeline.state == .persistenceFailed)
      await gate.releaseAll()
      let summary = await run.value

      #expect(summary.result == .failed)
      #expect(summary.failedCount == 1)
      #expect(summary.failures.count == 1)
      #expect(summary.failures.first?.assetId == asset.id)
      #expect(summary.failures.first?.variant == .original)
      #expect(summary.failures.first?.placement.kind == .timeline)
      #expect(summary.failures.first?.localizedDescription.isEmpty == false)
    } cleanup: {
      await f.cleanup()
    }
  }
}
