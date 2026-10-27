import Foundation
import Testing
import os

@testable import Photo_Export

/// `beginConfigure(for:)` reads a destination's history off the main actor behind `.loading`, and
/// the load's result is applied in one main-actor turn when it finishes. `HeldReadIO` holds the
/// snapshot read so each test can act while the load is still running.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct RecordStoreAsyncLoadTests {
  @MainActor
  private final class Fixture {
    let root = TestScratch.directory("RecordStoreAsyncLoad")
    let io = HeldReadIO()
    let timeline: ExportRecordStore
    let collections: CollectionExportRecordStore
    let router: RecordStoreRouter
    let placement: ExportPlacement
    let collection: Bool

    init(collection: Bool) {
      self.collection = collection
      timeline = ExportRecordStore(baseDirectoryURL: root, recordLogIO: io)
      collections = CollectionExportRecordStore(baseDirectoryURL: root, recordLogIO: io)
      router = RecordStoreRouter(timelineStore: timeline, collectionStore: collections)
      placement = collection ? .favorites() : .timeline(year: 2025, month: 6)
    }

    var state: RecordStoreState { collection ? collections.state : timeline.state }
    var destinationId: String? { collection ? collections.destinationId : timeline.destinationId }
    var finishedLoads: Int {
      collection ? collections.finishedLoadCount : timeline.finishedLoadCount
    }
    var waiters: Int {
      collection ? collections.pendingSettleWaiterCount : timeline.pendingSettleWaiterCount
    }
    var mutationCounter: Int {
      collection ? collections.mutationCounter : timeline.mutationCounter
    }

    func configure(_ id: String?) async {
      if collection {
        await collections.configureAndWait(for: id)
      } else {
        await timeline.configureAndWait(for: id)
      }
    }

    func begin(_ id: String?) {
      if collection {
        collections.beginConfigure(for: id)
      } else {
        timeline.beginConfigure(for: id)
      }
    }

    func settle() async {
      if collection {
        await collections.waitUntilSettled()
      } else {
        await timeline.waitUntilSettled()
      }
    }

    func flush() async throws {
      if collection { try await collections.flush() } else { try await timeline.flush() }
    }

    /// Writes `assets` (asset id → filename) into `destination`'s history and leaves the store
    /// configured for it.
    func seed(_ destination: String, _ assets: [String: String]) async throws {
      await configure(destination)
      for (assetId, filename) in assets.sorted(by: { $0.key < $1.key }) {
        mark(assetId, filename)
      }
      try await flush()
    }

    func mark(_ assetId: String, _ filename: String) {
      if collection {
        if collections.placement(id: placement.id) == nil { collections.upsertPlacement(placement) }
        collections.markVariantExported(
          assetId: assetId, placement: placement, variant: .original, filename: filename,
          exportedAt: Date())
      } else {
        timeline.markVariantExported(
          assetId: assetId, variant: .original, year: 2025, month: 6,
          relPath: placement.relativePath, filename: filename, exportedAt: Date())
      }
    }

    func capture() throws -> (String?) async -> Void {
      try router.captureFinalCommit(
        assetId: "asset", placement: placement, variant: .original,
        relPath: placement.relativePath, subfolder: nil, acceptsEditedFallback: false)
    }

    func filename(_ assetId: String = "asset") -> String? {
      router.variants(forAssetId: assetId, placement: placement)[.original]?.filename
    }

    /// What fresh stores read from `destination`'s files for `assetId`.
    func filenameOnDisk(_ destination: String, _ assetId: String = "asset") async -> String? {
      let timeline = ExportRecordStore(baseDirectoryURL: root)
      let collections = CollectionExportRecordStore(baseDirectoryURL: root)
      defer {
        timeline.drainSynchronously()
        collections.drainSynchronously()
      }
      await timeline.configureAndWait(for: destination)
      await collections.configureAndWait(for: destination)
      return RecordStoreRouter(timelineStore: timeline, collectionStore: collections)
        .variants(forAssetId: assetId, placement: placement)[.original]?.filename
    }

    func isClaimed(_ name: String) -> Bool {
      router.isFilenameClaimed(
        name, placement: placement, subfolder: nil, exceptVariant: .original, of: "someone-else")
    }

    func resetHistory() async {
      if collection { await collections.resetHistory() } else { await timeline.resetHistory() }
    }

    func retryHistoryPersistence() async {
      if collection {
        await collections.retryHistoryPersistence()
      } else {
        await timeline.retryHistoryPersistence()
      }
    }

    func url(_ destination: String, snapshot: Bool) -> URL {
      let name =
        switch (collection, snapshot) {
        case (true, true): CollectionExportRecordStore.Constants.snapshotFileName
        case (true, false): CollectionExportRecordStore.Constants.logFileName
        case (false, true): ExportRecordStore.Constants.snapshotFileName
        case (false, false): ExportRecordStore.Constants.logFileName
        }
      return root.appendingPathComponent(destination).appendingPathComponent(name)
    }

    /// Releases every held read before the stores' IO queues are drained.
    func cleanup() {
      io.releaseAll()
      timeline.drainSynchronously()
      collections.drainSynchronously()
      try? FileManager.default.removeItem(at: root)
    }
  }

  @MainActor
  private final class Ticks {
    var count = 0
  }

  private static let committed = "IMG_0001 (1).JPG"

  // MARK: - Off the main actor

  /// The read runs off the main actor: the store is `.loading` when `beginConfigure` returns,
  /// and the main actor keeps running while the read is held.
  @Test(arguments: [false, true])
  func loadRunsOffMainAndUIKeepsRunning(collection: Bool) async throws {
    let f = Fixture(collection: collection)
    defer { f.cleanup() }
    try await f.seed("A", ["a1": "A1.JPG"])
    await f.configure("B")
    f.io.hold(f.url("A", snapshot: true))
    let mainThreadReads = f.io.mainThreadReads.count

    f.begin("A")

    #expect(
      f.io.mainThreadReads.count == mainThreadReads, "the load read its files on the main thread")
    try #require(f.state == .loading, "the load finished before beginConfigure returned")
    #expect(f.destinationId == "A")
    #expect(f.filename("a1") == nil)
    try #require(await eventually("the snapshot read is held") { f.io.heldCount == 1 })
    let ticks = Ticks()
    let heartbeat = Task { @MainActor in
      for _ in 0..<5 {
        ticks.count += 1
        await Task.yield()
      }
    }
    #expect(await finished(heartbeat))
    #expect(ticks.count == 5)
    #expect(f.state == .loading && f.io.heldCount == 1)

    f.io.release(f.url("A", snapshot: true))
    await f.settle()
    #expect(f.state == .ready)
    #expect(f.filename("a1") == "A1.JPG")
    #expect(f.io.mainThreadReads.count == mainThreadReads)
  }

  // MARK: - Superseded loads

  /// A load overtaken by another configure is never published, even when it was for the same
  /// destination as the load that replaces it.
  @Test(arguments: [false, true])
  func supersededLoadIsDiscarded(collection: Bool) async throws {
    let f = Fixture(collection: collection)
    defer { f.cleanup() }
    try await f.seed("A", ["a1": "A1.JPG"])
    try await f.seed("B", ["b1": "B1.JPG"])
    await f.configure(nil)

    // A, then B, in one turn. A's read is not held, so it finishes first and is discarded.
    let start = f.finishedLoads
    f.io.hold(f.url("B", snapshot: true))
    f.begin("A")
    f.begin("B")
    try #require(f.state == .loading)
    #expect(await eventually("A's load finishes") { f.finishedLoads == start + 1 })
    #expect(f.state == .loading)
    #expect(f.destinationId == "B")
    #expect(f.filename("a1") == nil, "a superseded load published its records")
    f.io.release(f.url("B", snapshot: true))
    await f.settle()
    #expect(f.state == .ready)
    #expect(f.filename("b1") == "B1.JPG")
    #expect(f.filename("a1") == nil)
    #expect(f.finishedLoads == start + 2)

    // A, B, then A again: only the last load of A publishes.
    await f.configure(nil)
    let restart = f.finishedLoads
    let snapshotA = f.url("A", snapshot: true)
    f.io.hold(snapshotA, fromRead: f.io.readCount(of: snapshotA) + 2)
    f.begin("A")
    f.begin("B")
    f.begin("A")
    #expect(await eventually("the first two loads finish") { f.finishedLoads == restart + 2 })
    #expect(f.state == .loading)
    #expect(f.filename("a1") == nil, "the first load of A published its records")
    #expect(f.filename("b1") == nil)
    f.io.release(snapshotA)
    await f.settle()
    #expect(f.state == .ready)
    #expect(f.filename("a1") == "A1.JPG")
    #expect(f.finishedLoads == restart + 3)
  }

  enum SupersedingConfigure: CaseIterable, Sendable {
    case clearedAsync, clearedBlocking, otherDestinationBlocking, otherDestinationAsync,
      waiterCancelled
  }

  /// Every way out of `.loading` resumes the tasks waiting for it, and a cancelled waiter stops
  /// waiting.
  @Test(arguments: [false, true], SupersedingConfigure.allCases)
  func waitersResumeWhenLoadIsSupersededOrCleared(
    collection: Bool, configure: SupersedingConfigure
  ) async throws {
    let f = Fixture(collection: collection)
    defer { f.cleanup() }
    try await f.seed("A", ["a1": "A1.JPG"])
    try await f.seed("B", ["b1": "B1.JPG"])
    await f.configure(nil)
    let snapshotA = f.url("A", snapshot: true)
    f.io.hold(snapshotA)
    f.begin("A")
    try #require(f.state == .loading)
    let waiter = Task { @MainActor in
      await f.settle()
      return f.state
    }
    try #require(await eventually("the waiter is waiting") { f.waiters == 1 })

    // A held read blocks the IO queue a configure drains, so release it in the same turn: the
    // load's result can only arrive after this turn, when it is already superseded.
    switch configure {
    case .clearedAsync:
      f.io.release(snapshotA)
      f.begin(nil)
      #expect(f.waiters == 0)
    case .clearedBlocking:
      f.io.release(snapshotA)
      await f.configure(nil)
      #expect(f.waiters == 0)
    case .otherDestinationBlocking:
      f.io.release(snapshotA)
      await f.configure("B")
      #expect(f.waiters == 0)
    case .otherDestinationAsync:
      f.io.release(snapshotA)
      f.begin("B")
    case .waiterCancelled:
      waiter.cancel()
    }
    #expect(await finished(waiter), "the waiter was not resumed")
    let resumedState = await waiter.value
    switch configure {
    case .clearedAsync, .clearedBlocking:
      #expect(resumedState == .unconfigured)
    case .otherDestinationBlocking, .otherDestinationAsync:
      #expect(resumedState == .ready)
      #expect(f.filename("b1") == "B1.JPG")
      #expect(f.filename("a1") == nil)
    case .waiterCancelled:
      #expect(resumedState == .loading)
      #expect(f.waiters == 0)
      f.io.release(snapshotA)
      await f.settle()
      #expect(f.filename("a1") == "A1.JPG")
    }
  }

  // MARK: - How a load ends

  /// A corrupt snapshot reads as `.loading` first, then ends `.failed` with the file untouched.
  @Test(arguments: [false, true])
  func corruptSnapshotSettlesFailed(collection: Bool) async throws {
    let f = Fixture(collection: collection)
    defer { f.cleanup() }
    try await f.seed("A", ["a1": "A1.JPG"])
    await f.configure(nil)
    let snapshot = f.url("A", snapshot: true)
    let corrupt = Data("corrupt snapshot".utf8)
    try corrupt.write(to: snapshot)
    f.io.hold(snapshot)

    f.begin("A")
    try #require(f.state == .loading)
    f.io.release(snapshot)
    await f.settle()

    #expect(f.state == .failed)
    #expect(f.filename("a1") == nil)
    #expect(try Data(contentsOf: snapshot) == corrupt)
  }

  /// An unreadable snapshot reads as `.loading` first, then ends `.persistenceFailed` with the
  /// read error and nothing removed.
  @Test(arguments: [false, true])
  func unreadableSnapshotSettlesPersistenceFailed(collection: Bool) async throws {
    let f = Fixture(collection: collection)
    defer { f.cleanup() }
    try await f.seed("A", ["a1": "A1.JPG"])
    await f.configure(nil)
    let snapshot = f.url("A", snapshot: true)
    try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: false)
    f.io.hold(snapshot)

    f.begin("A")
    try #require(f.state == .loading)
    f.io.release(snapshot)
    await f.settle()

    #expect(f.state == .persistenceFailed)
    let error = collection ? f.collections.persistenceError : f.timeline.persistenceError
    #expect(error != nil)
    #expect(f.filename("a1") == nil)
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: snapshot.path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)
  }

  // MARK: - Final commits during a load

  enum LoadEnding: CaseIterable, Sendable { case ready, corrupt, unreadable }

  /// A final commit acknowledged while its destination loads lands once the load finishes, the
  /// way it would have landed on that ending: recorded on a good load, deferred until the reset
  /// on a corrupt one, and added to the restored parked history on an unreadable one.
  @Test(arguments: [false, true], LoadEnding.allCases)
  func finalCommitDuringLoadIsReplayed(collection: Bool, ending: LoadEnding) async throws {
    let f = Fixture(collection: collection)
    defer { f.cleanup() }
    try await f.seed("A", ["old": "OLD.JPG"])
    let acknowledge = try f.capture()
    await f.configure("B")
    let snapshot = f.url("A", snapshot: true)
    let log = f.url("A", snapshot: false)
    let logBytes = try Data(contentsOf: log)
    switch ending {
    case .ready:
      break
    case .corrupt:
      try Data("corrupt snapshot".utf8).write(to: snapshot)
    case .unreadable:
      try FileManager.default.removeItem(at: log)
      try FileManager.default.createDirectory(at: log, withIntermediateDirectories: false)
    }
    f.begin("A")
    try #require(f.state == .loading)

    // A load is installed on the main actor, which the acknowledgement keeps until it returns,
    // so the commit arrives while the destination loads. No read is held: an acknowledgement
    // that waited for IO would fail the checks below instead of hanging the test until its
    // time limit, which makes Xcode restart the test process.
    await acknowledge(Self.committed)
    #expect(f.filename() == nil)
    #expect(f.state == .loading, "the acknowledgement let the load finish first")
    await f.settle()

    switch ending {
    case .ready:
      #expect(f.state == .ready)
      #expect(f.filename() == Self.committed)
      #expect(f.filename("old") == "OLD.JPG")
      #expect(f.isClaimed(Self.committed))
      try await f.flush()
      await f.configure("B")
      await f.configure("A")
      #expect(f.filename() == Self.committed)
    case .corrupt:
      #expect(f.state == .failed)
      #expect(f.filename() == nil)
      await f.resetHistory()
      #expect(f.state == .ready)
      #expect(f.filename() == Self.committed)
      #expect(f.isClaimed(Self.committed))
    case .unreadable:
      #expect(f.state == .persistenceFailed)
      #expect(f.filename() == Self.committed)
      #expect(f.filename("old") == "OLD.JPG")
      #expect(f.isClaimed("OLD.JPG"))
      try FileManager.default.removeItem(at: log)
      try logBytes.write(to: log)
      await f.retryHistoryPersistence()
      #expect(f.state == .ready)
      await f.configure("B")
      await f.configure("A")
      #expect(f.filename() == Self.committed)
      #expect(f.filename("old") == "OLD.JPG")
    }
  }

  enum Departure: CaseIterable, Sendable {
    case otherDestinationAsync, otherDestinationBlocking, cleared
  }

  /// A final commit held for its destination's load is written to that destination's files when
  /// the store leaves it before the load finishes, so a later load of that destination finds it.
  @Test(arguments: [false, true], Departure.allCases)
  func finalCommitHeldForALoadIsWrittenWhenTheStoreLeaves(
    collection: Bool, departure: Departure
  ) async throws {
    let f = Fixture(collection: collection)
    defer { f.cleanup() }
    try await f.seed("B", ["b1": "B1.JPG"])
    try await f.seed("A", ["old": "OLD.JPG"])
    let acknowledge = try f.capture()
    await f.configure("B")
    f.begin("A")
    try #require(f.state == .loading)
    // As in `finalCommitDuringLoadIsReplayed`, the main actor stays with the acknowledgement,
    // so the load is still running when it returns and when the store leaves the destination.
    await acknowledge(Self.committed)
    try #require(f.state == .loading, "the acknowledgement let the load finish first")

    switch departure {
    case .otherDestinationAsync: f.begin("B")
    case .otherDestinationBlocking: await f.configure("B")
    case .cleared: f.begin(nil)
    }
    await f.settle()
    #expect(f.filename() == nil, "the commit landed in the history the store moved to")

    #expect(await f.filenameOnDisk("A") == Self.committed, "the commit is not in A's files")
    #expect(await f.filenameOnDisk("A", "old") == "OLD.JPG")
    #expect(await f.filenameOnDisk("B") == nil)
    await f.configure("A")
    #expect(f.state == .ready)
    #expect(f.filename() == Self.committed)
    #expect(f.filename("old") == "OLD.JPG")
  }

  /// A final-commit write failure retained while the destination loads parks only the commit's
  /// own snapshot: it does not copy the empty in-memory records or mark them unsaved. The load
  /// then installs the parked history. No known sequence reaches this; the guard is defensive.
  @Test(arguments: [false, true])
  func retainedFailureWhileLoadingParksOnlyTheCommitSnapshot(collection: Bool) async throws {
    let f = Fixture(collection: collection)
    defer { f.cleanup() }
    try await f.seed("A", ["old": "OLD.JPG"])
    await f.configure("B")
    let snapshot = f.url("A", snapshot: true)
    f.io.hold(snapshot)
    f.begin("A")
    try #require(f.state == .loading)

    let queue = DispatchQueue(label: "RecordStoreAsyncLoad.parked")
    let logger = Logger(subsystem: TestLogging.subsystem, category: "RecordStoreAsyncLoad")
    let done = ExportVariantRecord(
      filename: "PARKED.JPG", status: .done, exportDate: Date(), lastError: nil)
    if collection {
      let file = CollectionExportRecordStore.RecordFile(
        snapshotURL: snapshot, logURL: f.url("A", snapshot: false), ioQueue: queue,
        logger: logger)
      let parked = CollectionExportRecordStore.Snapshot(
        version: CollectionExportRecordStore.Constants.snapshotVersion,
        placements: [f.placement.id: f.placement],
        records: [f.placement.id: ["parked": .init(variants: ["original": done])]])
      let context = FinalCommitContext(destinationId: "A", file: file, snapshot: parked)
      f.collections.retainFinalCommitFailure(RecordPersistenceUnavailable(), context: context)
      #expect(context.snapshot == parked)
    } else {
      let file = ExportRecordStore.RecordFile(
        snapshotURL: snapshot, logURL: f.url("A", snapshot: false), ioQueue: queue,
        logger: logger)
      let parked = [
        "parked": ExportRecord(
          id: "parked", year: 2025, month: 6, relPath: f.placement.relativePath,
          variants: [.original: done])
      ]
      let context = FinalCommitContext(destinationId: "A", file: file, snapshot: parked)
      f.timeline.retainFinalCommitFailure(RecordPersistenceUnavailable(), context: context)
      #expect(context.snapshot == parked)
    }
    #expect(f.state == .loading)

    f.io.release(snapshot)
    await f.settle()
    #expect(f.state == .persistenceFailed)
    #expect(f.filename("parked") == "PARKED.JPG")
    #expect(f.filename("old") == nil)
  }

  // MARK: - Claims

  /// A claim index built from the empty records while the load runs is dropped when the load
  /// finishes, so the loaded names read as claimed.
  @Test(arguments: [false, true])
  func claimIndexBuiltWhileLoadingIsDiscarded(collection: Bool) async throws {
    let f = Fixture(collection: collection)
    defer { f.cleanup() }
    try await f.seed("A", ["a1": "A1.JPG"])
    await f.configure("B")
    let snapshot = f.url("A", snapshot: true)
    f.io.hold(snapshot)
    f.begin("A")
    try #require(f.state == .loading)

    #expect(!f.isClaimed("A1.JPG"))
    f.io.release(snapshot)
    await f.settle()
    #expect(f.state == .ready)
    #expect(f.isClaimed("A1.JPG"), "the index built during the load survived it")
  }

  // MARK: - Log separator

  enum LogTail: CaseIterable, Sendable { case completeLineWithoutLF, partialLine }

  /// The asynchronous load takes on what it found at the end of the log, so the first append
  /// after it starts a new line.
  @Test(arguments: [false, true], LogTail.allCases)
  func asyncLoadAdoptsTheLogSeparator(collection: Bool, tail: LogTail) async throws {
    let f = Fixture(collection: collection)
    defer { f.cleanup() }
    try await f.seed("A", ["a1": "A1.JPG"])
    await f.configure(nil)
    let log = f.url("A", snapshot: false)
    var bytes = try Data(contentsOf: log)
    let completeLines = bytes.split(separator: 0x0A).count
    switch tail {
    case .completeLineWithoutLF:
      #expect(bytes.last == 0x0A)
      bytes.removeLast()
    case .partialLine:
      bytes.append(Data(#"{"op":"upsert"#.utf8))
    }
    try bytes.write(to: log)

    f.begin("A")
    await f.settle()
    #expect(f.state == .ready)
    f.mark("a2", "A2.JPG")
    try await f.flush()

    let written = try Data(contentsOf: log)
    #expect(written.starts(with: bytes + Data([0x0A])))
    #expect(written.last == 0x0A)
    let malformed: Int
    let ops: Int
    let queue = DispatchQueue(label: "RecordStoreAsyncLoad.reload")
    let logger = Logger(subsystem: TestLogging.subsystem, category: "RecordStoreAsyncLoad")
    if collection {
      let reload =
        (await CollectionExportRecordStore.RecordFile(
          snapshotURL: f.url("A", snapshot: true), logURL: log, ioQueue: queue, logger: logger
        ).load())
      (malformed, ops) = (reload.malformedLineCount, reload.ops.count)
    } else {
      let reload =
        (await ExportRecordStore.RecordFile(
          snapshotURL: f.url("A", snapshot: true), logURL: log, ioQueue: queue, logger: logger
        ).load())
      (malformed, ops) = (reload.malformedLineCount, reload.ops.count)
    }
    #expect(ops == completeLines + 1)
    #expect(malformed == (tail == .partialLine ? 1 : 0))
    await f.configure("B")
    await f.configure("A")
    #expect(f.filename("a1") == "A1.JPG")
    #expect(f.filename("a2") == "A2.JPG")
  }

  // MARK: - Notifications

  /// The asynchronous load publishes `.loading`, then notifies again when it finishes.
  @Test(arguments: [false, true])
  func finishingTheLoadNotifies(collection: Bool) async throws {
    let f = Fixture(collection: collection)
    defer { f.cleanup() }
    try await f.seed("A", ["a1": "A1.JPG"])
    await f.configure(nil)
    let states = ObservedValues { f.state }
    let snapshot = f.url("A", snapshot: true)
    f.io.hold(snapshot)

    f.begin("A")
    #expect(states.values == [.loading])
    let whileLoading = f.mutationCounter
    f.io.release(snapshot)
    await f.settle()

    #expect(states.values == [.loading, .ready])
    #expect(f.mutationCounter == whileLoading + 1, "finishing the load did not notify")
  }

  // MARK: - Queue order

  /// An append that is still queued when the destination is switched away and back is part of
  /// the history the next load reads. A smoke check of IO-queue ordering: the serial queue alone
  /// orders the read after the append, so removing the configure's drain does not fail it.
  @Test(arguments: [false, true])
  func asyncLoadReadsAfterQueuedAppends(collection: Bool) async throws {
    let f = Fixture(collection: collection)
    defer { f.cleanup() }
    await f.configure("A")
    f.mark("a1", "A1.JPG")
    f.begin("B")
    f.begin("A")
    await f.settle()
    #expect(f.state == .ready)
    #expect(f.filename("a1") == "A1.JPG")
  }
}
