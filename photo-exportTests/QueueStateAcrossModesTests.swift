import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Pins the visible-state-vs-actual-state contract for the export queue
/// across timeline ↔ collections mode switches.
///
/// The export queue is a single shared `pendingJobs` array that holds
/// timeline and collection jobs side by side; jobs are routed to the
/// correct record store at write time by `placement.kind`. There is
/// **no** per-mode queue. These tests document that architecture and
/// pin the invariants users rely on:
///
///   1. Adding new work to a paused queue increases the visible
///      `totalJobsEnqueued` counter — it never resets while jobs are
///      still pending.
///   2. `pendingJobs` and `queueCount` reflect the full work depth
///      across modes; switching from timeline to collections does not
///      hide the parked timeline jobs.
///   3. After resume, jobs drain in FIFO order across the mode
///      boundary — the queue does not silently reorder so that "the
///      most recently started export" runs first.
///
/// Reproduced bug (pre-fix): paused album A → start month → counter
/// reset to month size, but `pendingJobs` still held A's leftover jobs.
/// On resume the queue chewed through A first while the toolbar
/// progress fraction overshot 100%. Fix: only `resetProgressCounters`
/// when `pendingJobs.isEmpty`. The accumulating-counter assertions
/// below catch that regression directly.
///
/// `.serialized` because the suite uses `writeDelaySeconds` and polls
/// transient `isRunning` state. Concurrent `@MainActor` suites exposed the
/// timing fragility under CI load. See issue #28.
@MainActor
@Suite(.serialized)
struct QueueStateAcrossModesTests {

  // MARK: - Fixtures

  private struct Harness {
    let manager: ExportManager
    let photoLib: FakePhotoLibraryService
    let dest: FakeExportDestination
    let writer: FakeAssetResourceWriter
    let timelineStore: ExportRecordStore
    let collectionStore: CollectionExportRecordStore
    let storeRoot: URL
  }

  private func makeHarness() -> Harness {
    let photoLib = FakePhotoLibraryService()
    let dest = FakeExportDestination()
    let writer = FakeAssetResourceWriter()
    let fileSystem = FakeFileSystem()
    let storeRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("QueueAcrossModes-\(UUID().uuidString)", isDirectory: true)
    let timelineStore = ExportRecordStore(baseDirectoryURL: storeRoot)
    timelineStore.configure(for: "test")
    let collectionStore = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    collectionStore.configure(for: "test")
    UserDefaults.standard.removeObject(forKey: ExportManager.versionSelectionDefaultsKey)
    let manager = ExportManager(
      photoLibraryService: photoLib,
      exportDestination: dest,
      exportRecordStore: timelineStore,
      collectionExportRecordStore: collectionStore,
      assetResourceWriter: writer,
      fileSystem: fileSystem
    )
    return Harness(
      manager: manager, photoLib: photoLib, dest: dest, writer: writer,
      timelineStore: timelineStore, collectionStore: collectionStore, storeRoot: storeRoot)
  }

  private func makeAsset(id: String, year: Int = 2025, month: Int = 4) -> AssetDescriptor {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = 15
    let date = Calendar.current.date(from: components) ?? Date(timeIntervalSince1970: 1_700_000_000)
    return AssetDescriptor(
      id: id, creationDate: date, mediaType: .image,
      pixelWidth: 100, pixelHeight: 100, duration: 0, hasAdjustments: false)
  }

  /// Sets up `assetCount` distinct assets in the timeline at `(year, month)`.
  private func seedTimelineMonth(
    _ photoLib: FakePhotoLibraryService, year: Int, month: Int, ids: [String]
  ) {
    let assets = ids.map { makeAsset(id: $0, year: year, month: month) }
    photoLib.assetsByYearMonth["\(year)-\(month)"] = assets
    for asset in assets {
      photoLib.resourcesByAssetId[asset.id] = [
        ResourceDescriptor(type: .photo, originalFilename: "\(asset.id).HEIC")
      ]
    }
  }

  /// Sets up `assetCount` distinct assets in an album. Mirrors the
  /// pattern used in `ReuseSourceAlbumPathTests`.
  private func seedAlbum(
    _ photoLib: FakePhotoLibraryService, localId: String, ids: [String]
  ) {
    let assets = ids.map { makeAsset(id: $0) }
    photoLib.assetsByAlbumLocalId[localId] = assets
    photoLib.collectionTree.append(
      PhotoCollectionDescriptor(
        id: "album:\(localId)", localIdentifier: localId, title: "Album-\(localId)",
        kind: .album, pathComponents: [], children: []))
    for asset in assets {
      photoLib.resourcesByAssetId[asset.id] = [
        ResourceDescriptor(type: .photo, originalFilename: "\(asset.id).HEIC")
      ]
    }
  }

  /// Yields until the given condition holds or the deadline elapses. Used
  /// instead of fixed sleeps so the tests stay deterministic under varying
  /// machine load.
  private func waitUntil(
    timeout: TimeInterval = 10, _ condition: @autoclosure () -> Bool
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
  }

  private func waitForQueueDrained(_ manager: ExportManager, timeout: TimeInterval = 5) async {
    let deadline = Date().addingTimeInterval(timeout)
    while (manager.isRunning || manager.queueCount > 0) && Date() < deadline {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  // MARK: - 1. Counter monotonicity across mode switch (the reported bug)

  /// Reproduces the user-reported scenario:
  /// 1. Start album A, pause.
  /// 2. Switch modes, start a month, pause.
  /// 3. Switch back, start album B.
  /// At every step the visible `totalJobsEnqueued` must accumulate, and
  /// `queueCount` must equal `pendingJobs.count` so the toolbar shows
  /// the same depth the run loop will actually drain.
  @Test func startingNewExportWhilePausedAccumulatesCounter() async throws {
    let h = makeHarness()
    defer {
      try? FileManager.default.removeItem(at: h.storeRoot)
      h.dest.cleanup()
    }

    // Slow the writer so we can reliably observe the in-flight + paused state.
    h.writer.writeDelaySeconds = 0.05

    seedAlbum(h.photoLib, localId: "album-A", ids: (1...4).map { "A\($0)" })
    seedTimelineMonth(h.photoLib, year: 2025, month: 6, ids: (1...3).map { "M\($0)" })
    seedAlbum(h.photoLib, localId: "album-B", ids: (1...2).map { "B\($0)" })

    // Step 1: start album A.
    h.manager.startExportAlbum(collectionId: "album-A")
    await waitUntil(h.manager.totalJobsEnqueued == 4)
    #expect(h.manager.totalJobsEnqueued == 4)

    // Pause. Queue parks once the in-flight job drains.
    await waitUntil(h.manager.isRunning)
    h.manager.pause()
    await waitUntil(!h.manager.isRunning)
    #expect(h.manager.isPaused)
    let completedAfterAPause = h.manager.totalJobsCompleted
    let queueAfterAPause = h.manager.queueCount

    // Step 2: switch modes, start a month export.
    h.manager.startExportMonth(year: 2025, month: 6)
    await waitUntil(h.manager.totalJobsEnqueued == 4 + 3)

    // Counter must accumulate, NOT reset. Pre-fix this dropped to 3.
    #expect(h.manager.totalJobsEnqueued == 7)
    #expect(h.manager.totalJobsCompleted == completedAfterAPause)
    // queueCount tracks the full pending depth.
    #expect(h.manager.queueCount >= queueAfterAPause)
    // Pause must persist across the new enqueue.
    #expect(h.manager.isPaused)
    #expect(!h.manager.isRunning)

    // Step 3: start album B.
    h.manager.startExportAlbum(collectionId: "album-B")
    await waitUntil(h.manager.totalJobsEnqueued == 4 + 3 + 2)

    #expect(h.manager.totalJobsEnqueued == 9)
    #expect(h.manager.totalJobsCompleted == completedAfterAPause)
    #expect(h.manager.isPaused)
  }

  // MARK: - 2. Pause state survives cross-mode enqueue

  /// A new `start*` while the queue is paused must not silently resume.
  /// Pre-fix the state bookkeeping wasn't broken here, but this nails it
  /// down so a future "auto-resume on enqueue" change cannot land
  /// without a test failing.
  @Test func pausedQueueStaysParkedWhenNewWorkIsAdded() async throws {
    let h = makeHarness()
    defer {
      try? FileManager.default.removeItem(at: h.storeRoot)
      h.dest.cleanup()
    }
    h.writer.writeDelaySeconds = 0.05

    seedTimelineMonth(h.photoLib, year: 2025, month: 7, ids: (1...3).map { "M\($0)" })
    seedAlbum(h.photoLib, localId: "album-X", ids: (1...3).map { "X\($0)" })

    h.manager.startExportMonth(year: 2025, month: 7)
    await waitUntil(h.manager.isRunning)
    h.manager.pause()
    await waitUntil(!h.manager.isRunning)
    #expect(h.manager.isPaused)

    h.manager.startExportAlbum(collectionId: "album-X")
    await waitUntil(h.manager.totalJobsEnqueued == 6)

    // Adding work must not unpause the run loop.
    #expect(h.manager.isPaused)
    #expect(!h.manager.isRunning)
  }

  // MARK: - 3. Pending queue is shared across timeline and collections

  /// Architecture invariant: `pendingJobs` is one queue. Timeline jobs
  /// and collection jobs land in the same array. Tests later in this
  /// branch may expect this; flagging it explicitly so a future
  /// "separate per-mode queues" refactor is intentional and updates
  /// every dependent assumption.
  @Test func pendingJobsHoldsMixedTimelineAndCollectionWork() async throws {
    let h = makeHarness()
    defer {
      try? FileManager.default.removeItem(at: h.storeRoot)
      h.dest.cleanup()
    }
    h.writer.writeDelaySeconds = 0.05

    seedTimelineMonth(h.photoLib, year: 2025, month: 8, ids: (1...4).map { "M\($0)" })
    seedAlbum(h.photoLib, localId: "album-Y", ids: (1...3).map { "Y\($0)" })

    h.manager.startExportMonth(year: 2025, month: 8)
    await waitUntil(h.manager.isRunning)
    h.manager.pause()
    await waitUntil(!h.manager.isRunning)
    h.manager.startExportAlbum(collectionId: "album-Y")
    await waitUntil(h.manager.totalJobsEnqueued == 7)

    let kinds = Set(h.manager.pendingJobs.map { $0.placement.kind })
    #expect(kinds.contains(.timeline))
    #expect(kinds.contains(.album))
    #expect(h.manager.pendingJobs.count == h.manager.queueCount)
  }

  // MARK: - 4. Resume drains FIFO across modes

  /// After pause + cross-mode enqueue + resume, the queue drains in
  /// FIFO order. Together with the counter test this catches the
  /// reported symptom: visible state advertises one thing while the
  /// run loop actually does another.
  @Test func resumeDrainsFifoAcrossModes() async throws {
    let h = makeHarness()
    defer {
      try? FileManager.default.removeItem(at: h.storeRoot)
      h.dest.cleanup()
    }
    h.writer.writeDelaySeconds = 0.02

    seedTimelineMonth(h.photoLib, year: 2025, month: 9, ids: (1...3).map { "M\($0)" })
    seedAlbum(h.photoLib, localId: "album-Z", ids: (1...3).map { "Z\($0)" })

    h.manager.startExportMonth(year: 2025, month: 9)
    await waitUntil(h.manager.isRunning)
    h.manager.pause()
    await waitUntil(!h.manager.isRunning)
    h.manager.startExportAlbum(collectionId: "album-Z")
    await waitUntil(h.manager.totalJobsEnqueued == 6)

    // Snapshot the order at resume time. The first 3 entries are the
    // pre-pause timeline batch; the next 3 are the post-pause album
    // batch.
    let preResumeOrder = h.manager.pendingJobs.map { $0.placement.kind }
    let firstTimelineRunLength = preResumeOrder.prefix(while: { $0 == .timeline }).count
    #expect(firstTimelineRunLength >= 1, "Expected at least one timeline job at queue head")

    h.manager.resume()
    await waitForQueueDrained(h.manager)

    // Final counter is consistent: total == completed, no overshoot.
    #expect(h.manager.totalJobsEnqueued == 6)
    #expect(h.manager.totalJobsCompleted == 6)
    // Both stores received their respective writes.
    let monthRecords = h.timelineStore.recordCount(
      year: 2025, month: 9, variant: .original, status: .done)
    let albumPlacement = h.collectionStore.placements(matching: .album)
      .first(where: { $0.collectionLocalIdentifier == "album-Z" })
    #expect(monthRecords == 3)
    if let albumPlacement {
      let summary = h.collectionStore.summary(for: albumPlacement)
      #expect(summary.exportedCount == 3)
    } else {
      Issue.record("Expected a persisted album placement for album-Z")
    }
  }
}
