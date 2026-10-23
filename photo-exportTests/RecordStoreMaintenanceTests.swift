import Foundation
import Testing

@testable import Photo_Export

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct RecordStoreMaintenanceTests {
  private final class Replacement: AtomicFileReplacing, @unchecked Sendable {
    let entered = AsyncCheckpoint()
    private let signal = DispatchSemaphore(value: 0)
    private let state = LockedBox((armed: false, fail: false))
    func arm(fail: Bool = false) { state.mutate { $0 = (true, fail) } }
    func release() { signal.signal() }
    func replaceItemAtomically(from source: URL, to destination: URL) throws {
      var control = (armed: false, fail: false)
      state.mutate { value in
        control = value
        value.armed = false
      }
      if control.armed {
        Task { await entered.enter() }
        signal.wait()
      }
      if control.fail { throw CocoaError(.fileWriteOutOfSpace) }
      try FileIOService().replaceItemAtomically(from: source, to: destination)
    }
  }

  private final class Log: JSONLRecordLogIO, @unchecked Sendable {
    let writes = LockedBox(0)
    private let real = ProductionJSONLRecordLogIO()
    func readIfPresent(at url: URL) throws -> Data? { try real.readIfPresent(at: url) }
    func openForAppending(at url: URL) throws -> FileHandle { try real.openForAppending(at: url) }
    func write(_ data: Data, to handle: FileHandle) throws {
      writes.mutate { $0 += 1 }
      try real.write(data, to: handle)
    }
    func synchronize(_ handle: FileHandle) throws { try real.synchronize(handle) }
  }

  @MainActor private final class Fixture {
    let root = TestScratch.directory("RecordStoreMaintenance")
    let replacement = Replacement()
    let log = Log()
    let timeline: ExportRecordStore
    let collections: CollectionExportRecordStore
    let collection: Bool
    let placement = ExportPlacement.favorites()
    var checkpointError: (any Error)?

    init(collection: Bool) {
      self.collection = collection
      timeline = ExportRecordStore(
        baseDirectoryURL: root, recordLogIO: log, snapshotReplacer: replacement)
      collections = CollectionExportRecordStore(
        baseDirectoryURL: root, recordLogIO: log, snapshotReplacer: replacement)
      if collection {
        collections.configure(for: "A")
        collections.upsertPlacement(placement)
      } else {
        timeline.configure(for: "A")
      }
    }

    var waiters: Int {
      collection
        ? collections.mutationAdmission.pendingWaiterCount
        : timeline.mutationAdmission.pendingWaiterCount
    }
    var closed: Bool {
      collection ? collections.mutationAdmission.isClosed : timeline.mutationAdmission.isClosed
    }
    func has(_ id: String) -> Bool {
      collection
        ? collections.exportInfo(assetId: id, placement: placement) != nil
        : timeline.exportInfo(assetId: id) != nil
    }
    func seed() async throws {
      if collection {
        collections.markVariantExported(
          assetId: "seed", placement: placement, variant: .original, filename: "seed.JPG",
          exportedAt: Date())
        try await collections.flush()
      } else {
        timeline.markVariantExported(
          assetId: "seed", variant: .original, year: 2026, month: 10, relPath: "2026/10/",
          filename: "seed.JPG", exportedAt: Date())
        try await timeline.flush()
      }
    }
    func checkpoint() async {
      do {
        if collection {
          try await collections.checkpointHistory()
        } else {
          try await timeline.checkpointHistory()
        }
      } catch { checkpointError = error }
    }
    func importOne() async throws {
      let variant = ExportVariantRecord(
        filename: "import.JPG", status: .done, exportDate: Date(), lastError: nil)
      if collection {
        try await collections.withMutationAdmission {
          collections.bulkImportRecords([
            .init(placement: placement, records: ["import": [.original: variant]])
          ])
        }
      } else {
        try await timeline.withMutationAdmission {
          timeline.bulkImportRecords([
            ExportRecord(
              id: "import", year: 2026, month: 10, relPath: "2026/10/",
              variants: [.original: variant])
          ])
        }
      }
    }
    func acknowledgement() throws -> (String?) async -> Void {
      if collection {
        return try collections.captureFinalCommit(
          assetId: "commit", variant: .original, placement: placement, subfolder: nil,
          acceptsEditedFallback: false)
      }
      return try timeline.captureFinalCommit(
        assetId: "commit", variant: .original, year: 2026, month: 10, relPath: "2026/10/",
        subfolder: nil, acceptsEditedFallback: false)
    }
    func close() {
      replacement.release()
      timeline.drainSynchronously()
      collections.drainSynchronously()
      try? FileManager.default.removeItem(at: root)
    }
  }

  @Test(arguments: [false, true], [false, true])
  func heldCheckpointExcludesSecondWriterFromMemoryAndLog(collection: Bool, finalCommit: Bool)
    async throws
  {
    let f = Fixture(collection: collection)
    try await f.seed()
    let acknowledge = finalCommit ? try f.acknowledgement() : nil
    f.replacement.arm()
    let maintenance = Task { await f.checkpoint() }
    try await withCleanup {
      await f.replacement.entered.waitForEnter(count: 1)
      let before = f.log.writes.value
      let finished = LockedBox(false)
      let writer = Task {
        defer { finished.mutate { $0 = true } }
        if let acknowledge { await acknowledge("committed.JPG") } else { try await f.importOne() }
      }
      try #require(
        await eventually("second writer reaches admission") { f.waiters > 0 || finished.value || f.has(finalCommit ? "commit" : "import") })
      #expect(!f.has(finalCommit ? "commit" : "import"))
      #expect(f.log.writes.value == before)
      #expect(f.closed)
      f.replacement.release()
      await maintenance.value
      try await writer.value
      if collection { try await f.collections.flush() } else { try await f.timeline.flush() }
      #expect(f.has(finalCommit ? "commit" : "import"))
      #expect(f.log.writes.value > before)
      #expect(f.checkpointError == nil)
    } cleanup: {
      f.replacement.release()
      await maintenance.value
      f.close()
    }
  }

  @Test(arguments: [false, true])
  func cancelledWaiterDoesNotReopenPhysicalMaintenance(collection: Bool) async throws {
    let f = Fixture(collection: collection)
    try await f.seed()
    f.replacement.arm()
    let maintenance = Task { await f.checkpoint() }
    try await withCleanup {
      await f.replacement.entered.waitForEnter(count: 1)
      let writer = Task { try await f.importOne() }
      try #require(await eventually("cancellable writer waiting") { f.waiters > 0 })
      writer.cancel()
      do {
        try await writer.value
        Issue.record("Cancelled writer accepted")
      } catch { #expect(error is CancellationError) }
      #expect(f.closed)
      #expect(!f.has("import"))
      f.replacement.release()
      await maintenance.value
      try await f.importOne()
      #expect(f.has("import"))
    } cleanup: {
      f.replacement.release()
      await maintenance.value
      f.close()
    }
  }

  @Test(arguments: [false, true])
  func failedCheckpointKeepsTheReplayLogAndRejectsAWaitingImport(collection: Bool) async throws {
    let f = Fixture(collection: collection)
    try await f.seed()
    let logName = collection ? CollectionExportRecordStore.Constants.logFileName : ExportRecordStore.Constants.logFileName
    let path = f.root.appendingPathComponent("A").appendingPathComponent(logName)
    let previous = try Data(contentsOf: path)
    f.replacement.arm(fail: true)
    let maintenance = Task { await f.checkpoint() }
    var writer: Task<Void, Error>?
    try await withCleanup {
      await f.replacement.entered.waitForEnter(count: 1)
      writer = Task { try await f.importOne() }
      try #require(await eventually("failed checkpoint's waiting writer") { f.waiters > 0 })
      #expect(!f.has("import"))
      f.replacement.release()
      await maintenance.value
      do { try await writer?.value; Issue.record("Failed persistence accepted import") } catch { }
      #expect(f.checkpointError != nil)
      #expect(!f.has("import"))
      #expect(try Data(contentsOf: path) == previous)
      #expect((collection ? f.collections.state : f.timeline.state) == .persistenceFailed)
    } cleanup: {
      f.replacement.release()
      await maintenance.value
      _ = try? await writer?.value
      f.close()
    }
  }

  @Test(arguments: [false, true])
  func reconfigurationWaitsForPhysicalCheckpointBeforeReplacingHistory(collection: Bool) async throws {
    let f = Fixture(collection: collection)
    try await f.seed()
    f.replacement.arm()
    let maintenance = Task { await f.checkpoint() }
    try await withCleanup {
      await f.replacement.entered.waitForEnter(count: 1)
      if collection { f.collections.beginConfigure(for: "B") }
      else { f.timeline.beginConfigure(for: "B") }
      #expect((collection ? f.collections.state : f.timeline.state) == .loading)
      #expect(f.closed)
      f.replacement.release()
      await maintenance.value
      if collection { await f.collections.waitUntilSettled() }
      else { await f.timeline.waitUntilSettled() }
      #expect(!f.has("seed"))
      if collection { f.collections.beginConfigure(for: "A"); await f.collections.waitUntilSettled() }
      else { f.timeline.beginConfigure(for: "A"); await f.timeline.waitUntilSettled() }
      #expect(f.has("seed"))
    } cleanup: {
      f.replacement.release()
      await maintenance.value
      f.close()
    }
  }

  @Test(arguments: [false, true])
  func cancelledRecordCleanupCannotEraseAReplacementAfterMaintenance(collection: Bool) async throws {
    let f = Fixture(collection: collection)
    let photos = FakePhotoLibraryService()
    let writer = FakeAssetResourceWriter()
    let destination = FakeExportDestination()
    let files = FakeFileSystem()
    let manager = ExportManager(
      photoLibraryService: photos, exportDestination: destination, exportRecordStore: f.timeline,
      collectionExportRecordStore: f.collections, assetResourceWriter: writer, fileSystem: files,
      userDefaults: TestScratch.defaults("MaintenanceCleanup"))
    let asset = TestAssetFactory.makeAsset(id: "export", creationDate:
      Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 1)))
    photos.assetsByYearMonth["2026-10"] = [asset]
    photos.favoritesAssets = [asset]
    photos.resourcesByAssetId[asset.id] = [TestAssetFactory.makeResource()]
    let producer = AsyncCheckpoint()
    writer.checkpoint = producer
    func start() {
      if collection { manager.startExportFavorites() }
      else { manager.startExportMonth(year: 2026, month: 10) }
    }
    start()
    await producer.waitForEnter(count: 1)
    let old = try #require(manager.currentTask)
    f.replacement.arm()
    let maintenance = Task { await f.checkpoint() }
    try await withCleanup {
      await f.replacement.entered.waitForEnter(count: 1)
      manager.cancelAndClear()
      #expect(manager.queueCount == 0 && !manager.isRunning && !manager.isEnqueueingAll)
      writer.checkpoint = nil
      start()
      try #require(await eventually("old record cleanup waits at maintenance") { f.waiters > 0 })
      f.replacement.release()
      await maintenance.value
      await manager.waitForQueueDrained()
      let current = collection
        ? f.collections.exportInfo(assetId: asset.id, placement: f.placement)?.variants[.original]
        : f.timeline.exportInfo(assetId: asset.id)?.variants[.original]
      #expect(current?.status == .done)
      await producer.releaseAll()
      await old.value
      let after = collection
        ? f.collections.exportInfo(assetId: asset.id, placement: f.placement)?.variants[.original]
        : f.timeline.exportInfo(assetId: asset.id)?.variants[.original]
      #expect(after == current)
      #expect(destination.beginScopedAccessCount == destination.endScopedAccessCount)
    } cleanup: {
      manager.cancelAndClear()
      await producer.releaseAll()
      f.replacement.release()
      await maintenance.value
      await old.value
      destination.cleanup()
      f.close()
    }
  }

  @Test func replayPressureUsesWorkUnitsRatherThanElapsedTestTime() {
    var budget = RecordReplayBudget(operationNanoseconds: 200_000_000, byteNanoseconds: 1)
    for _ in 0..<3 { budget.record(encodedBytes: 1) }
    #expect(!budget.needsCheckpoint)
    budget.record(encodedBytes: 1)
    #expect(budget.needsCheckpoint)
    budget.didCheckpoint()
    #expect(!budget.needsCheckpoint)
    budget.record(encodedBytes: 800_000_000)
    #expect(budget.needsCheckpoint)
  }
}
