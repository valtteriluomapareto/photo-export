import Foundation
import Testing
import os

@testable import Photo_Export

@MainActor
struct JSONLRecordFileIOFailureTests {
  private struct Snapshot: Codable, Sendable, Equatable {
    var values: [String: String]
  }

  private struct Mutation: Codable, Sendable, Equatable {
    let key: String
    let value: String
  }

  enum Fault: CaseIterable, Equatable, Sendable {
    case open
    case write
    case synchronize
  }

  private enum InjectedError: Error {
    case read
    case open
    case write
    case synchronize
  }

  /// Intercepts the actual operations used by JSONLRecordFile's append path. The
  /// production implementation handles every phase except the selected failure.
  private struct FailingLogIO: JSONLRecordLogIO {
    let fault: Fault?
    let failRead: Bool
    private let production = ProductionJSONLRecordLogIO()

    func readIfPresent(at url: URL) throws -> Data? {
      if failRead { throw InjectedError.read }
      return try production.readIfPresent(at: url)
    }

    func openForAppending(at url: URL) throws -> FileHandle {
      if fault == .open { throw InjectedError.open }
      return try production.openForAppending(at: url)
    }

    func write(_ data: Data, to handle: FileHandle) throws {
      if fault == .write { throw InjectedError.write }
      try production.write(data, to: handle)
    }

    func synchronize(_ handle: FileHandle) throws {
      if fault == .synchronize { throw InjectedError.synchronize }
      try production.synchronize(handle)
    }
  }

  private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("JSONL-io-failure-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func makeFile(
    at directory: URL, logIO: any JSONLRecordLogIO = ProductionJSONLRecordLogIO()
  ) -> JSONLRecordFile<Snapshot, Mutation> {
    JSONLRecordFile(
      snapshotURL: directory.appendingPathComponent("snapshot.json"),
      logURL: directory.appendingPathComponent("log.jsonl"),
      ioQueue: DispatchQueue(label: "JSONL-io-failure-\(UUID().uuidString)"),
      logger: Logger(subsystem: "test", category: "JSONLIOFailure"),
      logIO: logIO)
  }

  @Test func missingLogIsHealthyButUnreadableLogIsNot() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let file = makeFile(at: directory)
    let absent = file.load()
    #expect(absent.snapshotStatus == .absent)
    #expect(absent.ops.isEmpty)
    #expect(absent.ioFailure == nil)

    let logURL = directory.appendingPathComponent("log.jsonl")
    try FileManager.default.createDirectory(at: logURL, withIntermediateDirectories: false)
    let unreadable = file.load()
    #expect(unreadable.ops.isEmpty)
    #expect(unreadable.ioFailure != nil)
  }

  @Test func injectedReadErrorCannotBecomeAnEmptyHealthyLog() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let file = makeFile(at: directory, logIO: FailingLogIO(fault: nil, failRead: true))
    let loaded = file.load()
    #expect(loaded.ops.isEmpty)
    #expect(loaded.ioFailure is InjectedError)
  }

  @Test func danglingLogSymlinkIsNotMistakenForMissingLog() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let linkURL = directory.appendingPathComponent("log.jsonl")
    try FileManager.default.createSymbolicLink(
      at: linkURL, withDestinationURL: directory.appendingPathComponent("missing-target"))
    let loaded = makeFile(at: directory).load()
    #expect(loaded.ops.isEmpty)
    #expect(loaded.ioFailure != nil)
  }

  @Test func unreadableSnapshotIsIOFailureButMalformedSnapshotIsCorruption() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let snapshotURL = directory.appendingPathComponent("snapshot.json")
    try FileManager.default.createDirectory(at: snapshotURL, withIntermediateDirectories: false)
    let unreadable = makeFile(at: directory).load()
    #expect(unreadable.snapshotStatus == .absent)
    #expect(unreadable.ioFailure != nil)

    try FileManager.default.removeItem(at: snapshotURL)
    try Data("not-json".utf8).write(to: snapshotURL)
    let malformed = makeFile(at: directory).load()
    #expect(malformed.snapshotStatus == .corrupt)
    #expect(malformed.ioFailure == nil)
  }

  @Test func truncatedFinalLineRemainsRecoverable() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let op = Mutation(key: "durable", value: "value")
    var bytes = try JSONEncoder().encode(op)
    bytes.append(0x0A)
    bytes.append(contentsOf: "{\"key\":\"partial\"".utf8)
    try bytes.write(to: directory.appendingPathComponent("log.jsonl"))

    let loaded = makeFile(at: directory).load()
    #expect(loaded.ops == [op])
    #expect(loaded.malformedLineCount == 1)
    #expect(loaded.ioFailure == nil)
  }

  @Test(arguments: Fault.allCases)
  func appendFailureIsReportedAndSnapshotRetryRetainsSkippedOperations(fault: Fault) async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let file = makeFile(at: directory, logIO: FailingLogIO(fault: fault, failRead: false))
    var failures: [String] = []
    file.onPersistenceFailure = { failures.append(String(describing: $0)) }

    // The composing store applies both changes before its asynchronous IO completes.
    // The second queued append must not jump past the first failed one.
    let retained = Snapshot(values: ["first": "1", "second": "2"])
    file.append(Mutation(key: "first", value: "1"), currentSnapshot: { retained })
    file.append(Mutation(key: "second", value: "2"), currentSnapshot: { retained })
    await #expect(throws: (any Error).self) { try await file.flush() }
    #expect(failures.count == 1)
    let beforeRetry = makeFile(at: directory).load()
    #expect(beforeRetry.ops.allSatisfy { $0.key != "second" })

    // Retry writes the entire retained state, then releases the failure latch. The
    // injected append fault remains active, but snapshot recovery itself is independent.
    try file.writeSnapshot(retained)
    try await file.flush()
    let reopened = makeFile(at: directory).load()
    #expect(reopened.ioFailure == nil)
    #expect(reopened.snapshot == retained)
    #expect(reopened.ops.isEmpty)
  }
}
