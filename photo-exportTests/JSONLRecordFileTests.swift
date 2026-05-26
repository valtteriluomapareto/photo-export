import Foundation
import Testing
import os

@testable import Photo_Export

/// Tests for the shared persistence component. Both `ExportRecordStore` and the future
/// `CollectionExportRecordStore` compose this; the `ExportRecordStore` test suites cover the
/// composing-store concerns, this file focuses on the generic file-level invariants.
@MainActor
struct JSONLRecordFileTests {

  // MARK: - Test fixtures

  private struct Snapshot: Codable, Sendable, Equatable {
    var records: [String: String]
  }

  private struct Op: Codable, Sendable, Equatable {
    enum Kind: String, Codable { case upsert, delete }
    let kind: Kind
    let key: String
    let value: String?
  }

  private func makeStore() throws -> (
    URL, JSONLRecordFile<Snapshot, Op>, DispatchQueue
  ) {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("JSONLRecordFile-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let queue = DispatchQueue(label: "JSONLRecordFile-test-\(UUID().uuidString)", qos: .utility)
    let file = JSONLRecordFile<Snapshot, Op>(
      snapshotURL: dir.appendingPathComponent("snapshot.json"),
      logURL: dir.appendingPathComponent("log.jsonl"),
      ioQueue: queue,
      logger: Logger(subsystem: "test", category: "JSONLRecordFile")
    )
    return (dir, file, queue)
  }

  private func emptySnapshot() -> Snapshot { Snapshot(records: [:]) }

  // MARK: - Load (empty / missing)

  @Test func loadReturnsEmptyWhenNothingOnDisk() throws {
    let (dir, file, _) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let result = file.load()
    #expect(result.snapshot == nil)
    #expect(result.ops.isEmpty)
    #expect(result.malformedLineCount == 0)
  }

  // MARK: - Append + load roundtrip

  @Test func appendThenLoadRecoversOps() throws {
    let (dir, file, _) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let op1 = Op(kind: .upsert, key: "a", value: "1")
    let op2 = Op(kind: .upsert, key: "b", value: "2")
    file.append(op1, currentSnapshot: { Snapshot(records: ["a": "1"]) })
    file.append(op2, currentSnapshot: { Snapshot(records: ["a": "1", "b": "2"]) })
    file.flushForTesting()

    let result = file.load()
    #expect(result.snapshot == nil)  // neither append crossed the threshold
    #expect(result.ops == [op1, op2])
    #expect(result.malformedLineCount == 0)
  }

  // MARK: - Malformed lines

  @Test func loadSkipsMalformedLinesAndCountsThem() throws {
    let (dir, file, _) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let op = Op(kind: .upsert, key: "a", value: "1")
    file.append(op, currentSnapshot: { Snapshot(records: ["a": "1"]) })
    file.flushForTesting()

    // Inject a malformed line into the log.
    let logURL = dir.appendingPathComponent("log.jsonl")
    var logBytes = try Data(contentsOf: logURL)
    logBytes.append("not-json\n".data(using: .utf8)!)
    try logBytes.write(to: logURL)
    // Append another good line after the malformed one.
    let op2 = Op(kind: .upsert, key: "b", value: "2")
    file.append(op2, currentSnapshot: { Snapshot(records: ["a": "1", "b": "2"]) })
    file.flushForTesting()

    let result = file.load()
    #expect(result.ops == [op, op2])
    #expect(result.malformedLineCount == 1)
  }

  // MARK: - writeSnapshot

  @Test func writeSnapshotPersistsAndTruncates() throws {
    let (dir, file, _) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let op = Op(kind: .upsert, key: "a", value: "1")
    file.append(op, currentSnapshot: { emptySnapshot() })
    file.flushForTesting()

    // Manual snapshot write should leave only the snapshot, no log content.
    try file.writeSnapshot(Snapshot(records: ["a": "1", "b": "2"]))

    let result = file.load()
    #expect(result.snapshot == Snapshot(records: ["a": "1", "b": "2"]))
    #expect(result.ops.isEmpty)
  }

  // MARK: - Atomic write: snapshot fsync produces durable file

  @Test func writeSnapshotProducesFileEvenAfterSubsequentTruncate() throws {
    let (dir, file, _) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    try file.writeSnapshot(Snapshot(records: ["x": "y"]))
    let snapshotPath = dir.appendingPathComponent("snapshot.json").path
    let logPath = dir.appendingPathComponent("log.jsonl").path
    #expect(FileManager.default.fileExists(atPath: snapshotPath))
    #expect(FileManager.default.fileExists(atPath: logPath))
    let logBytes = try Data(contentsOf: dir.appendingPathComponent("log.jsonl"))
    #expect(logBytes.isEmpty)

    // No `.tmp` files left behind.
    let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    let tmpFiles = contents.filter { $0.hasSuffix(".tmp") }
    #expect(tmpFiles.isEmpty)
  }

  // MARK: - clearOnDiskState

  @Test func clearOnDiskStateRemovesBothFiles() throws {
    let (dir, file, _) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let op = Op(kind: .upsert, key: "a", value: "1")
    file.append(op, currentSnapshot: { emptySnapshot() })
    try file.writeSnapshot(Snapshot(records: ["a": "1"]))
    file.flushForTesting()

    file.clearOnDiskState()

    let snapshotPath = dir.appendingPathComponent("snapshot.json").path
    let logPath = dir.appendingPathComponent("log.jsonl").path
    #expect(!FileManager.default.fileExists(atPath: snapshotPath))
    #expect(!FileManager.default.fileExists(atPath: logPath))

    // Subsequent load returns empty.
    let result = file.load()
    #expect(result.snapshot == nil)
    #expect(result.ops.isEmpty)
  }

  // MARK: - Bulk reader edge cases
  //
  // The line reader was rewritten from per-byte `FileHandle.read(upToCount: 1)`
  // to one-shot `Data(contentsOf:) + split(separator: 0x0A)` for a 20× speedup
  // on warm reads. These tests pin the file-shape edge cases where the two
  // implementations differ subtly.

  @Test func loadHandlesLogWithoutTrailingNewline() throws {
    let (dir, file, _) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    // Write two JSON ops separated by a single newline, NO trailing newline
    // on the last line. The historical line reader returned the
    // unterminated tail as a final line; bulk-read must preserve that
    // behaviour so a crash mid-write doesn't drop the last durable line.
    let op1Data = try JSONEncoder().encode(Op(kind: .upsert, key: "a", value: "1"))
    let op2Data = try JSONEncoder().encode(Op(kind: .upsert, key: "b", value: "2"))
    var bytes = Data()
    bytes.append(op1Data)
    bytes.append(0x0A)
    bytes.append(op2Data)  // no trailing 0x0A
    let logURL = dir.appendingPathComponent("log.jsonl")
    try bytes.write(to: logURL)

    let result = file.load()
    #expect(
      result.ops == [
        Op(kind: .upsert, key: "a", value: "1"),
        Op(kind: .upsert, key: "b", value: "2"),
      ])
    #expect(result.malformedLineCount == 0)
  }

  @Test func loadSkipsConsecutiveBlankLines() throws {
    let (dir, file, _) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    // A series of consecutive newlines must not be treated as malformed
    // lines — they're zero-byte separators, not zero-byte JSON. The bulk
    // reader's `split(separator:omittingEmptySubsequences:)` defaults to
    // dropping empty subsequences; this test pins that contract.
    let op1Data = try JSONEncoder().encode(Op(kind: .upsert, key: "a", value: "1"))
    let op2Data = try JSONEncoder().encode(Op(kind: .upsert, key: "b", value: "2"))
    var bytes = Data()
    bytes.append(op1Data)
    bytes.append(contentsOf: [0x0A, 0x0A, 0x0A])  // three newlines
    bytes.append(op2Data)
    bytes.append(0x0A)
    let logURL = dir.appendingPathComponent("log.jsonl")
    try bytes.write(to: logURL)

    let result = file.load()
    #expect(
      result.ops == [
        Op(kind: .upsert, key: "a", value: "1"),
        Op(kind: .upsert, key: "b", value: "2"),
      ])
    #expect(result.malformedLineCount == 0)
  }

  @Test func loadHandlesZeroByteLogFile() throws {
    let (dir, file, _) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    // Distinct from `loadReturnsEmptyWhenNothingOnDisk`: the file exists
    // but is zero bytes. Bulk read's `Data(contentsOf:)` returns empty
    // `Data`, `split` yields no slices, and the load surfaces no ops and
    // no malformed-line count.
    let logURL = dir.appendingPathComponent("log.jsonl")
    try Data().write(to: logURL)
    #expect(FileManager.default.fileExists(atPath: logURL.path))

    let result = file.load()
    #expect(result.ops.isEmpty)
    #expect(result.malformedLineCount == 0)
  }

  // MARK: - Compaction trigger

  /// Crossing the mutation-count threshold writes a snapshot and truncates the log so the
  /// next load returns the snapshot alone (no log replay).
  @Test func compactionWritesSnapshotAndTruncatesLog() throws {
    let (dir, file, _) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    // Stuff `compactEveryNMutations` ops through. The last one triggers compaction.
    let n = JSONLRecordFile<Snapshot, Op>.Constants.compactEveryNMutations
    var rolling: [String: String] = [:]
    for i in 0..<n {
      let op = Op(kind: .upsert, key: "k\(i)", value: "v\(i)")
      rolling["k\(i)"] = "v\(i)"
      let captured = rolling
      file.append(op, currentSnapshot: { Snapshot(records: captured) })
    }
    file.flushForTesting()

    let result = file.load()
    #expect(result.snapshot == Snapshot(records: rolling))
    #expect(result.ops.isEmpty)
  }
}
