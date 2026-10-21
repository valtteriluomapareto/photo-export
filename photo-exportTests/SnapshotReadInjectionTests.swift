import Foundation
import Testing
import os

@testable import Photo_Export

@MainActor
struct SnapshotReadInjectionTests {
  private enum SnapshotReadError: Error { case unavailable }

  private final class SnapshotFaultIO: JSONLRecordLogIO, @unchecked Sendable {
    let snapshotURL: URL
    private let lock = NSLock()
    private var enabled = true
    private var readURLs: [URL] = []
    private let production = ProductionJSONLRecordLogIO()

    init(snapshotURL: URL) { self.snapshotURL = snapshotURL }

    func disableFault() {
      lock.lock()
      enabled = false
      lock.unlock()
    }

    func reads() -> [URL] {
      lock.lock()
      defer { lock.unlock() }
      return readURLs
    }

    func readIfPresent(at url: URL) throws -> Data? {
      lock.lock()
      readURLs.append(url)
      let fails = enabled && url == snapshotURL
      lock.unlock()
      if fails { throw SnapshotReadError.unavailable }
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

  private let date = Date(timeIntervalSince1970: 1_700_000_000)

  private func record(_ id: String) -> ExportRecord {
    ExportRecord(
      id: id, year: 2024, month: 4, relPath: "2024/04/",
      variants: [
        .original: ExportVariantRecord(
          filename: "\(id).JPG", status: .done, exportDate: date, lastError: nil,
          subfolder: "videos")
      ])
  }

  private func encoder() -> JSONEncoder {
    let result = JSONEncoder()
    result.dateEncodingStrategy = .iso8601
    return result
  }

  @Test func snapshotReadFailureUsesTheInjectedBoundaryAndKeepsTheReadableLog() throws {
    let root = TestScratch.directory("SnapshotReadInjection")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let snapshotURL = root.appendingPathComponent("snapshot.json")
    let logURL = root.appendingPathComponent("log.jsonl")
    let snapshot = ["snapshot": record("snapshot")]
    let mutation = ExportRecordMutation.upsert(record("log"))
    let snapshotBytes = try encoder().encode(snapshot)
    var logBytes = try encoder().encode(mutation)
    logBytes.append(0x0A)
    try snapshotBytes.write(to: snapshotURL)
    try logBytes.write(to: logURL)
    let io = SnapshotFaultIO(snapshotURL: snapshotURL)
    let file = JSONLRecordFile<[String: ExportRecord], ExportRecordMutation>(
      snapshotURL: snapshotURL, logURL: logURL,
      ioQueue: DispatchQueue(label: "SnapshotReadInjection"),
      logger: Logger(subsystem: TestLogging.subsystem, category: "SnapshotReadInjection"), logIO: io)

    let failed = file.load()
    #expect(failed.ioFailure is SnapshotReadError)
    #expect(failed.snapshot == nil && failed.snapshotStatus != .corrupt)
    #expect(failed.ops == [mutation], "The log is still independently readable")
    #expect(io.reads() == [snapshotURL, logURL])
    #expect(try Data(contentsOf: snapshotURL) == snapshotBytes)
    #expect(try Data(contentsOf: logURL) == logBytes)

    io.disableFault()
    let recovered = file.load()
    #expect(recovered.ioFailure == nil && recovered.snapshotStatus == .loaded)
    #expect(recovered.snapshot == snapshot && recovered.ops == [mutation])
    #expect(try Data(contentsOf: snapshotURL) == snapshotBytes)
    #expect(try Data(contentsOf: logURL) == logBytes)
  }

  @Test(arguments: [false, true])
  func bothStoresPreserveSnapshotAndLogUntilReadRetry(collection: Bool) throws {
    let root = TestScratch.directory("SnapshotReadInjection")
    let directory = root.appendingPathComponent("A")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let placement = ExportPlacement.favorites(createdAt: date)
    let snapshotURL = directory.appendingPathComponent(
      collection
        ? CollectionExportRecordStore.Constants.snapshotFileName
        : ExportRecordStore.Constants.snapshotFileName)
    let logURL = directory.appendingPathComponent(
      collection
        ? CollectionExportRecordStore.Constants.logFileName
        : ExportRecordStore.Constants.logFileName)
    let snapshotBytes: Data
    var logBytes: Data
    if collection {
      let body = CollectionExportRecordStore.RecordBody(
        variants: ["original": try #require(record("snapshot").variants[.original])])
      snapshotBytes = try encoder().encode(
        CollectionExportRecordStore.Snapshot(
          version: 1, placements: [placement.id: placement],
          records: [placement.id: ["snapshot": body]]))
      let logBody = CollectionExportRecordStore.RecordBody(
        variants: ["original": try #require(record("log").variants[.original])])
      logBytes = try encoder().encode(
        CollectionExportRecordStore.LogOp.upsertRecord(
          placementId: placement.id, assetId: "log", body: logBody))
    } else {
      snapshotBytes = try encoder().encode(["snapshot": record("snapshot")])
      logBytes = try encoder().encode(ExportRecordMutation.upsert(record("log")))
    }
    logBytes.append(0x0A)
    try snapshotBytes.write(to: snapshotURL)
    try logBytes.write(to: logURL)
    let io = SnapshotFaultIO(snapshotURL: snapshotURL)
    let timeline = ExportRecordStore(baseDirectoryURL: root, recordLogIO: io)
    let collections = CollectionExportRecordStore(baseDirectoryURL: root, recordLogIO: io)
    defer {
      timeline.flushForTesting()
      collections.flushForTesting()
      try? FileManager.default.removeItem(at: root)
    }
    if collection { collections.configure(for: "A") } else { timeline.configure(for: "A") }
    #expect(
      collection ? collections.state == .persistenceFailed : timeline.state == .persistenceFailed)
    #expect(try Data(contentsOf: snapshotURL) == snapshotBytes)
    #expect(try Data(contentsOf: logURL) == logBytes)
    #expect(io.reads() == [snapshotURL, logURL])

    io.disableFault()
    if collection { collections.retryPersistence() } else { timeline.retryPersistence() }
    #expect(collection ? collections.state == .ready : timeline.state == .ready)
    let variants: [String: ExportVariantRecord]
    if collection {
      let bodies = try #require(collections.recordBodies[placement.id])
      #expect(Set(bodies.keys) == ["snapshot", "log"])
      #expect(collections.placements[placement.id]?.relativePath == placement.relativePath)
      #expect(collections.placements[placement.id]?.createdAt == date)
      variants = bodies.compactMapValues { $0.variants["original"] }
    } else {
      #expect(Set(timeline.recordsById.keys) == ["snapshot", "log"])
      #expect(
        timeline.recordsById.values.allSatisfy {
          $0.year == 2024 && $0.month == 4 && $0.relPath == "2024/04/"
        })
      variants = timeline.recordsById.compactMapValues { $0.variants[.original] }
    }
    #expect(variants.values.allSatisfy { $0.status == .done && $0.subfolder == "videos" })
    #expect(variants["snapshot"]?.filename == "snapshot.JPG")
    #expect(variants["log"]?.filename == "log.JPG")
    #expect(try Data(contentsOf: snapshotURL) == snapshotBytes)
    #expect(try Data(contentsOf: logURL) == logBytes)
  }
}
