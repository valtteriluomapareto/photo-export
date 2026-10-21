import Foundation
import Testing
import os

@testable import Photo_Export

/// Stress / round-trip characterization tests for `JSONLRecordFile`. These exist to lock
/// in the persistence contract before the planned performance work that moves snapshot
/// encoding off the main actor.
///
/// **Invariant under test:** for any sequence of `append` calls, after `drainSynchronously`,
/// the next `load()` plus an in-order replay of `ops` reproduces the same logical state
/// the in-memory caller maintained. Whether that state is reconstructed from
/// snapshot-only, log-only, or snapshot+log-overlay is an implementation detail; the
/// reproduction must be exact.
///
/// Existing `JSONLRecordFileTests` covers the basic happy paths (one append, one
/// compaction, malformed line). This file adds:
/// - Heavy churn (upsert→update→update→delete) preserved across reload.
/// - Compaction mid-stream + further mutations replayed correctly.
/// - Snapshot+log overlay (post-compaction appends) reload.
/// - Multiple compactions in a single run.
/// - Out-of-threshold append count survives reload (no spurious compaction triggered by
///   load alone).
@MainActor
struct JSONLRecordFileRoundTripTests {

  // MARK: - Test fixtures

  fileprivate struct Snapshot: Codable, Sendable, Equatable {
    var records: [String: String]
  }

  fileprivate struct Operation: Codable, Sendable, Equatable {
    enum Kind: String, Codable { case upsert, delete }
    let kind: Kind
    let key: String
    let value: String?  // nil for delete
  }

  /// In-memory replica that mirrors what the composing store would maintain.
  fileprivate final class Replica {
    var records: [String: String] = [:]
    func apply(_ op: Operation) {
      switch op.kind {
      case .upsert: records[op.key] = op.value ?? ""
      case .delete: records.removeValue(forKey: op.key)
      }
    }
    var snapshot: Snapshot { Snapshot(records: records) }
  }

  private func makeStore() throws -> (
    URL, JSONLRecordFile<Snapshot, Operation>, DispatchQueue
  ) {
    let dir = TestScratch.directory("JSONLRecordFileRoundTrip")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let queue = DispatchQueue(
      label: "JSONLRecordFile-rt-\(UUID().uuidString)", qos: .utility)
    let file = JSONLRecordFile<Snapshot, Operation>(
      snapshotURL: dir.appendingPathComponent("snapshot.json"),
      logURL: dir.appendingPathComponent("log.jsonl"),
      ioQueue: queue,
      logger: Logger(subsystem: TestLogging.subsystem, category: "JSONLRecordFile-rt")
    )
    return (dir, file, queue)
  }

  /// Helper: run a sequence of ops through both the file and a replica, then verify that
  /// loading the file and replaying its ops reproduces the replica's state.
  private func driveAndVerify(
    file: JSONLRecordFile<Snapshot, Operation>, replica: Replica, ops: [Operation]
  ) {
    for op in ops {
      replica.apply(op)
      let captured = replica.snapshot
      file.append(op, currentSnapshot: { captured })
    }
    file.drainSynchronously()

    let loaded = file.load()
    var reconstructed = loaded.snapshot?.records ?? [:]
    for op in loaded.ops {
      switch op.kind {
      case .upsert: reconstructed[op.key] = op.value ?? ""
      case .delete: reconstructed.removeValue(forKey: op.key)
      }
    }
    #expect(reconstructed == replica.records, "round-trip reproduction must match replica")
  }

  // MARK: - Heavy churn round-trip

  /// 50 keys × 5 mutations each (upsert → update → update → delete → upsert), no
  /// compaction reached. Pure log replay must reproduce the final state exactly.
  @Test func churnNoCompactionRoundTrip() throws {
    let (dir, file, _) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let replica = Replica()

    var ops: [Operation] = []
    for k in 0..<50 {
      let key = "k\(k)"
      ops.append(Operation(kind: .upsert, key: key, value: "v0"))
      ops.append(Operation(kind: .upsert, key: key, value: "v1"))
      ops.append(Operation(kind: .upsert, key: key, value: "v2"))
      ops.append(Operation(kind: .delete, key: key, value: nil))
      ops.append(Operation(kind: .upsert, key: key, value: "final"))
    }
    // 250 ops; threshold is 1000 → no compaction yet.
    driveAndVerify(file: file, replica: replica, ops: ops)

    let loaded = file.load()
    #expect(loaded.snapshot == nil, "no compaction should have run yet")
    #expect(loaded.ops.count == ops.count)
  }

  // MARK: - Off-main-actor encode (threading invariant)

  /// `append` must return promptly even when crossing the compaction threshold with a
  /// large snapshot. The encode used to run synchronously on the calling actor, which
  /// stalled the main actor for seconds at scale (~150 MB JSON for a 500k-record store).
  /// The current implementation captures the snapshot synchronously (cheap CoW) and
  /// dispatches the encode + write to `ioQueue`, so the calling-actor wall-time of the
  /// threshold-crossing append is bounded by the cheap-capture cost, not by the encode
  /// cost.
  ///
  /// Test approach: **suspend the IO queue** before the threshold-crossing append so the
  /// dispatched encode + write cannot run, then assert the snapshot file is absent
  /// immediately after `append` returns. Without the suspend the test relies on the
  /// main actor winning a race against `ioQueue` — usually true on a developer machine
  /// (the encode + write takes milliseconds; the next test instruction is microseconds
  /// away) but a fast SSD plus a busy main actor could in principle invert the order.
  /// Suspending makes the assertion deterministic.
  @Test func appendReturnsBeforeSnapshotIsWrittenAtThresholdCrossing() throws {
    let (dir, file, queue) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let snapshotURL = dir.appendingPathComponent("snapshot.json")
    let n = JSONLRecordFile<Snapshot, Operation>.Constants.compactEveryNMutations

    // Drive (n - 1) ops without crossing the threshold so we can isolate the
    // threshold-crossing call.
    var rolling: [String: String] = [:]
    for i in 0..<(n - 1) {
      let op = Operation(kind: .upsert, key: "k\(i)", value: "v\(i)")
      rolling["k\(i)"] = "v\(i)"
      let captured = rolling
      file.append(op, currentSnapshot: { Snapshot(records: captured) })
    }
    // Drain the ioQueue so the n-1 log lines are durable; snapshot still absent.
    file.drainSynchronously()
    #expect(!FileManager.default.fileExists(atPath: snapshotURL.path))

    // Build a heavy snapshot to amplify the encode cost (~1 MB of JSON).
    var heavy: [String: String] = rolling
    for i in 0..<1000 {
      heavy["heavy-k\(i)"] = String(repeating: "x", count: 1000)
    }
    heavy["k\(n - 1)"] = "v"

    // Suspend the ioQueue. Anything dispatched onto it from this point on is queued but
    // not executed until we resume. This makes the "snapshot must not be on disk"
    // assertion deterministic — without the suspend, we'd be racing the queue.
    // (Swift Testing's `#expect(boolExpr)` records issues without throwing, so the
    // function flows linearly and a failed assertion does not leak a suspended queue.)
    queue.suspend()

    let crossing = Operation(kind: .upsert, key: "k\(n - 1)", value: "v")
    file.append(crossing, currentSnapshot: { Snapshot(records: heavy) })

    // The append-log + encode + snapshot-write all run on the suspended queue, so
    // nothing should have landed.
    #expect(
      !FileManager.default.fileExists(atPath: snapshotURL.path),
      "snapshot must NOT be on disk synchronously — encode + write run on ioQueue"
    )

    // Resume + drain confirms the snapshot eventually lands and reflects the frozen
    // `heavy` capture.
    queue.resume()
    file.drainSynchronously()
    #expect(FileManager.default.fileExists(atPath: snapshotURL.path))
    let loaded = file.load()
    #expect(loaded.snapshot?.records.count == heavy.count)
  }

  // MARK: - Cross-threshold compaction

  /// Crossing the threshold once + a few more appends afterward: load must produce the
  /// snapshot **plus** the post-compaction log lines, and overlay them in order.
  @Test func compactionWithPostCompactionAppendsRoundTrip() throws {
    let (dir, file, _) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let replica = Replica()

    let n = JSONLRecordFile<Snapshot, Operation>.Constants.compactEveryNMutations
    var ops: [Operation] = []
    for i in 0..<n {
      ops.append(Operation(kind: .upsert, key: "k\(i)", value: "v\(i)"))
    }
    // Five more appends after the threshold-triggering one.
    for i in 0..<5 {
      ops.append(Operation(kind: .upsert, key: "post-\(i)", value: "p\(i)"))
    }
    driveAndVerify(file: file, replica: replica, ops: ops)

    let loaded = file.load()
    #expect(loaded.snapshot != nil, "compaction must have written a snapshot")
    #expect(loaded.ops.count == 5, "post-compaction log lines must remain")
    // Snapshot reflects the state at the threshold-crossing append.
    let postOps = ops.suffix(5)
    let preCompactionState = ops.dropLast(5).reduce(into: [String: String]()) { acc, op in
      switch op.kind {
      case .upsert: acc[op.key] = op.value ?? ""
      case .delete: acc.removeValue(forKey: op.key)
      }
    }
    #expect(loaded.snapshot?.records == preCompactionState)
    #expect(Array(postOps) == loaded.ops)
  }

  // MARK: - Multiple compactions

  /// Run through the threshold three times (3 × N ops). Final load must yield a single
  /// snapshot reflecting the full post-state and an empty log (last batch ended exactly
  /// on a threshold).
  @Test func multipleCompactionsRoundTrip() throws {
    let (dir, file, _) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let replica = Replica()

    let n = JSONLRecordFile<Snapshot, Operation>.Constants.compactEveryNMutations
    var ops: [Operation] = []
    for batch in 0..<3 {
      for i in 0..<n {
        ops.append(Operation(kind: .upsert, key: "k-\(batch)-\(i)", value: "v"))
      }
    }
    driveAndVerify(file: file, replica: replica, ops: ops)

    let loaded = file.load()
    #expect(loaded.snapshot != nil)
    #expect(loaded.ops.isEmpty, "final batch ended on a threshold; log should be truncated")
    #expect(loaded.snapshot?.records.count == 3 * n)
  }

  // MARK: - Compaction interleaved with deletes

  /// A delete crossing the threshold must produce a snapshot that omits the deleted key.
  @Test func compactionAfterDeletesProducesAccurateSnapshot() throws {
    let (dir, file, _) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let replica = Replica()

    let n = JSONLRecordFile<Snapshot, Operation>.Constants.compactEveryNMutations
    var ops: [Operation] = []
    // Insert n-100 keys, delete 100 of them, then insert 100 more so the threshold
    // crosses on the (n)th op.
    for i in 0..<(n - 100) {
      ops.append(Operation(kind: .upsert, key: "k\(i)", value: "v\(i)"))
    }
    for i in 0..<100 {
      ops.append(Operation(kind: .delete, key: "k\(i)", value: nil))
    }
    for i in 0..<100 {
      ops.append(Operation(kind: .upsert, key: "post-\(i)", value: "p\(i)"))
    }
    driveAndVerify(file: file, replica: replica, ops: ops)

    let loaded = file.load()
    #expect(loaded.snapshot != nil)
    // Snapshot should NOT contain the 100 deleted keys.
    for i in 0..<100 {
      #expect(loaded.snapshot?.records["k\(i)"] == nil, "deleted key must not be in snapshot")
    }
    // The threshold-crossing op is the (n)th overall: n-100 inserts + 100 deletes.
    // Snapshot at compaction time = n-100 inserts - 100 deletes = n - 200 keys.
    // The 100 post-* inserts are ops 1001-1100 and live in the log.
    #expect(loaded.snapshot?.records.count == n - 200)
    #expect(loaded.ops.count == 100, "post-compaction inserts remain in the log")
  }

  // MARK: - Empty value on upsert

  /// `Operation.upsert` with `value: nil` (or empty string) is a valid sequence we want to
  /// faithfully round-trip, because production placement records can carry nil filenames
  /// for in-progress variants. Lock in: the value flows through encode → decode → apply
  /// without alteration.
  @Test func upsertWithNilValueRoundTrips() throws {
    let (dir, file, _) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let replica = Replica()

    let ops = [
      Operation(kind: .upsert, key: "a", value: nil),
      Operation(kind: .upsert, key: "b", value: ""),
      Operation(kind: .upsert, key: "c", value: "non-empty"),
    ]
    driveAndVerify(file: file, replica: replica, ops: ops)
  }

  // MARK: - Fresh instance after restart preserves the mutation-count budget

  /// Production semantics: each `configure(for:)` call on the composing store
  /// instantiates a fresh `JSONLRecordFile` pointing at the on-disk paths. The fresh
  /// instance's mutation counter starts at 0 — the (n-1) lines already on disk do not
  /// count against the next compaction threshold. Without this, an app that always
  /// quits at exactly (n-1) mutations would compact on every launch's very first
  /// append, churning IO unnecessarily.
  ///
  /// This test simulates the restart by constructing a second `JSONLRecordFile` against
  /// the same URLs and verifying the next append doesn't trigger compaction.
  @Test func freshInstanceAfterRestartDoesNotInheritOldCounter() throws {
    let (dir, file, queue) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let replica = Replica()

    let n = JSONLRecordFile<Snapshot, Operation>.Constants.compactEveryNMutations
    // Drive (n - 1) ops on the first instance — one shy of the threshold.
    for i in 0..<(n - 1) {
      let op = Operation(kind: .upsert, key: "k\(i)", value: "v")
      replica.apply(op)
      let captured = replica.snapshot
      file.append(op, currentSnapshot: { captured })
    }
    file.drainSynchronously()

    // Simulate a "restart": construct a fresh instance against the same URLs.
    let snapshotURL = dir.appendingPathComponent("snapshot.json")
    let logURL = dir.appendingPathComponent("log.jsonl")
    let secondInstance = JSONLRecordFile<Snapshot, Operation>(
      snapshotURL: snapshotURL, logURL: logURL, ioQueue: queue,
      logger: Logger(subsystem: TestLogging.subsystem, category: "JSONLRecordFile-rt-2")
    )
    let loaded = secondInstance.load()
    #expect(loaded.snapshot == nil)
    #expect(loaded.ops.count == n - 1)

    // First append on the fresh instance must NOT compact — its counter starts at 0,
    // not at (n-1).
    let firstAfterRestart = Operation(kind: .upsert, key: "post-0", value: "v")
    replica.apply(firstAfterRestart)
    let captured = replica.snapshot
    secondInstance.append(firstAfterRestart, currentSnapshot: { captured })
    secondInstance.drainSynchronously()

    let loadedAgain = secondInstance.load()
    #expect(loadedAgain.snapshot == nil, "first append after restart must not trigger compaction")
    #expect(loadedAgain.ops.count == n, "the new op landed in the log alongside the prior n-1")
  }

  // MARK: - resetToEmpty preserves recovery contract

  /// `resetToEmpty(emptySnapshot:)` writes a fresh empty snapshot and truncates the log.
  /// Subsequent reload returns the empty snapshot and zero ops. Used by the corruption-
  /// recovery flow.
  @Test func resetToEmptyProducesCleanReloadable() throws {
    let (dir, file, _) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let replica = Replica()

    // Plant some data.
    for i in 0..<10 {
      let op = Operation(kind: .upsert, key: "k\(i)", value: "v\(i)")
      replica.apply(op)
      let captured = replica.snapshot
      file.append(op, currentSnapshot: { captured })
    }
    file.drainSynchronously()

    // Plant a fake "broken" snapshot so resetToEmpty has something to rename aside.
    try Data("garbage".utf8).write(to: dir.appendingPathComponent("snapshot.json"))

    try file.resetToEmpty(emptySnapshot: Snapshot(records: [:]))

    let loaded = file.load()
    #expect(loaded.snapshot == Snapshot(records: [:]))
    #expect(loaded.ops.isEmpty)
    #expect(loaded.snapshotStatus == .loaded)

    // The broken file is preserved alongside. The rename uses
    // `deletingPathExtension().appendingPathExtension("broken-<ts>")`, so
    // `snapshot.json` becomes `snapshot.broken-<ISO8601>` (note: the `.json` extension
    // is replaced, not appended-after).
    let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(
      entries.contains(where: { $0.hasPrefix("snapshot.broken-") }),
      "broken snapshot must be renamed aside, not deleted")
  }

  // MARK: - Order preservation under heavy interleaving

  /// Random-but-deterministic sequence of inserts, updates, deletes, and re-inserts on a
  /// 30-key universe. Drives 500 ops (well below threshold). After reload, every key's
  /// final value matches the replica. Locks in: ops are replayed in their original order
  /// (FIFO), which is essential for correctness when an upsert and a later delete touch
  /// the same key.
  @Test func interleavedSequencePreservesOrder() throws {
    let (dir, file, _) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let replica = Replica()

    var rng = SeededRNG(seed: 42)
    var ops: [Operation] = []
    for i in 0..<500 {
      let key = "k\(rng.next() % 30)"
      let action = rng.next() % 5
      let op: Operation
      switch action {
      case 0:
        op = Operation(kind: .delete, key: key, value: nil)
      default:
        op = Operation(kind: .upsert, key: key, value: "v-\(i)")
      }
      ops.append(op)
    }
    driveAndVerify(file: file, replica: replica, ops: ops)
  }
}

/// Tiny deterministic RNG so the interleaved test produces the same sequence on every
/// run regardless of the platform's `random` implementation.
private struct SeededRNG {
  private var state: UInt64
  init(seed: UInt64) { self.state = seed }
  mutating func next() -> Int {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Int(truncatingIfNeeded: state >> 33)
  }
}
