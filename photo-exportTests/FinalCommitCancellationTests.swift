import Foundation
import Testing

@testable import Photo_Export

@MainActor
struct FinalCommitCancellationTests {
  enum Phase: CaseIterable { case move, timestamps }

  private final class Gate: @unchecked Sendable {
    let entered = AsyncCheckpoint()
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var used = false

    func holdOnce() {
      guard
        lock.withLock({
          if used { return false }
          used = true
          return true
        })
      else { return }
      Task { await entered.enter() }
      // Teardown always releases; the bound only keeps a broken test from stranding the worker.
      if semaphore.wait(timeout: .now() + 150) != .success {
        Issue.record("Final commit gate timed out")
      }
    }

    func release() { semaphore.signal() }
  }

  private final class LogGate: JSONLRecordLogIO, @unchecked Sendable {
    let gate = Gate()
    private let lock = NSLock()
    private var armed = false
    private let real = ProductionJSONLRecordLogIO()
    func arm() { lock.withLock { armed = true } }
    func readIfPresent(at url: URL) throws -> Data? { try real.readIfPresent(at: url) }
    func openForAppending(at url: URL) throws -> FileHandle {
      if url.deletingLastPathComponent().lastPathComponent == "A", lock.withLock({ armed }) {
        gate.holdOnce()
      }
      return try real.openForAppending(at: url)
    }
    func write(_ data: Data, to handle: FileHandle) throws { try real.write(data, to: handle) }
    func synchronize(_ handle: FileHandle) throws { try real.synchronize(handle) }
  }

  private final class Destination: ExportDestination {
    let root = TestScratch.directory("FinalCommitCancellation")
    var selectedFolderURL: URL?
    var canExportNow: Bool { true }
    var canImportNow: Bool { true }
    var closed: [URL] = []

    init() { selectedFolderURL = root.appendingPathComponent("A") }
    func beginScopedAccess() -> URL? { selectedFolderURL }
    func endScopedAccess(for url: URL) { closed.append(url) }
    func urlForRelativeDirectory(_ path: String, createIfNeeded: Bool) throws -> URL {
      let url = try #require(selectedFolderURL).appendingPathComponent(path)
      if createIfNeeded {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      }
      return url
    }
    func urlForMonth(year: Int, month: Int, createIfNeeded: Bool) throws -> URL {
      try urlForRelativeDirectory(
        "\(year)/\(String(format: "%02d", month))/", createIfNeeded: createIfNeeded)
    }
  }

  @MainActor
  private final class Fixture {
    let destination = Destination()
    let photos = FakePhotoLibraryService()
    let writer = FakeAssetResourceWriter()
    let files = FakeFileSystem()
    let timeline: ExportRecordStore
    let collections: CollectionExportRecordStore
    let manager: ExportManager
    let defaultsName = TestScratch.suiteName("FinalCommit")
    let defaults: UserDefaults
    let placement: ExportPlacement
    let asset: AssetDescriptor
    let gate = Gate()
    let root = TestScratch.directory("FinalCommitCancellation")

    init(
      collection: Bool, phase: Phase, fallback: Bool = false,
      logIO: any JSONLRecordLogIO = ProductionJSONLRecordLogIO()
    ) throws {
      defaults = TestScratch.defaults(suiteName: defaultsName)
      placement = collection ? .favorites() : .timeline(year: 2025, month: 1)
      asset = TestAssetFactory.makeAsset(
        id: "asset",
        creationDate: Calendar.current.date(from: DateComponents(year: 2025, month: 1, day: 15))!,
        hasAdjustments: fallback)
      timeline = ExportRecordStore(baseDirectoryURL: root, recordLogIO: logIO)
      collections = CollectionExportRecordStore(baseDirectoryURL: root, recordLogIO: logIO)
      timeline.configure(for: "A")
      collections.configure(for: "A")
      manager = ExportManager(
        photoLibraryService: photos, exportDestination: destination,
        exportRecordStore: timeline, collectionExportRecordStore: collections,
        assetResourceWriter: writer, fileSystem: files, userDefaults: defaults)
      photos.assetsByYearMonth["2025-1"] = [asset]
      photos.favoritesAssets = [asset]
      photos.resourcesByAssetId[asset.id] = [.init(type: .photo, originalFilename: "FILE.JPG")]
      if phase == .move {
        files.afterMoveHook = { [gate] _, _ in gate.holdOnce() }
      } else {
        files.afterTimestampsHook = { [gate] _ in gate.holdOnce() }
      }
    }

    func start() {
      if placement.kind == .favorites {
        manager.startExportFavorites()
      } else {
        manager.startExportMonth(year: 2025, month: 1)
      }
    }

    func variants(_ id: String = "asset") -> [ExportVariant: ExportVariantRecord] {
      if placement.kind == .favorites {
        return collections.exportInfo(assetId: id, placement: placement)?.variants ?? [:]
      }
      return timeline.exportInfo(assetId: id)?.variants ?? [:]
    }

    func sentinel(_ id: String) {
      timeline.markVariantExported(
        assetId: id, variant: .original, year: 2025, month: 1, relPath: placement.relativePath,
        filename: "\(id).JPG", exportedAt: Date())
      collections.upsertPlacement(.favorites())
      collections.markVariantExported(
        assetId: id, placement: .favorites(), variant: .original,
        filename: "\(id).JPG", exportedAt: Date())
    }

    func select(_ id: String) {
      destination.selectedFolderURL = destination.root.appendingPathComponent(id)
      timeline.configure(for: id)
      collections.configure(for: id)
    }

    func flush() async throws {
      try await timeline.flush()
      try await collections.flush()
    }

    func filesInA() throws -> [String] {
      try FileManager.default.contentsOfDirectory(
        atPath: destination.root.appendingPathComponent("A").appendingPathComponent(
          placement.relativePath
        ).path
      )
      .sorted()
    }

    /// Releases the held commit, cancels, and waits for that work to stop before the
    /// folders it writes to are removed.
    func cleanup() async {
      var running = manager.currentPreparationTasks + [manager.currentTask].compactMap { $0 }
      gate.release()
      await gate.entered.releaseAll()
      manager.cancelAndClear()
      running += manager.currentPreparationTasks + [manager.currentTask].compactMap { $0 }
      for task in running { _ = await finished(task) }
      timeline.drainSynchronously()
      collections.drainSynchronously()
      try? FileManager.default.removeItem(at: destination.root)
      try? FileManager.default.removeItem(at: root)
      defaults.removePersistentDomain(forName: defaultsName)
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: Phase.allCases, [false, true])
  func cancelThenRetryRecognizesCommittedOutput(phase: Phase, collection: Bool) async throws {
    let f = try Fixture(collection: collection, phase: phase)
    try await withCleanup {
      f.start()
      await f.gate.entered.waitForEnter(count: 1)
      let old = try #require(f.manager.currentTask)
      #expect(try f.filesInA() == ["FILE.JPG"])
      f.manager.cancelAndClear()
      #expect(f.destination.closed.isEmpty)
      f.gate.release()
      await old.value
      #expect(f.variants()[.original]?.status == .done)
      #expect(
        f.destination.closed.map(\.path) == [f.destination.root.appendingPathComponent("A").path])
      let final = f.destination.root.appendingPathComponent("A")
        .appendingPathComponent(f.placement.relativePath).appendingPathComponent("FILE.JPG")
      let resource = try #require(f.photos.resourcesByAssetId[f.asset.id]?.first)
      #expect(
        try Data(contentsOf: final)
          == FakeAssetResourceWriter.content(for: resource, assetId: f.asset.id))
      #expect(f.files.timestampCalls.count == 1)
      #expect(f.files.timestampCalls.first?.url.path == final.path)
      #expect(f.files.timestampCalls.first?.date == f.asset.creationDate)
      f.start()
      await f.manager.waitForQueueDrained()
      try await f.flush()
      #expect(try f.filesInA() == ["FILE.JPG"])
      #expect(f.writer.writeCalls.count == 1)
      f.select("B")
      f.select("A")
      #expect(f.variants()[.original]?.filename == "FILE.JPG")
    } cleanup: {
      await f.cleanup()
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: Phase.allCases, [false, true])
  func switchedDestinationGetsNoLateRecord(phase: Phase, collection: Bool) async throws {
    let f = try Fixture(collection: collection, phase: phase)
    try await withCleanup {
      f.start()
      await f.gate.entered.waitForEnter(count: 1)
      let old = try #require(f.manager.currentTask)
      f.manager.cancelAndClear()
      f.select("B")
      f.sentinel("B-only")
      f.manager.progressState.renderActivity = .rendering
      f.gate.release()
      await old.value
      #expect(f.variants().isEmpty)
      #expect(f.variants("B-only")[.original]?.status == .done)
      #expect(f.manager.renderActivity == .rendering)
      #expect(try f.filesInA() == ["FILE.JPG"])
      try await f.flush()
      f.select("A")
      #expect(f.variants()[.original]?.status == .done)
      f.start()
      await f.manager.waitForQueueDrained()
      #expect(f.writer.writeCalls.count == 1)
      #expect(try f.filesInA() == ["FILE.JPG"])
    } cleanup: {
      await f.cleanup()
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: Phase.allCases, [false, true])
  func returningToOriginalOwnerPreservesNewerRecords(phase: Phase, collection: Bool) async throws {
    let f = try Fixture(collection: collection, phase: phase)
    try await withCleanup {
      f.start()
      await f.gate.entered.waitForEnter(count: 1)
      let old = try #require(f.manager.currentTask)
      f.manager.cancelAndClear()
      f.select("B")
      f.sentinel("B-only")
      f.select("A")
      f.sentinel("newer-A")
      f.gate.release()
      await old.value
      try await f.flush()
      f.select("B")
      #expect(f.variants().isEmpty)
      #expect(f.variants("B-only")[.original]?.status == .done)
      f.select("A")
      #expect(f.variants()[.original]?.status == .done)
      #expect(f.variants("newer-A")[.original]?.status == .done)
    } cleanup: {
      await f.cleanup()
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: Phase.allCases, [false, true])
  func immediateRetryWaitsBeforeAllocatingAnotherOutput(phase: Phase, collection: Bool) async throws
  {
    let f = try Fixture(collection: collection, phase: phase)
    let admitted = AsyncCheckpoint()
    try await withCleanup {
      f.start()
      await f.gate.entered.waitForEnter(count: 1)
      let old = try #require(f.manager.currentTask)
      f.manager.cancelAndClear()
      f.writer.checkpoint = admitted
      f.manager.finalCommitWaitObserver = { Task { await admitted.enter() } }
      f.start()
      // Old implementation reaches writer 2; fixed implementation reaches the IO fence.
      await admitted.waitForEnter(count: 1)
      #expect(f.writer.writeCalls.count == 1)
      #expect(try f.filesInA() == ["FILE.JPG"])
      f.manager.progressState.renderActivity = .rendering
      f.gate.release()
      await old.value
      await admitted.releaseAll()
      await f.manager.waitForQueueDrained()
      try await f.flush()
      #expect(f.writer.writeCalls.count == 1)
      #expect(try f.filesInA() == ["FILE.JPG"])
      #expect(f.variants()[.original]?.status == .done)
    } cleanup: {
      await admitted.releaseAll()
      await f.cleanup()
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func switchedAcknowledgementFailureRemainsRecoverable(collection: Bool) async throws {
    let f = try Fixture(collection: collection, phase: .move)
    try await withCleanup {
      f.start()
      await f.gate.entered.waitForEnter(count: 1)
      let old = try #require(f.manager.currentTask)
      f.manager.cancelAndClear()
      f.select("B")
      f.sentinel("B-only")
      let name =
        collection
        ? CollectionExportRecordStore.Constants.logFileName
        : ExportRecordStore.Constants.logFileName
      let log = f.root.appendingPathComponent("A").appendingPathComponent(name)
      try FileManager.default.removeItem(at: log)
      try FileManager.default.createDirectory(at: log, withIntermediateDirectories: false)
      f.gate.release()
      await old.value
      #expect(f.variants("B-only")[.original]?.status == .done)
      try FileManager.default.removeItem(at: log)
      f.select("A")
      #expect(f.variants()[.original]?.filename == "FILE.JPG")
      if collection {
        #expect(f.collections.state == .persistenceFailed)
        f.collections.retryPersistence()
        #expect(f.collections.state == .ready)
      } else {
        #expect(f.timeline.state == .persistenceFailed)
        f.timeline.retryPersistence()
        #expect(f.timeline.state == .ready)
      }
      f.select("B")
      f.select("A")
      #expect(f.variants()[.original]?.status == .done)
      f.start()
      await f.manager.waitForQueueDrained()
      #expect(f.writer.writeCalls.count == 1)
    } cleanup: {
      await f.cleanup()
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func returningToUnreadableOwnerRetainsCompletion(collection: Bool) async throws {
    let f = try Fixture(collection: collection, phase: .move)
    try await withCleanup {
      f.start()
      await f.gate.entered.waitForEnter(count: 1)
      let old = try #require(f.manager.currentTask)
      f.manager.cancelAndClear()
      f.select("B")
      let name =
        collection
        ? CollectionExportRecordStore.Constants.logFileName
        : ExportRecordStore.Constants.logFileName
      let log = f.root.appendingPathComponent("A").appendingPathComponent(name)
      let originalLog = try Data(contentsOf: log)
      try FileManager.default.removeItem(at: log)
      try FileManager.default.createDirectory(at: log, withIntermediateDirectories: false)
      f.select("A")
      f.gate.release()
      await old.value
      #expect(f.variants()[.original]?.status == .done)
      try FileManager.default.removeItem(at: log)
      try originalLog.write(to: log)
      f.timeline.retryPersistence()
      f.collections.retryPersistence()
      f.select("B")
      f.select("A")
      #expect(f.variants()[.original]?.status == .done)
      f.start()
      await f.manager.waitForQueueDrained()
      #expect(f.writer.writeCalls.count == 1)
    } cleanup: {
      await f.cleanup()
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func deletedCollectionPlacementIsRestoredForCommittedOutput(switchAway: Bool) async throws {
    let f = try Fixture(collection: true, phase: .move)
    try await withCleanup {
      f.start()
      await f.gate.entered.waitForEnter(count: 1)
      let old = try #require(f.manager.currentTask)
      f.manager.cancelAndClear()
      f.collections.deletePlacement(id: f.placement.id)
      if switchAway { f.select("B") }
      f.gate.release()
      await old.value
      f.select("A")
      #expect(f.variants()[.original]?.status == .done)
      #expect(f.collections.placement(id: f.placement.id) == f.placement)
    } cleanup: {
      await f.cleanup()
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func lateMoveFailureCannotWriteIntoReplacementDestination() async throws {
    let f = try Fixture(collection: true, phase: .move)
    try await withCleanup {
      f.files.afterMoveHook = nil
      f.files.beforeMoveHook = { [gate = f.gate] _, _ in
        gate.holdOnce()
        throw CocoaError(.fileWriteOutOfSpace)
      }
      f.start()
      await f.gate.entered.waitForEnter(count: 1)
      let old = try #require(f.manager.currentTask)
      f.manager.cancelAndClear()
      f.select("B")
      f.sentinel("B-only")
      f.manager.progressState.renderActivity = .rendering
      f.gate.release()
      await old.value
      #expect(f.variants().isEmpty)
      #expect(f.variants("B-only")[.original]?.status == .done)
      #expect(f.manager.renderActivity == .rendering)
    } cleanup: {
      await f.cleanup()
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func cancelledFirstVariantDoesNotStartFurtherVariants() async throws {
    let f = try Fixture(collection: false, phase: .move, fallback: true)
    try await withCleanup {
      f.photos.resourcesByAssetId[f.asset.id]?.append(
        .init(type: .fullSizePhoto, originalFilename: "EDITED.JPG"))
      f.manager.versionSelection = .editedWithOriginals
      f.start()
      await f.gate.entered.waitForEnter(count: 1)
      let old = try #require(f.manager.currentTask)
      f.manager.cancelAndClear()
      f.gate.release()
      await old.value
      #expect(f.variants()[.original]?.status == .done)
      #expect(f.variants()[.edited] == nil)
      #expect(f.writer.writeCalls.count == 1)
    } cleanup: {
      await f.cleanup()
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func oldCommitCannotClearReplacementJobOrStage() async throws {
    let f = try Fixture(collection: true, phase: .move)
    let admitted = AsyncCheckpoint()
    let replacementWritten = AsyncCheckpoint()
    try await withCleanup {
      f.start()
      await f.gate.entered.waitForEnter(count: 1)
      let old = try #require(f.manager.currentTask)
      f.manager.cancelAndClear()
      f.select("B")
      let replacement = TestAssetFactory.makeAsset(id: "replacement")
      f.photos.favoritesAssets = [replacement]
      f.photos.resourcesByAssetId[replacement.id] = [.init(type: .photo, originalFilename: "B.JPG")]
      f.writer.afterWriteCheckpoint = replacementWritten
      f.manager.finalCommitWaitObserver = { Task { await admitted.enter() } }
      f.start()
      await admitted.waitForEnter(count: 1)
      #expect(f.manager.currentJobAssetId == replacement.id)
      f.gate.release()
      await replacementWritten.waitForEnter(count: 1)
      f.manager.progressState.renderActivity = .rendering
      let stage = try #require(f.writer.writeCalls.last?.url)
      let bytes = try Data(contentsOf: stage)
      await old.value
      #expect(try Data(contentsOf: stage) == bytes)
      #expect(f.manager.currentJobAssetId == replacement.id)
      #expect(f.manager.currentJobVariant == .original)
      #expect(f.manager.currentAssetFilename == "B.JPG")
      #expect(f.manager.renderActivity == .rendering)
      await replacementWritten.releaseAll()
      await f.manager.waitForQueueDrained()
      #expect(f.variants(replacement.id)[.original]?.status == .done)
      #expect(f.writer.writeCalls.count == 2)
    } cleanup: {
      await admitted.releaseAll()
      await replacementWritten.releaseAll()
      await f.cleanup()
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true])
  func corruptOwnerKeepsAlertAndReplaysOnlyCommittedDeltaAfterReset(
    collection: Bool, switchAway: Bool
  ) async throws {
    let f = try Fixture(collection: collection, phase: .move)
    try await withCleanup {
      f.sentinel("old-history")
      f.start()
      await f.gate.entered.waitForEnter(count: 1)
      let old = try #require(f.manager.currentTask)
      f.manager.cancelAndClear()
      f.select("B")
      let name =
        collection
        ? CollectionExportRecordStore.Constants.snapshotFileName
        : ExportRecordStore.Constants.snapshotFileName
      let snapshot = f.root.appendingPathComponent("A").appendingPathComponent(name)
      let corrupt = Data("corrupt snapshot".utf8)
      try corrupt.write(to: snapshot)
      f.select("A")
      if switchAway { f.select("B") }
      f.gate.release()
      await old.value
      if switchAway { f.select("A") }
      #expect(try Data(contentsOf: snapshot) == corrupt)
      #expect(collection ? f.collections.state == .failed : f.timeline.state == .failed)
      // Switching away/back must not let retained progress hide corruption.
      f.select("B")
      f.select("A")
      #expect(collection ? f.collections.state == .failed : f.timeline.state == .failed)
      if collection { f.collections.resetToEmpty() } else { f.timeline.resetToEmpty() }
      #expect(f.variants()[.original]?.status == .done)
      #expect(f.variants("old-history").isEmpty)
      let broken = try FileManager.default.contentsOfDirectory(
        at: snapshot.deletingLastPathComponent(), includingPropertiesForKeys: nil
      )
      .filter { $0.lastPathComponent.contains("broken-") }
      #expect(broken.count == 1)
      #expect(try Data(contentsOf: #require(broken.first)) == corrupt)
      try await f.flush()
      f.select("B")
      f.select("A")
      #expect(f.variants()[.original]?.status == .done)
      f.start()
      await f.manager.waitForQueueDrained()
      #expect(f.writer.writeCalls.count == 1)
    } cleanup: {
      await f.cleanup()
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func failedOldMoveCannotRemoveReplacementStage() async throws {
    let f = try Fixture(collection: false, phase: .move)
    let admitted = AsyncCheckpoint()
    let replacementWritten = AsyncCheckpoint()
    try await withCleanup {
      f.files.afterMoveHook = nil
      f.files.beforeMoveHook = { [gate = f.gate] _, _ in
        gate.holdOnce()
        throw CocoaError(.fileWriteOutOfSpace)
      }
      f.start()
      await f.gate.entered.waitForEnter(count: 1)
      let old = try #require(f.manager.currentTask)
      f.manager.cancelAndClear()
      f.writer.afterWriteCheckpoint = replacementWritten
      f.manager.finalCommitWaitObserver = { Task { await admitted.enter() } }
      f.start()
      await admitted.waitForEnter(count: 1)
      f.files.beforeMoveHook = nil
      f.gate.release()
      await replacementWritten.waitForEnter(count: 1)
      let stage = try #require(f.writer.writeCalls.last?.url)
      let bytes = try Data(contentsOf: stage)
      f.manager.progressState.renderActivity = .rendering
      await old.value
      #expect(try Data(contentsOf: stage) == bytes)
      #expect(f.manager.currentJobAssetId == f.asset.id)
      #expect(f.manager.currentJobVariant == .original)
      #expect(f.manager.renderActivity == .rendering)
      await replacementWritten.releaseAll()
      await f.manager.waitForQueueDrained()
      #expect(f.variants()[.original]?.filename == "FILE.JPG")
      #expect(try f.filesInA() == ["FILE.JPG"])
    } cleanup: {
      await admitted.releaseAll()
      await replacementWritten.releaseAll()
      await f.cleanup()
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func destinationRoundTripDuringAcknowledgementPreservesLatestHistory(collection: Bool)
    async throws
  {
    let io = LogGate()
    let f = try Fixture(collection: collection, phase: .move, logIO: io)
    try await withCleanup {
      f.start()
      await f.gate.entered.waitForEnter(count: 1)
      let old = try #require(f.manager.currentTask)
      f.manager.cancelAndClear()
      f.select("B")
      f.sentinel("B-only")
      io.arm()
      f.gate.release()
      await io.gate.entered.waitForEnter(count: 1)
      // No MainActor suspension between release and reconfiguration: the parked
      // writer may finish physically, but its acknowledgement cannot resume yet.
      io.gate.release()
      f.select("A")
      f.sentinel("newer-A")
      f.select("B")
      await old.value
      f.select("A")
      #expect(f.variants()[.original]?.status == .done)
      #expect(f.variants("newer-A")[.original]?.status == .done)
      f.select("B")
      #expect(f.variants("B-only")[.original]?.status == .done)
      #expect(f.variants().isEmpty)
    } cleanup: {
      io.gate.release()
      await io.gate.entered.releaseAll()
      await f.cleanup()
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: Phase.allCases)
  func cancelledFallbackAcknowledgesAcceptance(phase: Phase) async throws {
    let f = try Fixture(collection: false, phase: phase, fallback: true)
    try await withCleanup {
      f.manager.versionSelection = .edited
      f.start()
      await f.gate.entered.waitForEnter(count: 1)
      let old = try #require(f.manager.currentTask)
      f.manager.cancelAndClear()
      f.gate.release()
      await old.value
      #expect(f.variants()[.edited]?.reason == .editedUnavailableOriginalBackedUp)
      f.start()
      await f.manager.waitForQueueDrained()
      #expect(try f.filesInA() == ["FILE_orig.JPG"])
      #expect(f.writer.writeCalls.count == 1)
    } cleanup: {
      await f.cleanup()
    }
  }
}
