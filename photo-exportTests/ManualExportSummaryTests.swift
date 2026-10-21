import Combine
import Foundation
import Testing

@testable import Photo_Export

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct ManualExportSummaryTests {
  @MainActor
  private final class Fixture {
    let root = TestScratch.directory("ManualExportSummary")
    let suite = TestScratch.suiteName("ManualSummary")
    let defaults: UserDefaults
    let photos = FakePhotoLibraryService()
    let destination = FakeExportDestination()
    let writer = FakeAssetResourceWriter()
    let timeline: ExportRecordStore
    let collections: CollectionExportRecordStore
    let manager: ExportManager

    private var closed = false

    init(logIO: any JSONLRecordLogIO = ProductionJSONLRecordLogIO()) {
      defaults = TestScratch.defaults(suiteName: suite)
      timeline = ExportRecordStore(baseDirectoryURL: root, recordLogIO: logIO)
      collections = CollectionExportRecordStore(baseDirectoryURL: root)
      timeline.configure(for: "A")
      collections.configure(for: "A")
      manager = ExportManager(
        photoLibraryService: photos, exportDestination: destination,
        exportRecordStore: timeline, collectionExportRecordStore: collections,
        assetResourceWriter: writer, fileSystem: FakeFileSystem(), userDefaults: defaults)
    }

    func seed(_ ids: [String], year: Int = 2026, month: Int = 9, missing: Set<String> = []) {
      let date = Calendar.current.date(from: DateComponents(year: year, month: month, day: 15))!
      photos.assetsByYearMonth["\(year)-\(month)"] = ids.map {
        TestAssetFactory.makeAsset(id: $0, creationDate: date)
      }
      for id in ids where !missing.contains(id) {
        photos.resourcesByAssetId[id] = [
          TestAssetFactory.makeResource(originalFilename: "\(id).JPG")
        ]
      }
    }

    func close() {
      guard !closed else { return }
      closed = true
      manager.cancelAndClear()
      timeline.drainSynchronously()
      collections.drainSynchronously()
      destination.cleanup()
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
  }

  private func reached(_ gate: AsyncCheckpoint) async -> Bool {
    await gate.waitForEnter(count: 1)
  }

  private final class FailingLogIO: JSONLRecordLogIO, @unchecked Sendable {
    private let lock = NSLock()
    private var writes = 0
    private let failOn: Int
    private var committedFile: URL?
    private let production = ProductionJSONLRecordLogIO()
    init(failOn: Int) { self.failOn = failOn }
    func failAfterFileAppears(_ url: URL) { lock.withLock { committedFile = url } }
    func readIfPresent(at url: URL) throws -> Data? { try production.readIfPresent(at: url) }
    func openForAppending(at url: URL) throws -> FileHandle {
      try production.openForAppending(at: url)
    }
    func write(_ data: Data, to handle: FileHandle) throws {
      let (count, file) = lock.withLock {
        writes += 1
        return (writes, committedFile)
      }
      let fail = file.map { FileManager.default.fileExists(atPath: $0.path) } ?? (count == failOn)
      if fail { throw CocoaError(.fileWriteOutOfSpace) }
      try production.write(data, to: handle)
    }
    func synchronize(_ handle: FileHandle) throws { try production.synchronize(handle) }
  }

  @Test func legacyManualFailureReportsJobOutcomeWithoutNewRunPublications() async throws {
    let f = Fixture()
    defer { f.close() }
    f.seed(["one", "two", "broken"], missing: ["broken"])
    var completedRuns: [ExportRunSummary] = []
    let subscription = f.manager.completedRunsPublisher.sink { completedRuns.append($0) }
    defer { subscription.cancel() }
    f.manager.startExportMonth(year: 2026, month: 9)
    await f.manager.waitForQueueDrained()
    #expect(f.timeline.exportInfo(assetId: "one")?.variants[.original]?.status == .done)
    #expect(f.timeline.exportInfo(assetId: "two")?.variants[.original]?.status == .done)
    #expect(f.timeline.exportInfo(assetId: "broken")?.variants[.original]?.status == .failed)
    #expect(f.manager.totalJobsCompleted == 3)
    let summary = try #require(f.manager.progressState.manualSummary)
    #expect(summary.completedCount == 3 && summary.failedCount == 1)
    #expect(summary.result == .failed && summary.message == "2 exported · 1 failed")
    #expect(f.manager.activeRunContext == nil && completedRuns.isEmpty)
  }

  @Test func successfulManualRunAndNextAcceptedStartReplaceTerminalFeedback() async throws {
    let f = Fixture()
    defer { f.close() }
    f.seed(["one"])
    f.manager.startExportMonth(year: 2026, month: 9)
    await f.manager.waitForQueueDrained()
    let summary = try #require(f.manager.progressState.manualSummary)
    #expect(summary.result == .completed && summary.message == "Export complete")
    f.manager.startExportMonth(year: 2026, month: 10)
    #expect(f.manager.progressState.manualSummary == nil)
    await f.manager.waitForQueueDrained()
    #expect(f.manager.progressState.manualSummary == nil)
    #expect(f.manager.emptyRunMessage != nil)
  }

  @Test(arguments: [false, true])
  func zeroJobScanFailureAndDeniedPhotosNeverLookSuccessful(unauthorized: Bool) async throws {
    let f = Fixture()
    defer { f.close() }
    f.photos.isAuthorized = !unauthorized
    if !unauthorized { f.photos.fetchAssetsError = CocoaError(.fileReadUnknown) }
    f.manager.startExportMonth(year: 2026, month: 9)
    await f.manager.waitForQueueDrained()
    let summary = try #require(f.manager.progressState.manualSummary)
    #expect(summary.completedCount == 0 && summary.result == .failed)
    #expect(summary.failureMessage?.isEmpty == false)
    #expect(summary.message == "Export incomplete")
  }

  enum SingleScope: CaseIterable, Sendable {
    case favorites, album, albumTree, sharedAlbum, month, year

    var failureMessage: String {
      switch self {
      case .favorites: "Could not scan Favorites. Try exporting again."
      case .album, .albumTree: "Could not scan this album. Try exporting again."
      case .sharedAlbum: "Could not scan this shared album. Try exporting again."
      case .month: "Could not scan this month. Try exporting again."
      case .year: "Could not scan this year. Try exporting again."
      }
    }
  }

  /// A single-scope export whose scan fails reports that scope's message, writes nothing,
  /// and leaves no work or run behind. Without the injected failure (the control), the
  /// same setup exports its one asset, so only the scan failure stops it.
  @Test(arguments: SingleScope.allCases, [true, false])
  func singleScopeScanFailureReportsItsMessageAndSettles(
    scope: SingleScope, injectFailure: Bool
  ) async throws {
    let f = Fixture()
    defer { f.close() }
    let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 15))!
    let asset = TestAssetFactory.makeAsset(id: "asset", creationDate: date)
    f.photos.resourcesByAssetId[asset.id] = [
      TestAssetFactory.makeResource(originalFilename: "ASSET.JPG")
    ]
    let error: Error? = injectFailure ? CocoaError(.fileReadUnknown) : nil
    switch scope {
    case .favorites:
      f.photos.favoritesAssets = [asset]
      f.photos.fetchAssetsError = error
    case .album, .albumTree:
      f.photos.collectionTree = [
        PhotoCollectionDescriptor(
          id: "album:album", localIdentifier: "album", title: "Album", kind: .album,
          pathComponents: [], children: [])
      ]
      f.photos.assetsByAlbumLocalId["album"] = [asset]
      if scope == .album {
        f.photos.fetchAssetsErrorByAlbumId["album"] = error
      } else {
        f.photos.collectionTreeError = error
      }
    case .sharedAlbum:
      f.photos.collectionTree = [
        PhotoCollectionDescriptor(
          id: "shared:shared", localIdentifier: "shared", title: "Shared", kind: .sharedAlbum,
          pathComponents: [], children: [])
      ]
      f.photos.assetsBySharedAlbumLocalId["shared"] = [asset]
      f.photos.fetchAssetsErrorByAlbumId["shared"] = error
    case .month, .year:
      f.photos.assetsByYearMonth["2026-9"] = [asset]
      f.photos.fetchAssetsErrorByYear[2026] = error
    }

    switch scope {
    case .favorites: f.manager.startExportFavorites()
    case .album, .albumTree: f.manager.startExportAlbum(collectionId: "album")
    case .sharedAlbum: f.manager.startExportSharedAlbum(collectionId: "shared")
    case .month: f.manager.startExportMonth(year: 2026, month: 9)
    case .year: f.manager.startExportYear(year: 2026)
    }
    let preparation = f.manager.currentPreparationTasks
    try #require(!preparation.isEmpty)
    for task in preparation {
      let done = await finished(task)
      try #require(done)
    }
    guard injectFailure else {
      await f.manager.waitForQueueDrained()
      #expect(f.writer.writeCalls.map(\.assetId) == [asset.id])
      return
    }

    let summary = try #require(f.manager.progressState.manualSummary)
    #expect(summary.result == .failed)
    #expect(summary.failureMessage == scope.failureMessage)
    #expect(f.manager.emptyRunMessage == nil)
    #expect(f.writer.writeCalls.isEmpty)
    #expect(!f.manager.hasActiveExportWork)
    #expect(f.manager.activeRunContext == nil)
  }

  @Test func multipleVariantFailuresCountAsOneFailedJob() async throws {
    let f = Fixture()
    defer { f.close() }
    let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 15))!
    f.photos.assetsByYearMonth["2026-9"] = [
      TestAssetFactory.makeAsset(
        id: "adjusted", creationDate: date, hasAdjustments: true)
    ]
    f.photos.resourcesByAssetId["adjusted"] = [
      TestAssetFactory.makeResource(originalFilename: "ORIGINAL.JPG"),
      TestAssetFactory.makeResource(type: .fullSizePhoto, originalFilename: "EDITED.JPG"),
    ]
    f.writer.writeError = CocoaError(.fileReadUnknown)
    f.manager.includeOriginals = true
    f.manager.startExportMonth(year: 2026, month: 9)
    await f.manager.waitForQueueDrained()
    let variants = try #require(f.timeline.exportInfo(assetId: "adjusted")?.variants)
    #expect(variants[.original]?.status == .failed && variants[.edited]?.status == .failed)
    let summary = try #require(f.manager.progressState.manualSummary)
    #expect(summary.completedCount == 1 && summary.failedCount == 1)
    #expect(summary.message == "0 exported · 1 failed")
  }

  @Test(arguments: [false, true])
  func heldPreparationPreventsPrematureCompletionAndRetainsEarlierJobs(failing: Bool) async throws {
    let f = Fixture()
    let gate = AsyncCheckpoint()
    try await withCleanup {
      f.seed(["first"])
      f.seed(["later"], year: 2027, month: 1)
      f.photos.fetchAssetsCheckpointByYear[2027] = gate
      if failing { f.photos.fetchAssetsErrorByYear[2027] = CocoaError(.fileReadUnknown) }
      f.manager.startExportMonth(year: 2027, month: 1)
      try #require(await reached(gate))
      f.manager.startExportMonth(year: 2026, month: 9)
      let preparations = f.manager.currentPreparationTasks
      // The 2026 preparation can settle while the 2027 one remains physically held.
      let firstCompleted = await observe { f.manager.totalJobsCompleted == 1 }
      try #require(firstCompleted)
      #expect(f.timeline.exportInfo(assetId: "first")?.variants[.original]?.status == .done)
      #expect(f.manager.progressState.manualSummary == nil)
      await gate.releaseAll()
      for task in preparations { await task.value }
      await f.manager.waitForQueueDrained()
      let summary = try #require(f.manager.progressState.manualSummary)
      #expect(summary.completedCount == (failing ? 1 : 2))
      #expect(summary.result == (failing ? .failed : .completed))
      if failing { #expect(summary.failureMessage?.isEmpty == false) }
      f.close()
    } cleanup: {
      await gate.releaseAll()
      await f.manager.waitForQueueDrained()
      f.close()
    }
  }

  @Test func clearPendingReportsIncompleteInsteadOfComplete() async throws {
    let f = Fixture()
    let gate = AsyncCheckpoint()
    try await withCleanup {
      f.seed(["first", "second", "third"])
      f.writer.checkpoint = gate
      f.manager.startExportMonth(year: 2026, month: 9)
      try #require(await reached(gate))
      f.manager.clearPending()
      await gate.releaseAll()
      await f.manager.waitForQueueDrained()
      let summary = try #require(f.manager.progressState.manualSummary)
      #expect(summary.completedCount == 1 && summary.result == .failed)
      #expect(summary.failureMessage?.isEmpty == false)
      f.close()
    } cleanup: {
      await gate.releaseAll()
      await f.manager.waitForQueueDrained()
      f.close()
    }
  }
  @Test func bulkScanFailureStaysIncompleteWhenManualWorkIsAppended() async throws {
    let f = Fixture()
    let scan = AsyncCheckpoint()
    let write = AsyncCheckpoint()
    try await withCleanup {
      f.seed(["first"])
      f.seed(["later"], year: 2027, month: 1)
      f.seed(["appended"], year: 2028, month: 1)
      f.photos.fetchAssetsCheckpointByYear[2027] = scan
      f.photos.fetchAssetsErrorByYear[2027] = CocoaError(.fileReadUnknown)
      f.writer.checkpoint = write
      f.manager.startExportTimelineSelection(years: [2026, 2027], months: [])
      try #require(await reached(scan))
      // Resume can start already queued work while the next scope is still scanning.
      f.manager.pause()
      f.manager.resume()
      try #require(await reached(write))
      #expect(f.manager.progressState.manualSummary == nil)
      await scan.releaseAll()
      for task in f.manager.currentPreparationTasks { await task.value }
      f.manager.startExportMonth(year: 2028, month: 1)
      for task in f.manager.currentPreparationTasks { await task.value }
      f.writer.checkpoint = nil
      await write.releaseAll()
      await f.manager.waitForQueueDrained()
      let summary = try #require(f.manager.progressState.manualSummary)
      #expect(summary.completedCount == 2 && summary.failedCount == 0)
      #expect(summary.result == .failed && summary.failureMessage?.isEmpty == false)
      #expect(f.timeline.exportInfo(assetId: "appended")?.variants[.original]?.status == .done)
      f.close()
    } cleanup: {
      await scan.releaseAll()
      await write.releaseAll()
      await f.manager.waitForQueueDrained()
      f.close()
    }
  }

  @Test(arguments: [1, 2])
  func persistenceFailureRetainsStoppedOutcome(failOnWrite: Int) async throws {
    let io = FailingLogIO(failOn: 1)
    let f = Fixture(logIO: io)
    defer { f.close() }
    if failOnWrite == 2 {
      io.failAfterFileAppears(f.destination.rootURL.appendingPathComponent("2026/09/one.JPG"))
    }
    f.seed(["one"])
    f.manager.startExportMonth(year: 2026, month: 9)
    await f.manager.waitForQueueDrained()
    #expect(f.timeline.state == .persistenceFailed)
    let summary = try #require(f.manager.progressState.manualSummary)
    #expect(summary.result == .failed && summary.failedCount == 1)
    #expect(summary.failureMessage?.contains("progress could not be saved") == true)
    if failOnWrite == 2 {
      #expect(
        FileManager.default.fileExists(
          atPath: f.destination.rootURL
            .appendingPathComponent("2026/09/one.JPG").path))
      #expect(f.timeline.exportInfo(assetId: "one")?.variants[.original]?.status == .done)
    }
  }

  @Test(arguments: [ExportRunSource.manual, .autoSync])
  func awaitableRunKeepsItsExistingSummarySemantics(source: ExportRunSource) async throws {
    let f = Fixture()
    defer { f.close() }
    f.seed(["one", "broken"], missing: ["broken"])
    f.photos.yearCounts = [(2026, 2)]
    let result = await f.manager.runExport(
      context: ExportRunContext(
        source: source, visibility: source == .manual ? .userVisible : .background,
        scope: .timelineFullLibrary, selection: .edited))
    #expect(result.completedCount == 2 && result.failedCount == 1 && result.result == .failed)
    #expect(result.failures.count == 1)
    if source == .manual {
      #expect(f.manager.progressState.manualSummary?.failedCount == 1)
    } else {
      #expect(f.manager.progressState.manualSummary == nil)
    }
  }

  @Test func cancelledLateFailureCannotPolluteReplacementSummary() async throws {
    let f = Fixture()
    let old = AsyncCheckpoint()
    let replacement = AsyncCheckpoint()
    var oldTask: Task<Void, Never>?
    try await withCleanup {
      f.seed(["old"])
      f.seed(["replacement"], year: 2027, month: 1)
      f.writer.checkpoint = old
      f.manager.startExportMonth(year: 2026, month: 9)
      try #require(await reached(old))
      oldTask = f.manager.currentTask
      f.manager.cancelAndClear()
      #expect(f.manager.progressState.manualSummary == nil)
      f.writer.checkpoint = replacement
      f.manager.startExportMonth(year: 2027, month: 1)
      try #require(await reached(replacement))
      f.writer.writeError = CocoaError(.fileReadUnknown)
      await old.releaseAll()
      await oldTask?.value
      #expect(f.manager.progressState.manualSummary == nil)
      #expect(f.manager.totalJobsCompleted == 0)
      f.writer.writeError = nil
      await replacement.releaseAll()
      await f.manager.waitForQueueDrained()
      let summary = try #require(f.manager.progressState.manualSummary)
      #expect(summary.completedCount == 1 && summary.failedCount == 0)
      #expect(summary.result == .completed)
      f.close()
    } cleanup: {
      await old.releaseAll()
      await replacement.releaseAll()
      await oldTask?.value
      await f.manager.waitForQueueDrained()
      f.close()
    }
  }

}
