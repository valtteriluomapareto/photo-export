import AVFoundation
import Foundation
import Photos
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
    let root = TestScratch.directory("DestinationFailureStop")
    let suite = TestScratch.suiteName("DestinationStop")
    let photos = FakePhotoLibraryService()
    let destination = FakeExportDestination()
    let writer = FakeAssetResourceWriter()
    let files: FakeFileSystem
    let renderer = FakeMediaRenderer()
    let converter = FakeImageConverter()
    let timeline: ExportRecordStore
    let collections: CollectionExportRecordStore
    let manager: ExportManager
    let collection: Bool
    let ids = (0..<5).map { "asset-\($0)" }
    var placement: ExportPlacement { collection ? .favorites() : .timeline(year: 2026, month: 9) }

    init(
      collection: Bool = false, logIO: any JSONLRecordLogIO = ProductionJSONLRecordLogIO(),
      files: FakeFileSystem = FakeFileSystem()
    ) {
      self.collection = collection
      self.files = files
      timeline = ExportRecordStore(baseDirectoryURL: root, recordLogIO: logIO)
      collections = CollectionExportRecordStore(baseDirectoryURL: root, recordLogIO: logIO)
      timeline.configure(for: "A")
      collections.configure(for: "A")
      manager = ExportManager(
        photoLibraryService: photos, exportDestination: destination,
        exportRecordStore: timeline, collectionExportRecordStore: collections,
        assetResourceWriter: writer, mediaRenderer: renderer, imageConverter: converter,
        fileSystem: files, userDefaults: TestScratch.defaults(suiteName: suite))
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

    func runManualExport() async -> ExportRunSummary {
      await manager.runExport(
        context: .init(
          source: .manual, visibility: .userVisible,
          scope: collection ? .favoritesFull : .timelineFullLibrary, selection: .edited))
    }

    /// Replaces the five photos with ones of the given shape, one resource each.
    func useAssets(
      mediaType: PHAssetMediaType = .image, hasAdjustments: Bool = false,
      originalUTI: String? = nil, resourceType: PHAssetResourceType = .photo,
      ext: String = "JPG"
    ) {
      let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 15))!
      let assets = ids.map {
        TestAssetFactory.makeAsset(
          id: $0, creationDate: date, mediaType: mediaType, hasAdjustments: hasAdjustments,
          originalUTI: originalUTI)
      }
      photos.assetsByYearMonth["2026-9"] = assets
      photos.favoritesAssets = assets
      for id in ids {
        photos.resourcesByAssetId[id] = [
          .init(type: resourceType, originalFilename: "\(id).\(ext)")
        ]
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
      try? FileManager.default.removeItem(at: root)
    }
  }

  static let unavailableMessage =
    "Export stopped: the destination can't be reached. Check that the drive or network share is connected and the folder still exists, then start a new export."
  static let fullMessage =
    "Export stopped: the destination is full. Free up space, then start a new export."
  static let deniedMessage =
    "Export stopped: write access to the destination was denied. Restore access, then start a new export."

  static func category(forCode code: Int) -> AutoSyncFailureCategory {
    switch Int32(code) {
    case ENOSPC: return .destinationNoSpace
    case EACCES, EPERM, EROFS: return .destinationPermission
    default: return .destinationUnavailable
    }
  }

  static func message(for category: AutoSyncFailureCategory) -> String? {
    switch category {
    case .destinationUnavailable: return unavailableMessage
    case .destinationNoSpace: return fullMessage
    case .destinationPermission: return deniedMessage
    default: return nil
    }
  }

  @Test(arguments: [false, true], [Int(ENOSPC), Int(EACCES), Int(ENOTCONN), Int(ETIMEDOUT)])
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
    #expect(
      f.manager.progressState.manualSummary?.failureMessage
        == Self.message(for: Self.category(forCode: code)))
    f.writer.writeError = nil
    f.start()
    await f.manager.waitForQueueDrained()
    #expect(f.writer.writeCalls.count == 6)
    for id in f.ids { #expect(f.variants(id)[.original]?.status == .done) }
    #expect(f.manager.progressState.manualSummary?.result == .completed)
    await f.close()
  }

  @Test(
    arguments: [ExportRunSource.manual, .autoSync],
    [Int(ENOSPC), Int(EACCES), Int(ENOTCONN), Int(ETIMEDOUT)])
  func awaitableRunStopsWithAccurateCounts(source: ExportRunSource, code: Int) async throws {
    let f = Fixture()
    f.writer.writeError = NSError(domain: NSPOSIXErrorDomain, code: code)
    let summary = await f.manager.runExport(
      context: .init(
        source: source, visibility: source == .manual ? .userVisible : .background,
        scope: .timelineFullLibrary, selection: .edited))
    let category = Self.category(forCode: code)
    let unavailable = category == .destinationUnavailable
    #expect(summary.result == (unavailable ? .interrupted : .failed))
    #expect(summary.cancelReason == (unavailable ? .destinationUnavailable : nil))
    #expect(summary.stoppedBy == category)
    #expect(summary.enqueuedCount == 5)
    #expect(summary.completedCount == 1)
    #expect(summary.failedCount == 1)
    #expect(summary.failures.count == 1)
    #expect(summary.failures.first?.category == category)
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
    let summary = await f.runManualExport()
    #expect(f.writer.writeCalls.count == 10)
    #expect(summary.result == .failed && summary.cancelReason == nil)
    #expect(summary.stoppedBy == nil)
    #expect(summary.completedCount == 5 && summary.failures.count == 5)
    await f.close()
  }

  // MARK: - Stop outcome per destination failure

  struct StopCase: Sendable, CustomTestStringConvertible {
    let code: Int32
    let category: AutoSyncFailureCategory
    let testDescription: String
    init(_ code: Int32, _ name: String, _ category: AutoSyncFailureCategory) {
      self.code = code
      self.category = category
      self.testDescription = name
    }
  }

  static let commitStopCases: [StopCase] = [
    StopCase(ENOTCONN, "ENOTCONN", .destinationUnavailable),
    StopCase(ETIMEDOUT, "ETIMEDOUT", .destinationUnavailable),
    StopCase(ESTALE, "ESTALE", .destinationUnavailable),
    StopCase(EHOSTDOWN, "EHOSTDOWN", .destinationUnavailable),
    StopCase(EHOSTUNREACH, "EHOSTUNREACH", .destinationUnavailable),
    StopCase(ENETDOWN, "ENETDOWN", .destinationUnavailable),
    StopCase(ENETUNREACH, "ENETUNREACH", .destinationUnavailable),
    StopCase(ENXIO, "ENXIO", .destinationUnavailable),
    StopCase(ENOSPC, "ENOSPC", .destinationNoSpace),
    StopCase(EACCES, "EACCES", .destinationPermission),
    StopCase(EROFS, "EROFS", .destinationPermission),
  ]

  /// A commit whose exclusive rename fails with `code` for `filename` (every name when nil)
  /// and succeeds otherwise, as the real `FileIOService` reports it.
  static func failingCommit(
    _ code: Int32, filename: String? = nil, while failing: LockedBox<Bool> = LockedBox(true)
  ) -> FakeFileSystem {
    FakeFileSystem(
      real: FileIOService(
        renamer: { source, destination, flags in
          if failing.value, filename == nil || destination.lastPathComponent == filename {
            return code
          }
          return FileIOService.systemRename(source, destination, flags)
        },
        capability: { _ in true }))
  }

  /// A manual export of the five assets stops at the first one: one failure with the
  /// category and signature, the matching result and message, and nothing else touched.
  private func expectStop(
    _ f: Fixture, category: AutoSyncFailureCategory, signature: String
  ) async {
    let summary = await f.runManualExport()
    let unavailable = category == .destinationUnavailable
    #expect(summary.result == (unavailable ? .interrupted : .failed))
    #expect(summary.cancelReason == (unavailable ? .destinationUnavailable : nil))
    #expect(summary.stoppedBy == category)
    #expect(summary.failures.map(\.category) == [category])
    #expect(summary.failures.map(\.errorSignature) == [signature])
    #expect(summary.enqueuedCount == 5 && summary.completedCount == 1)
    #expect(f.manager.progressState.manualSummary?.failureMessage == Self.message(for: category))
    #expect(f.manager.progressState.manualSummary?.completedCount == 1)
    #expect(f.manager.progressState.manualSummary?.failedCount == 1)
    for id in f.ids.dropFirst() { #expect(f.variants(id).isEmpty) }
  }

  @Test(arguments: commitStopCases)
  func commitFailureStopsTheRunWithItsCategory(stop: StopCase) async {
    let f = Fixture(files: Self.failingCommit(stop.code))
    await expectStop(f, category: stop.category, signature: "NSPOSIXErrorDomain:\(stop.code)")
    #expect(f.writer.writeCalls.count == 1)
    #expect(f.variants(f.ids[0])[.original]?.status == .failed)
    await f.close()
  }

  enum StopRoute: String, CaseIterable, Sendable { case directory, render, conversion }

  /// The folder, render and conversion steps each stop on an unreachable destination and
  /// on a hard destination failure. The render and conversion errnos are injected bare; a
  /// real AVFoundation failure arrives as -11800 wrapping the errno, which is not unwrapped
  /// and still becomes edited-unavailable. That is a known limit.
  @Test(arguments: StopRoute.allCases, [true, false])
  func eachProducerRouteStopsTheRun(route: StopRoute, unavailable: Bool) async {
    let f = Fixture(collection: route == .directory)
    let error: Error
    let category: AutoSyncFailureCategory
    switch route {
    case .directory:
      f.useAssets(hasAdjustments: true)
      let cause =
        unavailable
        ? NSError(
          domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
          userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTCONN))]
        )
        : NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
      error = ExportDestinationManager.ExportDestinationError.failedToCreateFolder(
        f.destination.rootURL.appendingPathComponent(f.placement.relativePath), underlying: cause)
      category = unavailable ? .destinationUnavailable : .destinationPermission
      f.destination.urlForRelativeDirectoryError = error
    case .render:
      f.useAssets(mediaType: .video, hasAdjustments: true, resourceType: .video, ext: "MOV")
      error =
        unavailable
        ? NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT))
        : NSError(domain: AVFoundationErrorDomain, code: AVError.Code.diskFull.rawValue)
      category = unavailable ? .destinationUnavailable : .destinationNoSpace
      f.renderer.renderError = error
    case .conversion:
      f.useAssets(originalUTI: "public.heic", ext: "HEIC")
      f.manager.convertHEICToJPEG = true
      error =
        unavailable
        ? NSError(domain: NSPOSIXErrorDomain, code: Int(ENETUNREACH))
        : CocoaError(.fileWriteOutOfSpace)
      category = unavailable ? .destinationUnavailable : .destinationNoSpace
      f.converter.convertError = error
    }
    let bridged = error as NSError
    await expectStop(f, category: category, signature: "\(bridged.domain):\(bridged.code)")
    await f.close()
  }

  enum WriteAccessFailure: String, CaseIterable, Sendable {
    case notWritable, scopeAccessDenied
    var error: ExportDestinationManager.ExportDestinationError {
      switch self {
      case .notWritable: return .notWritable
      case .scopeAccessDenied: return .scopeAccessDenied
      }
    }
  }

  /// A read-only folder or a denied security scope fails every write the same way, so the
  /// destination error stops the run at its first item as a permission failure.
  @Test(arguments: WriteAccessFailure.allCases)
  func destinationWriteAccessErrorStopsTheRun(failure: WriteAccessFailure) async {
    let f = Fixture()
    let error = failure.error
    f.destination.urlForRelativeDirectoryError = error
    let bridged = error as NSError
    await expectStop(
      f, category: .destinationPermission, signature: "\(bridged.domain):\(bridged.code)")
    #expect(f.writer.writeCalls.isEmpty)
    #expect(f.variants(f.ids[0])[.original]?.status == .failed)
    await f.close()
  }

  /// A missing file at the commit can come from the source side, so it fails one item and
  /// the run goes on.
  @Test func missingFileAtTheCommitFailsOneItemAndContinues() async {
    let f = Fixture(files: Self.failingCommit(ENOENT, filename: "asset-0.JPG"))
    let summary = await f.runManualExport()
    #expect(summary.result == .failed && summary.cancelReason == nil)
    #expect(summary.stoppedBy == nil)
    #expect(summary.failures.map(\.category) == [.unknown])
    #expect(summary.failures.map(\.errorSignature) == ["NSPOSIXErrorDomain:\(ENOENT)"])
    #expect(summary.completedCount == 5)
    #expect(f.variants(f.ids[0])[.original]?.status == .failed)
    for id in f.ids.dropFirst() { #expect(f.variants(id)[.original]?.status == .done) }
    #expect(f.manager.progressState.manualSummary?.failureMessage == nil)
    await f.close()
  }

  /// After a stop on an unreachable destination, the next manual export picks up what the
  /// stopped run left: the failed item and the ones it never reached.
  @Test func nextManualExportAfterAnUnavailableStopQueuesWhatTheStopLeft() async {
    let failing = LockedBox(true)
    let f = Fixture(files: Self.failingCommit(ENOTCONN, filename: "asset-1.JPG", while: failing))
    let stopped = await f.runManualExport()
    #expect(stopped.result == .interrupted && stopped.stoppedBy == .destinationUnavailable)
    #expect(f.variants(f.ids[0])[.original]?.status == .done)
    #expect(f.variants(f.ids[1])[.original]?.status == .failed)
    for id in f.ids.dropFirst(2) { #expect(f.variants(id).isEmpty) }

    failing.mutate { $0 = false }
    let next = await f.runManualExport()
    #expect(next.result == .completed)
    #expect(next.enqueuedCount == 4)
    // The first run wrote asset-0 and asset-1; asset-0 is not written again.
    #expect(f.writer.writeCalls.map(\.assetId) == [f.ids[0], f.ids[1]] + f.ids.dropFirst())
    for id in f.ids { #expect(f.variants(id)[.original]?.status == .done) }
    await f.close()
  }

  /// The unmount notification that follows a dropped share must not erase the stop
  /// message while nothing is running.
  @Test func stopMessageSurvivesALaterUnmountWhileIdle() async {
    let f = Fixture(files: Self.failingCommit(ENOTCONN))
    f.start()
    await f.manager.waitForQueueDrained()
    let stopped = f.manager.progressState.manualSummary
    #expect(stopped?.failureMessage == Self.unavailableMessage)
    f.manager.interruptForDestinationUnavailable()
    #expect(f.manager.progressState.manualSummary == stopped)
    await f.close()
  }

  /// Guard: an unmount during an active export clears the feedback, including a summary
  /// that is showing. Starting an export already clears the last summary, and no current
  /// path sets one while work is active, so the summary is placed by hand; the rule that
  /// keeps it only while idle is defensive here.
  @Test(.timeLimit(.minutes(1)))
  func unmountDuringAnActiveExportClearsTheFeedback() async throws {
    let f = Fixture()
    let gate = AsyncCheckpoint()
    f.writer.checkpoint = gate
    f.start()
    var physical: Task<Void, Never>?
    var failure: Error?
    do {
      try #require(await reached(gate))
      physical = f.manager.currentTask
      f.manager.progressState.manualSummary = ManualExportSummary(
        completedCount: 1, failedCount: 1, failureMessage: Self.fullMessage)
      f.manager.interruptForDestinationUnavailable()
      #expect(f.manager.progressState.manualSummary == nil)
      await gate.releaseAll()
      await physical?.value
      #expect(f.manager.progressState.manualSummary == nil)
    } catch { failure = error }
    await gate.releaseAll()
    await physical?.value
    await f.close()
    if let failure { throw failure }
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
    f.photos.assetsByYearMonth["2027-1"] = [
      TestAssetFactory.makeAsset(
        id: "late-scan",
        creationDate: Calendar.current.date(from: DateComponents(year: 2027, month: 1, day: 15))!)
    ]
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
