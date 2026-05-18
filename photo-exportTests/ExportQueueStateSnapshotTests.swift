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
    let userDefaultsSuite: String

    func cleanup() {
      manager.cancelAndClear()
      store.flushForTesting()
      try? FileManager.default.removeItem(at: storeRoot)
      dest.cleanup()
      UserDefaults().removePersistentDomain(forName: userDefaultsSuite)
    }
  }

  private func makeHarness() -> Harness {
    let photoLib = FakePhotoLibraryService()
    let dest = FakeExportDestination()
    let writer = FakeAssetResourceWriter()
    let fileSystem = FakeFileSystem()
    let storeRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("ExportQueueSnapshot-\(UUID().uuidString)", isDirectory: true)
    let store = ExportRecordStore(baseDirectoryURL: storeRoot)
    store.configure(for: "test")
    let suiteName = "test-ExportQueueSnapshot-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let manager = ExportManager(
      photoLibraryService: photoLib,
      exportDestination: dest,
      exportRecordStore: store,
      assetResourceWriter: writer,
      fileSystem: fileSystem,
      userDefaults: defaults
    )
    return Harness(
      manager: manager, photoLib: photoLib, dest: dest, writer: writer,
      store: store, storeRoot: storeRoot, userDefaultsSuite: suiteName)
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

  private func waitUntil(
    timeout: TimeInterval = 3, _ condition: () -> Bool
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
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
      Snapshot(isRunning: true,  isPaused: false, hasPendingJobs: true),   // running
      Snapshot(isRunning: true,  isPaused: true,  hasPendingJobs: true),   // pause set mid-run
      Snapshot(isRunning: false, isPaused: true,  hasPendingJobs: true),   // parked
      Snapshot(isRunning: true,  isPaused: false, hasPendingJobs: true),   // resumed
      Snapshot(isRunning: false, isPaused: true,  hasPendingJobs: true),   // parked again
      Snapshot(isRunning: false, isPaused: false, hasPendingJobs: false),  // cancelled idle
    ]

    #expect(canonical == expected, """
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
    h.photoLib.assetsByYearMonth["2025-7"] = [asset]
    h.photoLib.resourcesByAssetId[asset.id] = [
      TestAssetFactory.makeResource(originalFilename: "X.JPG")
    ]
    let gate = AsyncCheckpoint()
    h.writer.checkpoint = gate

    h.manager.startExportMonth(year: 2025, month: 7)
    await gate.waitForEnter(count: 1)
    #expect(h.manager.isRunning, "precondition: coordinator should have flipped isRunning")

    // The contract: teardownQueue() mutates the coordinator's @Published synchronously,
    // sinks fire synchronously, manager mirrors are updated before this call returns.
    h.manager.queueCoordinator.teardownQueue()
    #expect(!h.manager.isRunning,
      "manager.isRunning must reflect coordinator state synchronously after teardownQueue")
    #expect(!h.manager.isPaused)
    #expect(h.manager.queueCount == 0)

    await gate.releaseAll()
  }
}
