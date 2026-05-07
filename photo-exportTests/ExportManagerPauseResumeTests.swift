import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Closes a P0 coverage gap: existing pause tests
/// (`testPauseAndResumeToggle` in `ExportManagerHelperTests.swift` and
/// `pauseAndResumeBehavior` in `ExportPipelineTests.swift`) only verify the
/// "pause when not running is a no-op" branch and the end-state after a full
/// drain. The actual **pause-during-active-run** flow — where `processNext()`
/// reads `isPaused`, exits the run loop, sets `isProcessing/isRunning = false`,
/// and `resume()` later restarts the queue via `processQueueIfNeeded()` — is
/// never exercised end-to-end. A regression in any of those guards (e.g.
/// flipping the order of `isProcessing = false` and the early return, or
/// dropping `processQueueIfNeeded()` from `resume`) would either deadlock the
/// queue or run jobs through pause; no current test would notice.
///
/// Approach: enqueue 3 assets, slow the writer via `writeDelaySeconds`, call
/// `pause()` after the first asset's write starts, wait for the in-flight job
/// to finish, then assert the queue parked correctly. Resume and verify the
/// remaining work drains.
@MainActor
struct ExportManagerPauseResumeTests {

  // MARK: - Fixtures

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

  private func makeTestHarness() -> Harness {
    let photoLib = FakePhotoLibraryService()
    let dest = FakeExportDestination()
    let writer = FakeAssetResourceWriter()
    let fileSystem = FakeFileSystem()
    let storeRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("ExportManagerPause-\(UUID().uuidString)", isDirectory: true)
    let store = ExportRecordStore(baseDirectoryURL: storeRoot)
    store.configure(for: "test")
    let suiteName = "test-ExportManagerPause-\(UUID().uuidString)"
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

  /// Polls until `condition` returns true or the timeout elapses. Used for parking
  /// against intermediate states the queue passes through (e.g. "pause has taken
  /// effect") without sleeping a fixed duration.
  private func waitUntil(
    timeout: TimeInterval = 3, _ condition: () -> Bool
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  // MARK: - Pause mid-run, then resume

  @Test func pauseDuringActiveRunStopsQueueAndResumeRestarts() async throws {
    let h = makeTestHarness()
    defer { h.cleanup() }

    let assets = (1...3).map {
      TestAssetFactory.makeAsset(id: "pause-\($0)")
    }
    h.photoLib.assetsByYearMonth["2025-7"] = assets
    for asset in assets {
      h.photoLib.resourcesByAssetId[asset.id] = [
        TestAssetFactory.makeResource(originalFilename: "\(asset.id).JPG")
      ]
    }

    // Gate writes so we can step through the queue deterministically — the
    // first write is suspended on the gate, we pause, release just one ticket
    // so the in-flight job completes, and processNext exits on the pause guard.
    let writeGate = AsyncCheckpoint()
    h.writer.checkpoint = writeGate

    h.manager.startExportMonth(year: 2025, month: 7)

    // Wait until the first writer is suspended on the gate.
    await writeGate.waitForEnter(count: 1)
    #expect(h.manager.isRunning)
    #expect(h.manager.queueCount > 0)

    // Pause, then release exactly one ticket so the in-flight job completes
    // and processNext sees isPaused on its next iteration.
    h.manager.pause()
    #expect(h.manager.isPaused)
    await writeGate.release(1)

    // Queue parked: run loop has exited but jobs remain. (`hasActiveExportWork`
    // is intentionally NOT in this predicate — it's `isRunning || queueCount > 0
    // || isEnqueueingAll`, so it's still true here, and that's correct.)
    await waitUntil {
      !h.manager.isRunning && h.manager.queueCount > 0
    }
    #expect(h.manager.isPaused, "isPaused must persist while queue is parked")
    #expect(!h.manager.isRunning, "run loop must exit on the pause guard")
    #expect(h.manager.queueCount > 0, "remaining jobs must stay in pendingJobs")
    #expect(
      h.manager.totalJobsCompleted == 1,
      "exactly the released first asset must have completed before pause took effect"
    )

    // Open the gate fully and resume. Remaining work drains.
    await writeGate.releaseAll()
    h.manager.resume()
    #expect(!h.manager.isPaused)
    await h.manager.waitForQueueDrained()
    #expect(h.manager.totalJobsCompleted == 3)
    #expect(h.manager.queueCount == 0)
    #expect(!h.manager.isRunning)
  }

  /// Calling `pause()` after the queue has already drained is a no-op (no `isRunning`
  /// to pause). The mirror to `testPauseAndResumeToggle` which covers the "pause
  /// before start" no-op.
  @Test func pauseAfterQueueDrainsIsNoOp() async throws {
    let h = makeTestHarness()
    defer { h.cleanup() }

    let asset = TestAssetFactory.makeAsset(id: "single")
    h.photoLib.assetsByYearMonth["2025-1"] = [asset]
    h.photoLib.resourcesByAssetId[asset.id] = [
      TestAssetFactory.makeResource(originalFilename: "S.JPG")
    ]

    h.manager.startExportMonth(year: 2025, month: 1)
    await h.manager.waitForQueueDrained()
    #expect(h.manager.totalJobsCompleted == 1)

    h.manager.pause()
    #expect(!h.manager.isPaused, "pause after drain must not flip the flag")
  }
}
