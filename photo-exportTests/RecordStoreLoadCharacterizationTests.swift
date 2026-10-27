import Foundation
import Testing
import os

@testable import Photo_Export

/// Pins how a load turns read failures, corruption and the log's final byte into store
/// state, so moving the load's steps elsewhere cannot change them.
@MainActor
struct RecordStoreLoadCharacterizationTests {
  private struct ReadFailure: LocalizedError, Equatable {
    let name: String
    var errorDescription: String? { "Injected \(name) read failure" }
  }

  /// Fails reads of the chosen files until `heal()`; every other operation is production IO.
  private final class FaultyReadIO: JSONLRecordLogIO, @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [URL: ReadFailure]
    private let production = ProductionJSONLRecordLogIO()

    init(_ failures: [URL: ReadFailure] = [:]) { self.failures = failures }

    func fail(_ url: URL, with failure: ReadFailure) { lock.withLock { failures[url] = failure } }
    func heal() { lock.withLock { failures = [:] } }

    func readIfPresent(at url: URL) throws -> Data? {
      if let failure = lock.withLock({ failures[url] }) { throw failure }
      return try production.readIfPresent(at: url)
    }
    func openForAppending(at url: URL) throws -> FileHandle {
      try production.openForAppending(at: url)
    }
    func write(_ data: Data, to handle: FileHandle) throws {
      try production.write(data, to: handle)
    }
    func synchronize(_ handle: FileHandle) throws { try production.synchronize(handle) }
  }

  private struct Entry: Codable, Sendable, Equatable { let id: String }
  private struct Snapshot: Codable, Sendable, Equatable { let ids: [String] }

  private let date = Date(timeIntervalSince1970: 1_700_000_000)

  private func makeDirectory(_ label: String) throws -> URL {
    let url = TestScratch.directory(label)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func encoder() -> JSONEncoder {
    let result = JSONEncoder()
    result.dateEncodingStrategy = .iso8601
    return result
  }

  /// Writes a readable log for the chosen store under `<root>/A` and returns its files.
  private func seedStore(collection: Bool, root: URL) throws -> (snapshot: URL, log: URL) {
    let directory = root.appendingPathComponent("A")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let snapshotURL = directory.appendingPathComponent(
      collection
        ? CollectionExportRecordStore.Constants.snapshotFileName
        : ExportRecordStore.Constants.snapshotFileName)
    let logURL = directory.appendingPathComponent(
      collection
        ? CollectionExportRecordStore.Constants.logFileName
        : ExportRecordStore.Constants.logFileName)
    let variant = ExportVariantRecord(
      filename: "LOG.JPG", status: .done, exportDate: date, lastError: nil)
    var logBytes: Data
    if collection {
      let placement = ExportPlacement.favorites(createdAt: date)
      logBytes = try encoder().encode(
        CollectionExportRecordStore.LogOp.upsertPlacement(
          placementId: placement.id, placement: placement))
      logBytes.append(0x0A)
      logBytes.append(
        try encoder().encode(
          CollectionExportRecordStore.LogOp.upsertRecord(
            placementId: placement.id, assetId: "log",
            body: .init(variants: ["original": variant]))))
    } else {
      logBytes = try encoder().encode(
        ExportRecordMutation.upsert(
          ExportRecord(
            id: "log", year: 2024, month: 4, relPath: "2024/04/",
            variants: [.original: variant])))
    }
    logBytes.append(0x0A)
    try logBytes.write(to: logURL)
    return (snapshotURL, logURL)
  }

  private func configureStore(
    collection: Bool, root: URL, io: FaultyReadIO
  ) async -> (state: RecordStoreState, error: String?, isEmpty: Bool) {
    if collection {
      let store = CollectionExportRecordStore(baseDirectoryURL: root, recordLogIO: io)
      await store.configureAndWait(for: "A")
      defer { store.drainSynchronously() }
      return (
        store.state, store.persistenceError,
        store.recordBodies.isEmpty && store.placements.isEmpty
      )
    }
    let store = ExportRecordStore(baseDirectoryURL: root, recordLogIO: io)
    await store.configureAndWait(for: "A")
    defer { store.drainSynchronously() }
    return (store.state, store.persistenceError, store.recordsById.isEmpty)
  }

  // MARK: - Outcome precedence

  /// An unreadable log outranks a corrupt snapshot: the store asks to retry storage access
  /// instead of offering to reset the history it could not read.
  @Test(arguments: [false, true])
  func corruptSnapshotWithUnreadableLogIsAPersistenceFailure(collection: Bool) async throws {
    let root = try makeDirectory("LoadPrecedence")
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try seedStore(collection: collection, root: root)
    try Data("not-json".utf8).write(to: files.snapshot)
    let logFailure = ReadFailure(name: "log")
    let io = FaultyReadIO([files.log: logFailure])

    let loaded = await configureStore(collection: collection, root: root, io: io)

    #expect(loaded.state == .persistenceFailed)
    #expect(loaded.error == logFailure.errorDescription)
    #expect(loaded.isEmpty)
    #expect(try Data(contentsOf: files.snapshot) == Data("not-json".utf8))
  }

  /// When both reads fail, the log's error is the one the store reports.
  @Test(arguments: [false, true])
  func bothReadsFailingReportsTheLogError(collection: Bool) async throws {
    let root = try makeDirectory("LoadPrecedence")
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try seedStore(collection: collection, root: root)
    try Data("{}".utf8).write(to: files.snapshot)
    let snapshotFailure = ReadFailure(name: "snapshot")
    let logFailure = ReadFailure(name: "log")
    let io = FaultyReadIO([files.snapshot: snapshotFailure, files.log: logFailure])

    let loaded = await configureStore(collection: collection, root: root, io: io)

    #expect(loaded.state == .persistenceFailed)
    #expect(loaded.error == logFailure.errorDescription)
    #expect(loaded.isEmpty)
  }

  // MARK: - Log separator

  private func makeFile(_ root: URL, io: any JSONLRecordLogIO) -> JSONLRecordFile<Snapshot, Entry> {
    JSONLRecordFile(
      snapshotURL: root.appendingPathComponent("snapshot.json"),
      logURL: root.appendingPathComponent("log.jsonl"),
      ioQueue: DispatchQueue(label: "LoadSeparator-\(UUID())"),
      logger: Logger(subsystem: TestLogging.subsystem, category: "LoadSeparator"), logIO: io)
  }

  private func line(_ id: String) throws -> Data {
    var bytes = try JSONEncoder().encode(Entry(id: id))
    bytes.append(0x0A)
    return bytes
  }

  /// A log that is gone on a later load clears the separator an earlier load recorded.
  @Test func absentLogClearsAnEarlierSeparator() async throws {
    let root = try makeDirectory("LoadSeparator")
    defer { try? FileManager.default.removeItem(at: root) }
    let logURL = root.appendingPathComponent("log.jsonl")
    try Data(try line("a").dropLast()).write(to: logURL)
    let file = makeFile(root, io: FaultyReadIO())
    _ = file.load()

    try FileManager.default.removeItem(at: logURL)
    let absent = file.load()
    #expect(absent.ops.isEmpty && absent.ioFailure == nil)
    file.append(Entry(id: "c"))
    try await file.flush()

    #expect(try Data(contentsOf: logURL) == (try line("c")))
  }

  /// A failed log read leaves the separator as the previous load left it, in both directions.
  @Test(arguments: [false, true])
  func unreadableLogKeepsTheEarlierSeparator(earlierNeedsSeparator: Bool) async throws {
    let root = try makeDirectory("LoadSeparator")
    defer { try? FileManager.default.removeItem(at: root) }
    let logURL = root.appendingPathComponent("log.jsonl")
    let seeded = earlierNeedsSeparator ? Data(try line("a").dropLast()) : try line("a")
    try seeded.write(to: logURL)
    let io = FaultyReadIO()
    let file = makeFile(root, io: io)
    #expect(file.load().ops == [Entry(id: "a")])

    io.fail(logURL, with: ReadFailure(name: "log"))
    let unreadable = file.load()
    #expect(unreadable.ioFailure is ReadFailure)
    #expect(unreadable.ops.isEmpty)
    io.heal()
    file.append(Entry(id: "c"))
    try await file.flush()

    let separator = earlierNeedsSeparator ? Data([0x0A]) : Data()
    #expect(try Data(contentsOf: logURL) == seeded + separator + (try line("c")))
    let reloaded = makeFile(root, io: FaultyReadIO()).load()
    #expect(reloaded.ops == [Entry(id: "a"), Entry(id: "c")])
    #expect(reloaded.malformedLineCount == 0)
  }
}
