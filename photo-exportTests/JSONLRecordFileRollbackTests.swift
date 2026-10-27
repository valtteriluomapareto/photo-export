import Foundation
import Testing
import os

@testable import Photo_Export

/// Covers explicit snapshot encode failure and the failed-append recovery latch.
/// A failed encoding preserves the durable log and can be retried without another append.
@MainActor
struct JSONLRecordFileRollbackTests {

  // MARK: - Test fixtures

  /// A snapshot type whose `encode(to:)` is gated by an instance flag. When
  /// `shouldThrow == true`, encoding throws — simulating a regression in the
  /// production Snapshot type that breaks `JSONEncoder` compatibility.
  fileprivate struct ConditionalSnapshot: Codable, Sendable, Equatable {
    var records: [String: String]
    var shouldThrow: Bool

    init(records: [String: String] = [:], shouldThrow: Bool = false) {
      self.records = records
      self.shouldThrow = shouldThrow
    }

    enum CodingKeys: String, CodingKey { case records }

    func encode(to encoder: Encoder) throws {
      if shouldThrow {
        throw EncodingError.invalidValue(
          "test",
          EncodingError.Context(
            codingPath: [], debugDescription: "intentional encode failure for rollback test"
          ))
      }
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(records, forKey: .records)
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      self.records = try c.decodeIfPresent([String: String].self, forKey: .records) ?? [:]
      self.shouldThrow = false
    }
  }

  fileprivate struct Operation: Codable, Sendable, Equatable {
    let key: String
    let value: String
  }

  private func makeStore(at dir: URL) -> (
    JSONLRecordFile<ConditionalSnapshot, Operation>, DispatchQueue
  ) {
    let queue = DispatchQueue(
      label: "JSONLRecordFile-rollback-\(UUID().uuidString)", qos: .utility)
    let file = JSONLRecordFile<ConditionalSnapshot, Operation>(
      snapshotURL: dir.appendingPathComponent("snapshot.json"),
      logURL: dir.appendingPathComponent("log.jsonl"),
      ioQueue: queue,
      logger: Logger(subsystem: TestLogging.subsystem, category: "JSONLRecordFile-rollback")
    )
    return (file, queue)
  }

  /// `drainSynchronously` drains `ioQueue` synchronously, but the rollback hops
  /// back through `Task { @MainActor }`. Yielding gives that hop a chance to
  /// run on the main actor before the test continues.
  private func drainIOAndRollbacks(_ file: JSONLRecordFile<ConditionalSnapshot, Operation>)
    async
  {
    file.drainSynchronously()
    await Task.yield()
    await Task.yield()
  }

  @Test func snapshotEncodeFailureAllowsExplicitCheckpointRetry() async throws {
    let dir = TestScratch.directory("JSONLRollback")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let (file, _) = makeStore(at: dir)
    file.append(Operation(key: "crossing", value: "v"))
    try await file.flush()
    let logURL = dir.appendingPathComponent("log.jsonl")
    let durableLog = try Data(contentsOf: logURL)
    do {
      try await file.checkpoint(ConditionalSnapshot(records: ["crossing": "v"], shouldThrow: true))
      Issue.record("Encoding should fail")
    } catch {}
    #expect(
      !FileManager.default.fileExists(atPath: dir.appendingPathComponent("snapshot.json").path))
    #expect(try Data(contentsOf: logURL) == durableLog)
    #expect(file.hasReplayWork)
    try await file.checkpoint(ConditionalSnapshot(records: ["crossing": "v"]))
    let loaded = file.load()
    #expect(loaded.snapshot?.records == ["crossing": "v"])
    #expect(loaded.ops.isEmpty)
  }

  // MARK: - Log-write-failure rollback

  /// Force `appendLogLine` to throw by pointing the JSONLRecordFile at a
  /// non-existent parent directory. The first append's `FileHandle(forWritingTo:)`
  /// throws (it can't open the file because the parent directory is gone).
  /// The failed operation is retained by the owner in memory. Later appends must remain
  /// blocked until the owner writes a complete recovery snapshot.
  ///
  /// The observable distinction here is that the **op data does NOT land on disk**;
  /// an explicit snapshot retry is required before later appends can be acknowledged.
  @Test func logWriteFailureRequiresSnapshotRecoveryBeforeLaterAppend() async throws {
    // A directory that does not exist on disk. `appendLogLine` will fail to
    // open a FileHandle to a path inside it.
    let nonexistentDir = TestScratch.directory("JSONLRollback-Missing")
      .appendingPathComponent("subdir", isDirectory: true)
    // (Intentionally do NOT create this directory.)

    let queue = DispatchQueue(
      label: "JSONLRecordFile-logfail-\(UUID().uuidString)", qos: .utility)
    let file = JSONLRecordFile<ConditionalSnapshot, Operation>(
      snapshotURL: nonexistentDir.appendingPathComponent("snapshot.json"),
      logURL: nonexistentDir.appendingPathComponent("log.jsonl"),
      ioQueue: queue,
      logger: Logger(subsystem: TestLogging.subsystem, category: "JSONLRecordFile-logfail")
    )

    let op = Operation(key: "k", value: "v")
    file.append(op)
    await drainIOAndRollbacks(file)

    // Log file does not exist (write failed; rollback fired).
    #expect(!FileManager.default.fileExists(atPath: nonexistentDir.path))

    // load() returns empty everywhere — no log to read, no snapshot, no ops.
    let loaded = file.load()
    #expect(loaded.snapshot == nil)
    #expect(loaded.ops.isEmpty)
    #expect(loaded.malformedLineCount == 0)

    // Merely restoring the parent directory cannot make a later operation durable:
    // the missing first operation still exists only in the owner's memory.
    try FileManager.default.createDirectory(
      at: nonexistentDir, withIntermediateDirectories: true)
    let recovered = Operation(key: "ok", value: "v")
    file.append(recovered)
    await drainIOAndRollbacks(file)
    #expect(file.load().ops.isEmpty)

    // The owner retries by saving its complete retained state. Subsequent appends now
    // proceed, and reopening recovers both the originally failed and later operation.
    try file.writeSnapshot(ConditionalSnapshot(records: ["k": "v", "ok": "v"]))
    let afterRecovery = Operation(key: "later", value: "v")
    file.append(afterRecovery)
    await drainIOAndRollbacks(file)

    let loadedAfterRecovery = file.load()
    #expect(loadedAfterRecovery.snapshot?.records == ["k": "v", "ok": "v"])
    #expect(loadedAfterRecovery.ops == [afterRecovery])
  }
}
