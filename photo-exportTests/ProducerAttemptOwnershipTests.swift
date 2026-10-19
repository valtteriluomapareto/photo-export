import Foundation
import Photos
import Testing

@testable import Photo_Export

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct ProducerAttemptOwnershipTests {
  enum Producer: CaseIterable { case resource, render, heicSource, heicConversion, fallback }

  @MainActor
  private final class Destination: ExportDestination {
    let root = TestScratch.directory("ProducerAttemptOwnership")
    var selectedFolderURL: URL?
    var canExportNow: Bool { true }
    var canImportNow: Bool { true }
    var opened: [URL] = []
    var closed: [URL] = []

    init() { selectedFolderURL = root.appendingPathComponent("A") }
    func beginScopedAccess() -> URL? {
      if let selectedFolderURL { opened.append(selectedFolderURL) }
      return selectedFolderURL
    }
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
    let producer: Producer
    let collection: Bool
    let destination = Destination()
    let photos = FakePhotoLibraryService()
    let writer = FakeAssetResourceWriter()
    let renderer = FakeMediaRenderer()
    let converter = FakeImageConverter()
    let files = FakeFileSystem()
    let root = TestScratch.directory("ProducerAttemptOwnership")
    let timeline: ExportRecordStore
    let collections: CollectionExportRecordStore
    let manager: ExportManager
    let defaultsName = TestScratch.suiteName("ProducerOwnership")
    let defaults: UserDefaults
    let oldGate = AsyncCheckpoint()
    let targetGate = AsyncCheckpoint()
    let blockerGate = AsyncCheckpoint()
    var physicalTasks: [Task<Void, Never>] = []
    private var cleanedUp = false

    var placement: ExportPlacement { collection ? .favorites() : .timeline(year: 2025, month: 1) }
    var variant: ExportVariant {
      producer == .resource || producer == .fallback ? .original : .edited
    }
    var selection: ExportVersionSelection { .edited }

    init(_ producer: Producer, collection: Bool = false) {
      self.producer = producer
      self.collection = collection
      defaults = TestScratch.defaults(suiteName: defaultsName)
      timeline = ExportRecordStore(baseDirectoryURL: root)
      collections = CollectionExportRecordStore(baseDirectoryURL: root)
      timeline.configure(for: "A")
      collections.configure(for: "A")
      manager = ExportManager(
        photoLibraryService: photos, exportDestination: destination,
        exportRecordStore: timeline, collectionExportRecordStore: collections,
        assetResourceWriter: writer, mediaRenderer: renderer,
        imageConverter: converter, fileSystem: files, userDefaults: defaults)
      manager.versionSelection = selection
      manager.convertHEICToJPEG = producer == .heicSource || producer == .heicConversion
      seed(ids: ["target"])
    }

    func seed(ids: [String], includeEdits: Bool = true) {
      let assets = ids.map {
        TestAssetFactory.makeAsset(
          id: $0,
          creationDate: Calendar.current.date(from: DateComponents(year: 2025, month: 1, day: 15)),
          mediaType: producer == .render ? .video : .image,
          hasAdjustments: includeEdits && (producer == .render || producer == .fallback),
          originalUTI: producer == .heicSource || producer == .heicConversion ? "public.heic" : nil)
      }
      photos.assetsByYearMonth["2025-1"] = assets
      photos.yearCounts = [(2025, assets.count)]
      photos.favoritesAssets = assets
      for asset in assets {
        let ext = producer == .render ? "MOV" : manager.convertHEICToJPEG ? "HEIC" : "JPG"
        photos.resourcesByAssetId[asset.id] = [
          TestAssetFactory.makeResource(
            type: producer == .render ? .video : .photo,
            originalFilename: "\(asset.id).\(ext)")
        ]
      }
    }

    func start() {
      if collection {
        manager.startExportFavorites()
      } else {
        manager.startExportMonth(year: 2025, month: 1)
      }
    }

    func startRun() -> Task<ExportRunSummary, Never> {
      let context = ExportRunContext(
        source: .manual, visibility: .userVisible,
        scope: collection ? .favoritesFull : .timelineFullLibrary,
        selection: selection)
      return Task { await manager.runExport(context: context) }
    }

    func selectB() {
      destination.selectedFolderURL = destination.root.appendingPathComponent("B")
      timeline.configure(for: "B")
      collections.configure(for: "B")
    }

    func variants(_ id: String = "target") -> [ExportVariant: ExportVariantRecord] {
      collection
        ? collections.exportInfo(assetId: id, placement: placement)?.variants ?? [:]
        : timeline.exportInfo(assetId: id)?.variants ?? [:]
    }

    func armBefore(_ gate: AsyncCheckpoint?) {
      switch producer {
      case .resource, .heicSource, .fallback: writer.checkpoint = gate
      case .render: renderer.beforeRenderCheckpoint = gate
      case .heicConversion: converter.beforeConvertCheckpoint = gate
      }
    }

    func armAfter(_ gate: AsyncCheckpoint?) {
      switch producer {
      case .resource, .heicSource, .fallback: writer.afterWriteCheckpoint = gate
      case .render: renderer.afterRenderCheckpoint = gate
      case .heicConversion: converter.afterConvertCheckpoint = gate
      }
    }

    func injectError() {
      switch producer {
      case .resource, .heicSource, .fallback: writer.writeError = CocoaError(.fileReadUnknown)
      case .render: renderer.renderError = CocoaError(.fileReadUnknown)
      case .heicConversion: converter.convertError = CocoaError(.fileReadUnknown)
      }
    }

    func stage() throws -> URL {
      switch producer {
      case .resource, .heicSource, .fallback: return try #require(writer.writeCalls.last?.url)
      case .render: return try #require(renderer.renderCalls.last?.url)
      case .heicConversion: return try #require(converter.convertCalls.last?.destURL)
      }
    }

    func captureTask() throws -> Task<Void, Never> {
      let task = try #require(manager.currentTask)
      physicalTasks.append(task)
      return task
    }

    func assertBalancedScopes() {
      #expect(destination.opened.map(\.path).sorted() == destination.closed.map(\.path).sorted())
    }

    func cleanup() async {
      guard !cleanedUp else { return }
      cleanedUp = true
      manager.cancelAndClear()
      await oldGate.releaseAll()
      await targetGate.releaseAll()
      await blockerGate.releaseAll()
      for task in physicalTasks { await task.value }
      timeline.flushForTesting()
      collections.flushForTesting()
      try? FileManager.default.removeItem(at: destination.root)
      try? FileManager.default.removeItem(at: root)
      defaults.removePersistentDomain(forName: defaultsName)
    }
  }

  private func reached(_ gate: AsyncCheckpoint) async -> Bool {
    await gate.waitForEnter(count: 1)
  }

  @Test(
    .timeLimit(.minutes(1)), arguments: [Producer.resource, .render, .heicSource, .heicConversion],
    [false, true])
  func oldCleanupCannotDeleteReplacementStage(producer: Producer, supersede: Bool) async throws {
    let f = Fixture(producer)
    try await withCleanup {
      f.armAfter(f.oldGate)
      f.start()
      let oldArrived = await reached(f.oldGate)
      try #require(oldArrived)
      let old = try f.captureTask()
      let oldStage = try f.stage()
      try Data("old-attempt".utf8).write(to: oldStage)
      if supersede { f.manager.supersedeForManualRun() } else { f.manager.cancelAndClear() }
      f.armAfter(f.targetGate)
      f.start()
      let replacementArrived = await reached(f.targetGate)
      try #require(replacementArrived)
      let replacement = try f.captureTask()
      let stage = try f.stage()
      let expected = try Data(contentsOf: stage)
      #expect(expected != Data("old-attempt".utf8))
      await f.oldGate.releaseAll()
      await old.value
      #expect(
        (try? Data(contentsOf: stage)) == expected, "A's cleanup must preserve B's staged bytes")
      #expect(f.variants()[f.variant]?.status == .inProgress)
      #expect(f.manager.currentJobAssetId == "target")
      #expect(f.manager.currentJobVariant == f.variant)
      if producer == .heicSource {
        #expect(
          f.converter.convertCalls.isEmpty,
          "A must not start conversion after its source await became stale")
      }
      await f.targetGate.releaseAll()
      await replacement.value
      let info = try #require(f.variants()[f.variant])
      #expect(info.status == .done)
      let directory = try f.destination.urlForRelativeDirectory(
        f.placement.relativePath, createIfNeeded: false)
      let filename = try #require(info.filename)
      #expect(filename == (producer == .render ? "target.MOV" : "target.JPG"))
      let final = directory.appendingPathComponent(filename)
      let bytes = try? Data(contentsOf: final)
      if producer == .heicSource {
        #expect(bytes == Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data("FAKE-JPEG-CONTENT".utf8))
      } else {
        #expect(bytes == expected)
      }
      #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [filename])
      f.assertBalancedScopes()
      await f.cleanup()
    } cleanup: {
      await f.cleanup()
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: Producer.allCases, [false, true])
  func staleErrorCannotDowngradeDoneOrContaminateActiveRun(producer: Producer, collection: Bool)
    async throws
  {
    let f = Fixture(producer, collection: collection)
    try await withCleanup {
      f.armBefore(f.oldGate)
      f.start()
      let oldArrived = await reached(f.oldGate)
      try #require(oldArrived)
      let old = try f.captureTask()
      f.manager.supersedeForManualRun()
      f.selectB()
      f.armBefore(nil)
      f.armAfter(f.targetGate)
      f.seed(ids: ["target", "blocker"], includeEdits: producer != .fallback)
      let run = f.startRun()
      let targetArrived = await reached(f.targetGate)
      try #require(targetArrived)
      f.armAfter(f.blockerGate)
      await f.targetGate.releaseAll()
      let blockerArrived = await reached(f.blockerGate)
      try #require(blockerArrived)
      let replacement = try f.captureTask()
      let before = f.variants()
      #expect(before[f.variant]?.status == .done)
      #expect(f.variants("blocker")[f.variant]?.status == .inProgress)
      #expect(f.manager.activeRunContext != nil)
      f.injectError()
      await f.oldGate.releaseAll()
      await old.value
      #expect(f.variants() == before, "A's late error cannot downgrade B's committed variant")
      #expect(f.variants("blocker")[f.variant]?.status == .inProgress)
      await f.blockerGate.releaseAll()
      await replacement.value
      let summary = await run.value
      #expect(summary.result == .completed)
      #expect(summary.enqueuedCount == 2 && summary.completedCount == 2)
      #expect(summary.failedCount == 0 && summary.failures.isEmpty)
      f.assertBalancedScopes()
      try await f.timeline.flush()
      try await f.collections.flush()
      let reopenedTimeline = ExportRecordStore(baseDirectoryURL: f.root)
      let reopenedCollections = CollectionExportRecordStore(baseDirectoryURL: f.root)
      reopenedTimeline.configure(for: "B")
      reopenedCollections.configure(for: "B")
      let reopened =
        collection
        ? reopenedCollections.exportInfo(assetId: "target", placement: f.placement)?.variants
        : reopenedTimeline.exportInfo(assetId: "target")?.variants
      let persisted = try #require(reopened)
      #expect(Set(persisted.keys) == Set(before.keys))
      for (variant, expected) in before {
        var actual = try #require(persisted[variant])
        // JSONL's ISO8601 dates preserve seconds, not subsecond clock precision.
        if let loadedDate = actual.exportDate, let expectedDate = expected.exportDate {
          #expect(abs(loadedDate.timeIntervalSince(expectedDate)) < 1)
        } else {
          #expect(actual.exportDate == expected.exportDate)
        }
        actual.exportDate = expected.exportDate
        #expect(actual == expected)
      }
      reopenedTimeline.flushForTesting()
      reopenedCollections.flushForTesting()
      await f.cleanup()
    } cleanup: {
      await f.cleanup()
    }
  }

  @Test(
    .timeLimit(.minutes(1)), arguments: [Producer.resource, .render, .heicSource, .heicConversion])
  func cancelledProducerErrorDoesNotCreateFailure(producer: Producer) async throws {
    let f = Fixture(producer)
    try await withCleanup {
      f.armBefore(f.oldGate)
      f.start()
      let arrived = await reached(f.oldGate)
      try #require(arrived)
      let old = try f.captureTask()
      f.manager.cancelAndClear()
      f.injectError()
      await f.oldGate.releaseAll()
      await old.value
      #expect(f.variants().isEmpty)
      #expect(f.manager.totalJobsCompleted == 0)
      f.assertBalancedScopes()
      await f.cleanup()
    } cleanup: {
      await f.cleanup()
    }
  }
}
