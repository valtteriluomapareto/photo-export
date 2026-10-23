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
      let control = state.mutate { value in let result = value; value.armed = false; return result }
      if control.armed { Task { await entered.enter() }; signal.wait() }
      if control.fail { throw CocoaError(.fileWriteOutOfSpace) }
      try FileIOService().replaceItemAtomically(from: source, to: destination)
    }
  }

  private final class Log: JSONLRecordLogIO, @unchecked Sendable {
    let writes = LockedBox(0)
    private let real = ProductionJSONLRecordLogIO()
    func readIfPresent(at url: URL) throws -> Data? { try real.readIfPresent(at: url) }
    func openForAppending(at url: URL) throws -> FileHandle { try real.openForAppending(at: url) }
    func write(_ data: Data, to handle: FileHandle) throws { writes.mutate { $0 += 1 }; try real.write(data, to: handle) }
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
      timeline = ExportRecordStore(baseDirectoryURL: root, recordLogIO: log, snapshotReplacer: replacement)
      collections = CollectionExportRecordStore(baseDirectoryURL: root, recordLogIO: log, snapshotReplacer: replacement)
      if collection { collections.configure(for: "A"); collections.upsertPlacement(placement) }
      else { timeline.configure(for: "A") }
    }

    var waiters: Int { collection ? collections.mutationAdmission.pendingWaiterCount : timeline.mutationAdmission.pendingWaiterCount }
    var closed: Bool { collection ? collections.mutationAdmission.isClosed : timeline.mutationAdmission.isClosed }
    func has(_ id: String) -> Bool {
      collection ? collections.exportInfo(assetId: id, placement: placement) != nil : timeline.exportInfo(assetId: id) != nil
    }
    func seed() async throws {
      if collection {
        collections.markVariantExported(assetId: "seed", placement: placement, variant: .original, filename: "seed.JPG", exportedAt: Date())
        try await collections.flush()
      } else {
        timeline.markVariantExported(assetId: "seed", variant: .original, year: 2026, month: 10, relPath: "2026/10/", filename: "seed.JPG", exportedAt: Date())
        try await timeline.flush()
      }
    }
    func checkpoint() async {
      do {
        if collection { try await collections.checkpointHistory() }
        else { try await timeline.checkpointHistory() }
      } catch { checkpointError = error }
    }
    func importOne() async throws {
      let variant = ExportVariantRecord(filename: "import.JPG", status: .done, exportDate: Date(), lastError: nil)
      if collection {
        try await collections.withMutationAdmission {
          collections.bulkImportRecords([.init(placement: placement, records: ["import": [.original: variant]])])
        }
      } else {
        try await timeline.withMutationAdmission {
          timeline.bulkImportRecords([ExportRecord(id: "import", year: 2026, month: 10, relPath: "2026/10/", variants: [.original: variant])])
        }
      }
    }
    func acknowledgement() throws -> (String?) async -> Void {
      if collection {
        return try collections.captureFinalCommit(assetId: "commit", variant: .original, placement: placement, subfolder: nil, acceptsEditedFallback: false)
      }
      return try timeline.captureFinalCommit(assetId: "commit", variant: .original, year: 2026, month: 10, relPath: "2026/10/", subfolder: nil, acceptsEditedFallback: false)
    }
    func close() {
      replacement.release()
      timeline.drainSynchronously()
      collections.drainSynchronously()
      try? FileManager.default.removeItem(at: root)
    }
  }

  @Test(arguments: [false, true], [false, true])
  func heldCheckpointExcludesSecondWriterFromMemoryAndLog(collection: Bool, finalCommit: Bool) async throws {
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
        if let acknowledge { await acknowledge("committed.JPG") }
        else { try await f.importOne() }
      }
      try #require(await eventually("second writer reaches admission") { f.waiters > 0 || finished.value })
      #expect(!f.has(finalCommit ? "commit" : "import"))
      #expect(f.log.writes.value == before)
      #expect(f.closed)
      f.replacement.release()
      await maintenance.value
      try await writer.value
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
      do { try await writer.value; Issue.record("Cancelled writer accepted") }
      catch { #expect(error is CancellationError) }
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
