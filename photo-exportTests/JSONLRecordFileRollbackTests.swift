import Foundation
import Testing
import os

@testable import Photo_Export

/// Covers snapshot encode-failure rollback and the failed-append recovery latch.
/// Neither path is exercised by happy-path round-trip tests: losing the rollback
/// delays compaction, while retrying appends after a missing log op could discard
/// state that only the composing store still holds in memory.
///
/// The compaction rollback runs via `Task { @MainActor }` inside `ioQueue.async`,
/// so observing it from a `@MainActor` test requires
/// (a) `flushForTesting()` to drain the queue and (b) an `await Task.yield()`
/// to let the queued main-actor Task run.
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

  fileprivate struct Op: Codable, Sendable, Equatable {
    let key: String
    let value: String
  }

  private func makeStore(at dir: URL) -> (
    JSONLRecordFile<ConditionalSnapshot, Op>, DispatchQueue
  ) {
    let queue = DispatchQueue(
      label: "JSONLRecordFile-rollback-\(UUID().uuidString)", qos: .utility)
    let file = JSONLRecordFile<ConditionalSnapshot, Op>(
      snapshotURL: dir.appendingPathComponent("snapshot.json"),
      logURL: dir.appendingPathComponent("log.jsonl"),
      ioQueue: queue,
      logger: Logger(subsystem: "test", category: "JSONLRecordFile-rollback")
    )
    return (file, queue)
  }

  /// `flushForTesting` drains `ioQueue` synchronously, but the rollback hops
  /// back through `Task { @MainActor }`. Yielding gives that hop a chance to
  /// run on the main actor before the test continues.
  private func drainIOAndRollbacks(_ file: JSONLRecordFile<ConditionalSnapshot, Op>)
    async
  {
    file.flushForTesting()
    await Task.yield()
    await Task.yield()
  }

  // MARK: - Snapshot encode-failure rollback

  /// Drive (n - 1) ops with non-throwing snapshots, then op n with a throwing
  /// snapshot (threshold-crossing → encode → throws → rollback). After the
  /// rollback lands, `mutationCountSinceCompact == compactEveryNMutations - 1`,
  /// so the next single append re-triggers compaction. The observable
  /// distinction:
  /// - **With** the rollback intact: snapshot file lands after one more append.
  /// - **Without** the rollback: counter stays at 0 (the synchronous reset
  ///   that ran before the failed encode), and the next append doesn't compact.
  ///
  /// We assert the post-rollback retry compacts successfully — that's the
  /// observable proof the rollback fired.
  @Test func snapshotEncodeFailureRollbackAllowsNextAppendToRetryCompaction() async throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("JSONLRollback-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let (file, _) = makeStore(at: dir)
    let n = JSONLRecordFile<ConditionalSnapshot, Op>.Constants.compactEveryNMutations
    let snapshotURL = dir.appendingPathComponent("snapshot.json")

    // Drive (n - 1) ops with non-throwing snapshots.
    var rolling: [String: String] = [:]
    for i in 0..<(n - 1) {
      let op = Op(key: "k\(i)", value: "v\(i)")
      rolling["k\(i)"] = "v\(i)"
      let frozen = rolling
      file.append(op, currentSnapshot: { ConditionalSnapshot(records: frozen) })
    }
    await drainIOAndRollbacks(file)
    #expect(!FileManager.default.fileExists(atPath: snapshotURL.path))

    // Threshold-crossing append with a throwing snapshot. The encode fails on
    // ioQueue; rollback dispatches back to MainActor and sets the counter to
    // compactEveryNMutations - 1.
    let crossing = Op(key: "crossing", value: "v")
    rolling["crossing"] = "v"
    let frozenCrossing = rolling
    file.append(
      crossing,
      currentSnapshot: { ConditionalSnapshot(records: frozenCrossing, shouldThrow: true) })
    await drainIOAndRollbacks(file)

    // Snapshot must NOT exist (the encode threw before the file write was reached).
    #expect(
      !FileManager.default.fileExists(atPath: snapshotURL.path),
      "encode-failure path must not produce a snapshot file")

    // Log has n lines (the crossing op's log line was written before the encode
    // attempt; only the snapshot/truncate step failed).
    let loadedAfterFailure = file.load()
    #expect(loadedAfterFailure.snapshot == nil)
    #expect(loadedAfterFailure.ops.count == n)

    // One more append with a non-throwing snapshot. If the rollback fired, the
    // counter is at compactEveryNMutations - 1, so this single append re-crosses
    // the threshold and compacts successfully.
    let retry = Op(key: "retry", value: "v")
    rolling["retry"] = "v"
    let frozenRetry = rolling
    file.append(retry, currentSnapshot: { ConditionalSnapshot(records: frozenRetry) })
    await drainIOAndRollbacks(file)

    #expect(
      FileManager.default.fileExists(atPath: snapshotURL.path),
      "post-rollback retry must compact successfully — proves rollback fired")

    // Loaded state: snapshot reflects the full pre-retry state plus the retry op
    // (retry op crosses the threshold and is included in the captured snapshot
    // because contribution happens before the closure freezes; log is empty.
    let loadedAfterRetry = file.load()
    #expect(loadedAfterRetry.snapshot != nil)
    #expect(loadedAfterRetry.snapshot?.records["retry"] == "v")
    #expect(loadedAfterRetry.ops.isEmpty, "log truncated after successful compaction")
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
    let nonexistentDir = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "JSONLRollback-Missing-\(UUID().uuidString)/subdir", isDirectory: true)
    // (Intentionally do NOT create this directory.)

    let queue = DispatchQueue(
      label: "JSONLRecordFile-logfail-\(UUID().uuidString)", qos: .utility)
    let file = JSONLRecordFile<ConditionalSnapshot, Op>(
      snapshotURL: nonexistentDir.appendingPathComponent("snapshot.json"),
      logURL: nonexistentDir.appendingPathComponent("log.jsonl"),
      ioQueue: queue,
      logger: Logger(subsystem: "test", category: "JSONLRecordFile-logfail")
    )

    let op = Op(key: "k", value: "v")
    file.append(op, currentSnapshot: { ConditionalSnapshot() })
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
    let recovered = Op(key: "ok", value: "v")
    file.append(recovered, currentSnapshot: { ConditionalSnapshot() })
    await drainIOAndRollbacks(file)
    #expect(file.load().ops.isEmpty)

    // The owner retries by saving its complete retained state. Subsequent appends now
    // proceed, and reopening recovers both the originally failed and later operation.
    try file.writeSnapshot(ConditionalSnapshot(records: ["k": "v", "ok": "v"]))
    let afterRecovery = Op(key: "later", value: "v")
    file.append(afterRecovery, currentSnapshot: { ConditionalSnapshot() })
    await drainIOAndRollbacks(file)

    let loadedAfterRecovery = file.load()
    #expect(loadedAfterRecovery.snapshot?.records == ["k": "v", "ok": "v"])
    #expect(loadedAfterRecovery.ops == [afterRecovery])
  }
}
