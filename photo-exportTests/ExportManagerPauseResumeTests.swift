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
///
/// `.serialized` because the suite uses `writeDelaySeconds` and polls transient
/// `isRunning` state — running concurrently with other `@MainActor` suites
/// starves the main-actor scheduler under CI load. See issue #28.
@MainActor
@Suite(.serialized)
struct ExportManagerPauseResumeTests {

  // MARK: - Fixtures

  private func makeTestHarness() -> (
    ExportManager, FakePhotoLibraryService, FakeExportDestination, FakeAssetResourceWriter,
    FakeFileSystem, ExportRecordStore
  ) {
    let photoLib = FakePhotoLibraryService()
    let dest = FakeExportDestination()
    let writer = FakeAssetResourceWriter()
    let fileSystem = FakeFileSystem()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ExportManagerPause-\(UUID().uuidString)", isDirectory: true)
    let store = ExportRecordStore(baseDirectoryURL: tempDir)
    store.configure(for: "test")
    UserDefaults.standard.removeObject(forKey: ExportManager.versionSelectionDefaultsKey)
    let manager = ExportManager(
      photoLibraryService: photoLib,
      exportDestination: dest,
      exportRecordStore: store,
      assetResourceWriter: writer,
      fileSystem: fileSystem
    )
    return (manager, photoLib, dest, writer, fileSystem, store)
  }

  private func waitForQueueDrained(_ manager: ExportManager, timeout: TimeInterval = 5)
    async
  {
    let deadline = Date().addingTimeInterval(timeout)
    await Task.yield()
    try? await Task.sleep(nanoseconds: 50_000_000)
    while (manager.isRunning || manager.queueCount > 0 || manager.hasActiveExportWork)
      && Date() < deadline
    {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
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
    let (manager, photoLib, dest, writer, _, _) = makeTestHarness()
    defer { dest.cleanup() }

    let assets = (1...3).map {
      TestAssetFactory.makeAsset(id: "pause-\($0)")
    }
    photoLib.assetsByYearMonth["2025-7"] = assets
    for asset in assets {
      photoLib.resourcesByAssetId[asset.id] = [
        TestAssetFactory.makeResource(originalFilename: "\(asset.id).JPG")
      ]
    }

    // Slow each variant write to ~300 ms so we can pause between assets.
    writer.writeDelaySeconds = 0.3

    manager.startExportMonth(year: 2025, month: 7)

    // Wait until the run loop is actually running (the first job is in flight).
    await waitUntil { manager.isRunning && manager.queueCount > 0 }
    #expect(manager.isRunning)
    #expect(manager.queueCount > 0)

    // Pause while the first variant is mid-write. processNext won't exit until the
    // current job's writer call completes; the next processNext call will see
    // isPaused and bail.
    manager.pause()
    #expect(manager.isPaused)

    // Wait for the queue to park: the in-flight job finishes, processNext's pause
    // guard fires, isProcessing/isRunning go false, but isPaused stays true and
    // pendingJobs is non-empty.
    await waitUntil(timeout: 5) {
      !manager.isRunning && !manager.hasActiveExportWork && manager.queueCount > 0
    }
    #expect(manager.isPaused, "isPaused must persist while queue is parked")
    #expect(!manager.isRunning, "run loop must exit on the pause guard")
    #expect(manager.queueCount > 0, "remaining jobs must stay in pendingJobs")
    #expect(manager.totalJobsCompleted >= 1, "at least the first asset must have completed")
    #expect(
      manager.totalJobsCompleted < 3,
      "at least one asset must still be queued — the test would prove nothing if all three completed before pause took effect"
    )

    let completedAfterPause = manager.totalJobsCompleted

    // Now resume — processQueueIfNeeded() should drive the remaining work to
    // completion. Speed up the writer so the rest finishes within the test budget.
    writer.writeDelaySeconds = 0
    manager.resume()
    #expect(!manager.isPaused)
    await waitForQueueDrained(manager)
    #expect(manager.totalJobsCompleted == 3)
    #expect(manager.totalJobsCompleted > completedAfterPause)
    #expect(manager.queueCount == 0)
    #expect(!manager.isRunning)
  }

  /// Calling `pause()` after the queue has already drained is a no-op (no `isRunning`
  /// to pause). The mirror to `testPauseAndResumeToggle` which covers the "pause
  /// before start" no-op.
  @Test func pauseAfterQueueDrainsIsNoOp() async throws {
    let (manager, photoLib, dest, _, _, _) = makeTestHarness()
    defer { dest.cleanup() }

    let asset = TestAssetFactory.makeAsset(id: "single")
    photoLib.assetsByYearMonth["2025-1"] = [asset]
    photoLib.resourcesByAssetId[asset.id] = [
      TestAssetFactory.makeResource(originalFilename: "S.JPG")
    ]

    manager.startExportMonth(year: 2025, month: 1)
    await waitForQueueDrained(manager)
    #expect(manager.totalJobsCompleted == 1)

    manager.pause()
    #expect(!manager.isPaused, "pause after drain must not flip the flag")
  }
}
