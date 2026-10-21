import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Phase 4b prep regression-gate test. Records the queue-state tuple
/// `(isRunning, isPaused, queueCount, hasCurrentTask)` at each transition during a
/// multi-job run with `pause` → `resume` → `cancel`. The Phase 4b extraction moves
/// `pendingJobs`, `isProcessing`, `isPaused`, `queueCount`, and the drain loop into
/// `ExportQueueCoordinator`; the manager's published mirrors must keep emitting the
/// same canonical sequence so UI bindings and the AutoSync seam don't drift.
///
/// The existing pause-resume tests assert on outcomes (counters, drain completion).
/// This one asserts on the state-machine *transitions* — the shape AutoSync's
/// `exportRunStatePublisher` indirectly observes via `$isRunning` + `$queueCount`.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct ExportQueueStateSnapshotTests {

  // MARK: - Harness (mirrors ExportManagerPauseResumeTests)

  @MainActor
  private struct Harness {
    let manager: ExportManager
    let photoLib: FakePhotoLibraryService
    let dest: FakeExportDestination
    let writer: FakeAssetResourceWriter
    let store: ExportRecordStore
    let storeRoot: URL

    func cleanup() {
      manager.cancelAndClear()
      store.flushForTesting()
      try? FileManager.default.removeItem(at: storeRoot)
      dest.cleanup()
    }
  }

  private func makeHarness() -> Harness {
    let photoLib = FakePhotoLibraryService()
    let dest = FakeExportDestination()
    let writer = FakeAssetResourceWriter()
    let fileSystem = FakeFileSystem()
    let storeRoot = TestScratch.directory("ExportQueueSnapshot")
    let store = ExportRecordStore(baseDirectoryURL: storeRoot)
    store.configure(for: "test")
    let collections = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    collections.configure(for: "test")
    let defaults = TestScratch.defaults("ExportQueueSnapshot")
    let manager = ExportManager(
      photoLibraryService: photoLib,
      exportDestination: dest,
      exportRecordStore: store,
      collectionExportRecordStore: collections,
      assetResourceWriter: writer,
      fileSystem: fileSystem,
      userDefaults: defaults
    )
    return Harness(
      manager: manager, photoLib: photoLib, dest: dest, writer: writer,
      store: store, storeRoot: storeRoot)
  }

  /// Canonical queue-state at a single instant. The Phase 4b extraction must preserve
  /// the sequence of these tuples observed at the same transition points.
  private struct Snapshot: Equatable, CustomStringConvertible {
    let isRunning: Bool
    let isPaused: Bool
    let hasPendingJobs: Bool
    var description: String {
      "Snap(running:\(isRunning) paused:\(isPaused) pending:\(hasPendingJobs))"
    }
  }

  private func snapshot(_ manager: ExportManager) -> Snapshot {
    Snapshot(
      isRunning: manager.isRunning,
      isPaused: manager.isPaused,
      hasPendingJobs: manager.queueCount > 0)
  }

  /// Drops adjacent duplicates from a snapshot list — same canonicalization shape as the
  /// AutoSync seam regression gate.
  private func canonicalize(_ snaps: [Snapshot]) -> [Snapshot] {
    var result: [Snapshot] = []
    for snap in snaps where result.last != snap {
      result.append(snap)
    }
    return result
  }

  /// Re-checks until `condition` holds; the suite's time limit is the backstop. Deliberately
  /// not a `#require`, so a stalled park still reaches the canonical-sequence diff below.
  private func waitUntil(
    _ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation
  ) async {
    _ = await eventually("waitUntil condition", sourceLocation: sourceLocation) { condition() }
  }

  // MARK: - Test

  /// Three-asset run with: gate-suspended start → pause mid-run → resume one ticket →
  /// pause again → cancel. The canonical transition sequence must end identically
  /// after the Phase 4b extraction.
  @Test func pauseResumeCancelStateSnapshot_canonicalTransitions() async throws {
    let h = makeHarness()
    defer { h.cleanup() }

    let assets = (1...3).map { TestAssetFactory.makeAsset(id: "snap-\($0)") }
    h.photoLib.assetsByYearMonth["2025-7"] = assets
    for a in assets {
      h.photoLib.resourcesByAssetId[a.id] = [
        TestAssetFactory.makeResource(originalFilename: "\(a.id).JPG")
      ]
    }

    let writeGate = AsyncCheckpoint()
    h.writer.checkpoint = writeGate

    var snaps: [Snapshot] = []
    snaps.append(snapshot(h.manager))  // initial: idle

    h.manager.startExportMonth(year: 2025, month: 7)
    await writeGate.waitForEnter(count: 1)
    snaps.append(snapshot(h.manager))  // running, not paused, has pending

    // Pause mid-run; release one ticket so the in-flight job completes; observe park.
    h.manager.pause()
    snaps.append(snapshot(h.manager))  // paused, still running until processNext exits
    await writeGate.release(1)
    await waitUntil { !h.manager.isRunning && h.manager.queueCount > 0 }
    snaps.append(snapshot(h.manager))  // parked: paused, not running, pending > 0

    // Resume; release another ticket; observe park again.
    h.manager.resume()
    await writeGate.waitForEnter(count: 2)
    snaps.append(snapshot(h.manager))  // running again, not paused, has pending
    h.manager.pause()
    await writeGate.release(1)
    await waitUntil { !h.manager.isRunning && h.manager.queueCount > 0 }
    snaps.append(snapshot(h.manager))  // parked again

    // Cancel.
    h.manager.cancelAndClear()
    // Cancel clears pending and bumps generation; let the in-flight task observe it.
    await writeGate.releaseAll()
    await h.manager.waitForQueueDrained()
    snaps.append(snapshot(h.manager))  // terminal: idle

    let canonical = canonicalize(snaps)
    let expected: [Snapshot] = [
      Snapshot(isRunning: false, isPaused: false, hasPendingJobs: false),  // initial
      Snapshot(isRunning: true, isPaused: false, hasPendingJobs: true),  // running
      Snapshot(isRunning: true, isPaused: true, hasPendingJobs: true),  // pause set mid-run
      Snapshot(isRunning: false, isPaused: true, hasPendingJobs: true),  // parked
      Snapshot(isRunning: true, isPaused: false, hasPendingJobs: true),  // resumed
      Snapshot(isRunning: false, isPaused: true, hasPendingJobs: true),  // parked again
      Snapshot(isRunning: false, isPaused: false, hasPendingJobs: false),  // cancelled idle
    ]

    #expect(
      canonical == expected,
      """
      Phase 4b queue-state contract violation. Expected:
      \(expected.map(\.description).joined(separator: "\n      "))
      Got:
      \(canonical.map(\.description).joined(separator: "\n      "))
      """)
  }

  /// Sink-synchrony pin: the coordinator's `@Published` updates must reach the
  /// manager's mirrors in the same MainActor turn. `@Published` emits on `willSet`
  /// synchronously, so an immediate read (no `await` between) sees the new value.
  ///
  /// If a future Swift-concurrency change deferred sink delivery to the next runloop
  /// tick, AutoSync would see a transient `(running=true, queueCount>0)` state where
  /// today there's none — and the canonical-sequence test above would still pass.
  /// This test asserts synchronous propagation directly.
  @Test func teardownQueue_synchronouslyClearsManagerMirrors() async throws {
    let h = makeHarness()
    defer { h.cleanup() }

    // Force the coordinator into a running state cheaply by enqueueing one job and
    // gating its writer so the run loop is parked.
    let asset = TestAssetFactory.makeAsset(id: "sink-sync")
    let queued = TestAssetFactory.makeAsset(id: "sink-sync-queued")
    h.photoLib.assetsByYearMonth["2025-7"] = [asset, queued]
    h.photoLib.resourcesByAssetId[asset.id] = [
      TestAssetFactory.makeResource(originalFilename: "X.JPG")
    ]
    h.photoLib.resourcesByAssetId[queued.id] = [
      TestAssetFactory.makeResource(originalFilename: "Y.JPG")
    ]
    let gate = AsyncCheckpoint()
    h.writer.checkpoint = gate

    h.manager.startExportMonth(year: 2025, month: 7)
    await gate.waitForEnter(count: 1)
    // Pause too, so clearing every mirror is observable, not just already-false values.
    h.manager.pause()
    try #require(h.manager.isRunning, "precondition: coordinator should have flipped isRunning")
    try #require(h.manager.isPaused, "precondition: the queue should be paused")
    try #require(h.manager.pendingJobs.count == 1, "precondition: a second job should be queued")

    // The contract: teardownQueue() mutates the coordinator's @Published synchronously,
    // sinks fire synchronously, manager mirrors are updated before this call returns.
    h.manager.queueCoordinator.teardownQueue()
    #expect(
      !h.manager.isRunning,
      "manager.isRunning must reflect coordinator state synchronously after teardownQueue")
    #expect(!h.manager.isPaused)
    #expect(h.manager.queueCount == 0)

    await gate.releaseAll()
  }
}
