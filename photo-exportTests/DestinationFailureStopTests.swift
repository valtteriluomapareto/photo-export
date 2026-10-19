import AVFoundation
import Foundation
import Testing

@testable import Photo_Export

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct DestinationFailureStopTests {
  enum Route: CaseIterable { case render, conversion, copy, move, fallback, directory }

  private final class FailingLogIO: JSONLRecordLogIO, @unchecked Sendable {
    private let lock = NSLock()
    private var writes = 0
    private let real = ProductionJSONLRecordLogIO()
    func readIfPresent(at url: URL) throws -> Data? { try real.readIfPresent(at: url) }
    func openForAppending(at url: URL) throws -> FileHandle { try real.openForAppending(at: url) }
    func write(_ data: Data, to handle: FileHandle) throws {
      let fail = lock.withLock {
        writes += 1
        return writes == 2
      }
      if fail { throw CocoaError(.fileWriteOutOfSpace) }
      try real.write(data, to: handle)
    }
    func synchronize(_ handle: FileHandle) throws { try real.synchronize(handle) }
  }

  private func reached(_ gate: AsyncCheckpoint) async -> Bool {
    await gate.waitForEnter(count: 1)
  }
  @MainActor
  private final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "DestinationStop-\(UUID().uuidString)"
    let photos = FakePhotoLibraryService()
    let destination = FakeExportDestination()
    let writer = FakeAssetResourceWriter()
    let files = FakeFileSystem()
    let renderer = FakeMediaRenderer()
    let converter = FakeImageConverter()
    let timeline: ExportRecordStore
    let collections: CollectionExportRecordStore
    let manager: ExportManager
    let collection: Bool
    let ids = (0..<5).map { "asset-\($0)" }
    var placement: ExportPlacement { collection ? .favorites() : .timeline(year: 2026, month: 9) }

    init(collection: Bool = false, logIO: any JSONLRecordLogIO = ProductionJSONLRecordLogIO()) {
      self.collection = collection
      timeline = ExportRecordStore(baseDirectoryURL: root, recordLogIO: logIO)
      collections = CollectionExportRecordStore(baseDirectoryURL: root, recordLogIO: logIO)
      timeline.configure(for: "A")
      collections.configure(for: "A")
      manager = ExportManager(
        photoLibraryService: photos, exportDestination: destination,
        exportRecordStore: timeline, collectionExportRecordStore: collections,
        assetResourceWriter: writer, mediaRenderer: renderer, imageConverter: converter,
        fileSystem: files, userDefaults: UserDefaults(suiteName: suite)!)
      let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 15))!
      let assets = ids.map { TestAssetFactory.makeAsset(id: $0, creationDate: date) }
      photos.assetsByYearMonth["2026-9"] = assets
      photos.favoritesAssets = assets
      photos.yearCounts = [(2026, assets.count)]
      for id in ids {
        photos.resourcesByAssetId[id] = [.init(type: .photo, originalFilename: "\(id).JPG")]
      }
    }

    func start() {
      if collection {
        manager.startExportFavorites()
      } else {
        manager.startExportMonth(year: 2026, month: 9)
      }
    }

    func variants(_ id: String) -> [ExportVariant: ExportVariantRecord] {
      if collection {
        return collections.exportInfo(assetId: id, placement: placement)?.variants ?? [:]
      }
      return timeline.exportInfo(assetId: id)?.variants ?? [:]
    }

    func reloadVariants(_ id: String) async throws -> [ExportVariant: ExportVariantRecord] {
      try await timeline.flush()
      try await collections.flush()
      if collection {
        let fresh = CollectionExportRecordStore(baseDirectoryURL: root)
        fresh.configure(for: "A")
        return fresh.exportInfo(assetId: id, placement: placement)?.variants ?? [:]
      }
      let fresh = ExportRecordStore(baseDirectoryURL: root)
      fresh.configure(for: "A")
      return fresh.exportInfo(assetId: id)?.variants ?? [:]
    }

    func close() async {
      let physical = manager.currentTask
      manager.cancelAndClear()
      await physical?.value
      try? await timeline.flush()
      try? await collections.flush()
      destination.cleanup()
      UserDefaults.standard.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
  }

  @Test(arguments: [false, true], [Int(ENOSPC), Int(EACCES)])
  func manualFailureStopsBeforeOtherAssetsAndExplicitRetryWorks(collection: Bool, code: Int)
    async throws
  {
    let f = Fixture(collection: collection)
    f.writer.writeError = NSError(domain: NSPOSIXErrorDomain, code: code)
    f.start()
    await f.manager.waitForQueueDrained()
    #expect(f.writer.writeCalls.count == 1)
    #expect(try await f.reloadVariants(f.ids[0])[.original]?.status == .failed)
    for id in f.ids.dropFirst() { #expect(f.variants(id).isEmpty) }
    #expect(f.manager.progressState.manualSummary?.completedCount == 1)
    #expect(f.manager.progressState.manualSummary?.failedCount == 1)
    let message = f.manager.progressState.manualSummary?.failureMessage?.lowercased()
    #expect(message?.contains(code == Int(ENOSPC) ? "full" : "access") == true)
    f.writer.writeError = nil
    f.start()
    await f.manager.waitForQueueDrained()
    #expect(f.writer.writeCalls.count == 6)
    for id in f.ids { #expect(f.variants(id)[.original]?.status == .done) }
    #expect(f.manager.progressState.manualSummary?.result == .completed)
    await f.close()
  }

  @Test(arguments: [ExportRunSource.manual, .autoSync], [Int(ENOSPC), Int(EACCES)])
  func awaitableRunStopsWithAccurateCounts(source: ExportRunSource, code: Int) async throws {
    let f = Fixture()
    f.writer.writeError = NSError(domain: NSPOSIXErrorDomain, code: code)
    let summary = await f.manager.runExport(
      context: .init(
        source: source, visibility: source == .manual ? .userVisible : .background,
        scope: .timelineFullLibrary, selection: .edited))
    #expect(summary.result == .failed)
    #expect(summary.enqueuedCount == 5)
    #expect(summary.completedCount == 1)
    #expect(summary.failedCount == 1)
    #expect(summary.failures.count == 1)
    #expect(
      summary.failures.first?.category
        == (code == Int(ENOSPC) ? .destinationNoSpace : .destinationPermission))
    #expect(f.writer.writeCalls.count == 1)
    for id in f.ids.dropFirst() { #expect(f.variants(id).isEmpty) }
    await f.close()
  }

  @Test(arguments: Route.allCases)
  func destinationFailureStopsEachByteAndDirectoryRoute(route: Route) async throws {
    let f = Fixture(collection: route == .directory)
    let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 15))!
    switch route {
    case .render, .conversion, .fallback, .directory:
      let assets = f.ids.map {
        TestAssetFactory.makeAsset(
          id: $0, creationDate: date, mediaType: route == .render ? .video : .image,
          hasAdjustments: route != .conversion,
          originalUTI: route == .conversion ? "public.heic" : nil)
      }
      f.photos.assetsByYearMonth["2026-9"] = assets
      f.photos.favoritesAssets = assets
      for id in f.ids {
        f.photos.resourcesByAssetId[id] = [
          .init(
            type: route == .render ? .video : .photo,
            originalFilename:
              "\(id).\(route == .render ? "MOV" : route == .conversion ? "HEIC" : "JPG")")
        ]
      }
      if route == .render {
        f.renderer.renderError = NSError(
          domain: AVFoundationErrorDomain, code: AVError.Code.diskFull.rawValue)
      } else if route == .conversion {
        f.manager.convertHEICToJPEG = true
        f.converter.convertError = CocoaError(.fileWriteOutOfSpace)
      } else if route == .fallback {
        f.writer.writeError = CocoaError(.fileWriteOutOfSpace)
      } else {
        f.destination.urlForRelativeDirectoryError = CocoaError(.fileWriteNoPermission)
      }
    case .copy:
      let source = ExportPlacement.favorites()
      f.collections.upsertPlacement(source)
      f.collections.markVariantExported(
        assetId: f.ids[0], placement: source, variant: .original,
        filename: "source.JPG", exportedAt: date)
      let directory = try f.destination.urlForRelativeDirectory(
        source.relativePath, createIfNeeded: true)
      try Data("source".utf8).write(to: directory.appendingPathComponent("source.JPG"))
      f.files.copyError = CocoaError(.fileWriteNoPermission)
    case .move:
      f.files.moveError = CocoaError(.fileWriteOutOfSpace)
    }
    f.start()
    await f.manager.waitForQueueDrained()
    #expect(f.manager.progressState.manualSummary?.completedCount == 1)
    #expect(f.manager.progressState.manualSummary?.failedCount == 1)
    let message = f.manager.progressState.manualSummary?.failureMessage?.lowercased()
    #expect(message?.contains(route == .copy || route == .directory ? "access" : "full") == true)
    for id in f.ids.dropFirst() { #expect(f.variants(id).isEmpty) }
    let failed = f.variants(f.ids[0]).values.filter { $0.status == .failed }
    #expect(failed.count == (route == .fallback ? 2 : 1))
    switch route {
    case .render:
      #expect(f.renderer.renderCalls.count == 1)
      #expect(f.writer.writeCalls.isEmpty)
      #expect(f.variants(f.ids[0])[.original] == nil)
    case .conversion:
      #expect(f.converter.convertCalls.count == 1)
      #expect(f.writer.writeCalls.count == 1)
      #expect(f.variants(f.ids[0])[.original] == nil)
    case .copy:
      #expect(f.files.copyCalls.count == 1 && f.writer.writeCalls.isEmpty)
    case .move:
      #expect(f.files.moveCalls.count == 1 && f.writer.writeCalls.count == 1)
    case .fallback:
      #expect(f.writer.writeCalls.count == 1)
    case .directory:
      #expect(f.writer.writeCalls.isEmpty)
      #expect(f.variants(f.ids[0])[.original] == nil)
      #expect(f.variants(f.ids[0])[.edited]?.status == .failed)
    }
    await f.close()
  }

  @Test(.timeLimit(.minutes(1)))
  func successfulPredecessorAndStoppedMultivariantJobKeepCounts() async throws {
    let f = Fixture()
    let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 15))!
    f.photos.assetsByYearMonth["2026-9"] = f.ids.enumerated().map {
      TestAssetFactory.makeAsset(id: $0.element, creationDate: date, hasAdjustments: $0.offset == 1)
    }
    f.photos.resourcesByAssetId[f.ids[1]]?.append(
      .init(type: .fullSizePhoto, originalFilename: "EDIT.JPG"))
    let gate = AsyncCheckpoint()
    f.writer.afterWriteCheckpoint = gate
    let operation = Task {
      await f.manager.runExport(
        context: .init(
          source: .manual, visibility: .userVisible, scope: .timelineFullLibrary,
          selection: .editedWithOriginals))
    }
    var physical: Task<Void, Never>?
    var failure: Error?
    do {
      try #require(await reached(gate))
      physical = f.manager.currentTask
      f.writer.writeError = CocoaError(.fileWriteOutOfSpace)
      await gate.releaseAll()
      let summary = await operation.value
      #expect(summary.enqueuedCount == 5 && summary.completedCount == 2)
      #expect(summary.failedCount == 1 && summary.failures.count == 1)
      #expect(f.variants(f.ids[0])[.original]?.status == .done)
      #expect(f.variants(f.ids[1])[.original]?.status == .failed)
      #expect(f.variants(f.ids[1])[.edited] == nil)
      for id in f.ids.dropFirst(2) { #expect(f.variants(id).isEmpty) }
      #expect(f.writer.writeCalls.count == 2)
      #expect(f.manager.progressState.manualSummary?.completedCount == 2)
      #expect(f.manager.progressState.manualSummary?.failedCount == 1)
    } catch { failure = error }
    let current = f.manager.currentTask
    f.manager.cancelAndClear()
    await gate.releaseAll()
    await physical?.value
    await current?.value
    _ = await operation.value
    await f.close()
    if let failure { throw failure }
  }

  @Test func fallbackCountsTwoVariantFailuresAsOneFailedManualJob() async throws {
    let f = Fixture()
    let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 15))!
    f.photos.assetsByYearMonth["2026-9"] = f.ids.map {
      TestAssetFactory.makeAsset(id: $0, creationDate: date, hasAdjustments: true)
    }
    f.writer.writeError = CocoaError(.fileWriteOutOfSpace)
    let summary = await f.manager.runExport(
      context: .init(
        source: .manual, visibility: .userVisible, scope: .timelineFullLibrary, selection: .edited))
    #expect(summary.completedCount == 1 && summary.failedCount == 2)
    #expect(Set(summary.failures.map(\.variant)) == [.original, .edited])
    #expect(f.manager.progressState.manualSummary?.completedCount == 1)
    #expect(f.manager.progressState.manualSummary?.failedCount == 1)
    #expect(f.writer.writeCalls.count == 1)
    await f.close()
  }

  @Test func ordinaryResourceErrorsStillContinue() async throws {
    let f = Fixture()
    let generation = f.manager.generation
    f.writer.writeError = NSError(domain: "ResourceTest", code: 99)
    f.start()
    await f.manager.waitForQueueDrained()
    #expect(f.writer.writeCalls.count == 5)
    #expect(f.manager.generation == generation)
    #expect(f.manager.progressState.manualSummary?.completedCount == 5)
    #expect(f.manager.progressState.manualSummary?.failureMessage == nil)
    await f.close()
  }

  @Test func historyFailureTakesPrecedenceOverDestinationFailure() async throws {
    let f = Fixture(logIO: FailingLogIO())
    f.writer.writeError = CocoaError(.fileWriteOutOfSpace)
    let summary = await f.manager.runExport(
      context: .init(
        source: .manual, visibility: .userVisible, scope: .timelineFullLibrary, selection: .edited))
    #expect(f.timeline.state == .persistenceFailed)
    #expect(
      f.manager.progressState.manualSummary?.failureMessage?.contains("progress could not be saved")
        == true)
    #expect(summary.enqueuedCount == 5 && summary.completedCount == 1)
    #expect(summary.failedCount == 1 && summary.failures.count == 1)
    #expect(f.writer.writeCalls.count == 1)
    for id in f.ids.dropFirst() { #expect(f.variants(id).isEmpty) }
    await f.close()
  }

  @Test(.timeLimit(.minutes(1)))
  func staleHardRendererFailureCannotStopReplacement() async throws {
    let f = Fixture()
    let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 15))!
    f.photos.assetsByYearMonth["2026-9"] = f.ids.map {
      TestAssetFactory.makeAsset(
        id: $0, creationDate: date, mediaType: .video, hasAdjustments: true)
    }
    for id in f.ids {
      f.photos.resourcesByAssetId[id] = [.init(type: .video, originalFilename: "\(id).MOV")]
    }
    let render = AsyncCheckpoint()
    let replacement = AsyncCheckpoint()
    f.renderer.beforeRenderCheckpoint = render
    f.renderer.renderError = CocoaError(.fileWriteOutOfSpace)
    f.start()
    var old: Task<Void, Never>?
    var newer: Task<Void, Never>?
    var failure: Error?
    do {
      try #require(await reached(render))
      old = f.manager.currentTask
      f.manager.cancelAndClear()
      f.photos.assetsByYearMonth["2026-9"] = [
        TestAssetFactory.makeAsset(id: "replacement", creationDate: date)
      ]
      f.photos.resourcesByAssetId["replacement"] = [
        .init(type: .photo, originalFilename: "REPLACEMENT.JPG")
      ]
      f.writer.checkpoint = replacement
      f.start()
      try #require(await reached(replacement))
      newer = f.manager.currentTask
      let generation = f.manager.generation
      await render.releaseAll()
      await old?.value
      #expect(f.manager.generation == generation && f.manager.isRunning)
      #expect(f.manager.progressState.manualSummary == nil)
      #expect(f.variants("replacement")[.original]?.status == .inProgress)
      for id in f.ids { #expect(f.variants(id).isEmpty) }
      await replacement.releaseAll()
      await newer?.value
      #expect(f.variants("replacement")[.original]?.status == .done)
      #expect(f.manager.progressState.manualSummary?.result == .completed)
    } catch { failure = error }
    let current = f.manager.currentTask
    f.manager.cancelAndClear()
    await render.releaseAll()
    await replacement.releaseAll()
    await old?.value
    await newer?.value
    await current?.value
    await f.close()
    if let failure { throw failure }
  }

  @Test(.timeLimit(.minutes(1)))
  func destinationStopInvalidatesConcurrentPreparation() async throws {
    let f = Fixture()
    let scan = AsyncCheckpoint()
    f.photos.fetchAssetsCheckpointByYear[2027] = scan
    f.photos.assetsByYearMonth["2027-1"] = [TestAssetFactory.makeAsset(id: "late-scan")]
    f.photos.resourcesByAssetId["late-scan"] = [.init(type: .photo, originalFilename: "LATE.JPG")]
    f.writer.writeError = CocoaError(.fileWriteOutOfSpace)
    f.manager.startExportYear(year: 2027)
    var preparations: [Task<Void, Never>] = []
    var failure: Error?
    do {
      try #require(await reached(scan))
      preparations = f.manager.currentPreparationTasks
      let generation = f.manager.generation
      f.start()
      _ = await eventually("destination stop advances the generation") {
        f.manager.generation != generation
      }
      try #require(f.manager.generation != generation)
      #expect(f.manager.currentPreparationTasks.isEmpty)
      await scan.releaseAll()
      for task in preparations { await task.value }
      #expect(f.writer.writeCalls.count == 1)
      #expect(f.variants("late-scan").isEmpty)
      #expect(f.manager.pendingJobs.isEmpty && !f.manager.isRunning)
    } catch { failure = error }
    let physical = f.manager.currentTask
    f.manager.cancelAndClear()
    await scan.releaseAll()
    for task in preparations { await task.value }
    await physical?.value
    await f.close()
    if let failure { throw failure }
  }

  @Test func autoSyncDirectoryFailurePreservesBlockedOriginal() async throws {
    let f = Fixture(collection: true)
    let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 15))!
    f.photos.favoritesAssets = [
      TestAssetFactory.makeAsset(id: f.ids[0], creationDate: date, hasAdjustments: true)
    ]
    f.photos.assetsByYearMonth["2026-9"] = f.photos.favoritesAssets
    f.collections.upsertPlacement(f.placement)
    f.collections.markVariantFailed(
      assetId: f.ids[0], placement: f.placement, variant: .original,
      error: "Original is blocked pending user action", at: date)
    let before = f.variants(f.ids[0])[.original]
    f.manager.autoSyncEligibilityCheck = { _, _, variant, _ in variant == .edited }
    f.destination.urlForRelativeDirectoryError = CocoaError(.fileWriteNoPermission)
    let summary = await f.manager.runExport(
      context: .init(
        source: .autoSync, visibility: .background, scope: .favoritesFull,
        selection: .editedWithOriginals))
    #expect(summary.result == .failed)
    #expect(summary.failures.count == 1)
    #expect(summary.failures.first?.variant == .edited)
    #expect(f.variants(f.ids[0])[.original] == before)
    #expect(f.variants(f.ids[0])[.edited]?.status == .failed)
    #expect(f.writer.writeCalls.isEmpty)
    await f.close()
  }

  @Test(.timeLimit(.minutes(1)))
  func newlyBlockedAutoSyncJobsSkipBeforeDestinationAccess() async throws {
    let f = Fixture()
    var eligible = true
    f.manager.autoSyncEligibilityCheck = { _, _, _, _ in eligible }
    let gate = AsyncCheckpoint()
    f.writer.afterWriteCheckpoint = gate
    let operation = Task {
      await f.manager.runExport(
        context: .init(
          source: .autoSync, visibility: .background, scope: .timelineFullLibrary,
          selection: .edited))
    }
    var physical: Task<Void, Never>?
    var failure: Error?
    do {
      try #require(await reached(gate))
      physical = f.manager.currentTask
      eligible = false
      f.destination.urlForRelativeDirectoryError = CocoaError(.fileWriteNoPermission)
      await gate.releaseAll()
      let summary = await operation.value
      #expect(summary.result == .completed)
      #expect(summary.skippedCount == 4)
      #expect(summary.failedCount == 0 && summary.failures.isEmpty)
      #expect(f.variants(f.ids[0])[.original]?.status == .done)
      for id in f.ids.dropFirst() { #expect(f.variants(id).isEmpty) }
      #expect(f.writer.writeCalls.count == 1)
    } catch { failure = error }
    let current = f.manager.currentTask
    f.manager.cancelAndClear()
    await gate.releaseAll()
    await physical?.value
    await current?.value
    _ = await operation.value
    await f.close()
    if let failure { throw failure }
  }

  @Test func directoryFailurePreservesDoneOriginalAndFailsOnlyMissingVersion() async throws {
    let f = Fixture(collection: true)
    let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 15))!
    f.photos.favoritesAssets = f.ids.enumerated().map {
      TestAssetFactory.makeAsset(id: $0.element, creationDate: date, hasAdjustments: $0.offset == 0)
    }
    f.photos.assetsByYearMonth["2026-9"] = f.photos.favoritesAssets
    f.photos.resourcesByAssetId[f.ids[0]]?.append(
      .init(type: .fullSizePhoto, originalFilename: "EDIT.JPG"))
    f.manager.versionSelection = .editedWithOriginals
    f.collections.upsertPlacement(f.placement)
    f.collections.markVariantExported(
      assetId: f.ids[0], placement: f.placement, variant: .original,
      filename: "ORIGINAL_orig.JPG", exportedAt: date)
    let before = f.variants(f.ids[0])[.original]
    let directory = try f.destination.urlForRelativeDirectory(
      f.placement.relativePath, createIfNeeded: true)
    let original = directory.appendingPathComponent("ORIGINAL_orig.JPG")
    try Data("original".utf8).write(to: original)
    f.destination.urlForRelativeDirectoryError = CocoaError(.fileWriteNoPermission)
    f.start()
    await f.manager.waitForQueueDrained()
    #expect(f.variants(f.ids[0])[.original] == before)
    #expect(f.variants(f.ids[0])[.edited]?.status == .failed)
    #expect(try Data(contentsOf: original) == Data("original".utf8))
    #expect(f.writer.writeCalls.isEmpty)
    for id in f.ids.dropFirst() { #expect(f.variants(id).isEmpty) }
    await f.close()
  }
}
