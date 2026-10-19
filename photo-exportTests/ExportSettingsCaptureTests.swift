import Foundation
import Testing

@testable import Photo_Export

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct ExportSettingsCaptureTests {
  enum Mode: CaseIterable, Sendable {
    case month, year, all, timelineSelection, favorites, collectionsSelection
    case allAlbums, allSharedAlbums, folder, albums, sharedAlbum, album

    static let dispatched: [Mode] = [.month, .year, .favorites, .folder, .sharedAlbum, .album]
    static let overridden: [Mode] = [
      .all, .timelineSelection, .favorites, .allAlbums, .allSharedAlbums,
    ]

    var expected: [String] {
      switch self {
      case .month, .year: ["t1|timeline|2025/01/"]
      case .all, .timelineSelection: ["t1|timeline|2025/01/", "t2|timeline|2026/02/"]
      case .favorites: ["fav|favorites|Collections/Favorites/"]
      case .collectionsSelection:
        [
          "fav|favorites|Collections/Favorites/", "a|album|Collections/Albums/Trips/Inside/",
          "shared|sharedAlbum|Collections/Shared Albums/Shared/",
        ]
      case .allAlbums, .albums:
        ["a|album|Collections/Albums/Trips/Inside/", "b|album|Collections/Albums/Outside/"]
      case .folder, .album: ["a|album|Collections/Albums/Trips/Inside/"]
      case .allSharedAlbums, .sharedAlbum: ["shared|sharedAlbum|Collections/Shared Albums/Shared/"]
      }
    }

    var selection: LibrarySelection {
      switch self {
      case .month: .timelineMonth(year: 2025, month: 1)
      case .year: .timelineYear(year: 2025)
      case .favorites: .favorites
      case .folder: .folder(collectionId: "folder")
      case .sharedAlbum: .sharedAlbum(collectionId: "shared")
      case .album: .album(collectionId: "a")
      default: preconditionFailure("This mode has no single-selection dispatcher route")
      }
    }

    @MainActor
    func start(_ manager: ExportManager, override: ExportVersionSelection? = nil) {
      switch self {
      case .month: manager.startExportMonth(year: 2025, month: 1)
      case .year: manager.startExportYear(year: 2025)
      case .all: manager.startExportAll(selectionOverride: override)
      case .timelineSelection:
        manager.startExportTimelineSelection(
          years: [2025], months: [.init(year: 2026, month: 2)], selectionOverride: override)
      case .favorites: manager.startExportFavorites(selectionOverride: override)
      case .collectionsSelection:
        manager.startExportCollectionsSelection(
          .init(includesFavorites: true, albumIds: ["a"], sharedAlbumIds: ["shared"]))
      case .allAlbums: manager.startExportAllAlbums(selectionOverride: override)
      case .allSharedAlbums: manager.startExportAllSharedAlbums(selectionOverride: override)
      case .folder: manager.startExportFolder(folderId: "folder")
      case .albums: manager.startExportAlbums(collectionIds: ["a", "b", "a"])
      case .sharedAlbum: manager.startExportSharedAlbum(collectionId: "shared")
      case .album: manager.startExportAlbum(collectionId: "a")
      }
    }
  }

  @MainActor
  private final class Fixture {
    let library = FakePhotoLibraryService()
    let destination = FakeExportDestination()
    let writer = FakeAssetResourceWriter()
    let converter = FakeImageConverter()
    let root = TestScratch.directory("ExportSettingsCapture")
    let suite = TestScratch.suiteName("ExportSettingsCapture")
    let timeline: ExportRecordStore
    let collections: CollectionExportRecordStore
    let manager: ExportManager

    init() {
      timeline = ExportRecordStore(baseDirectoryURL: root)
      collections = CollectionExportRecordStore(baseDirectoryURL: root)
      timeline.configure(for: "test")
      collections.configure(for: "test")
      manager = ExportManager(
        photoLibraryService: library, exportDestination: destination,
        exportRecordStore: timeline, collectionExportRecordStore: collections,
        assetResourceWriter: writer, imageConverter: converter, fileSystem: FakeFileSystem(),
        userDefaults: TestScratch.defaults(suiteName: suite))
      manager.queueCoordinator.pause()
      library.yearCounts = [(2025, 1), (2026, 1)]
      library.assetsByYearMonth["2025-1"] = [asset("t1")]
      library.assetsByYearMonth["2026-2"] = [asset("t2", year: 2026, month: 2)]
      library.favoritesAssets = [asset("fav")]
      library.assetsByAlbumLocalId = ["a": [asset("a")], "b": [asset("b")]]
      library.assetsBySharedAlbumLocalId["shared"] = [asset("shared")]
      let inside = PhotoCollectionDescriptor(
        id: "album:a", localIdentifier: "a", title: "Inside", kind: .album,
        pathComponents: ["Trips"], children: [])
      library.collectionTree = [
        PhotoCollectionDescriptor(
          id: "folder:folder", localIdentifier: "folder", title: "Trips", kind: .folder,
          pathComponents: [], children: [inside]),
        PhotoCollectionDescriptor(
          id: "album:b", localIdentifier: "b", title: "Outside", kind: .album,
          pathComponents: [], children: []),
        PhotoCollectionDescriptor(
          id: "shared-album:shared", localIdentifier: "shared", title: "Shared", kind: .sharedAlbum,
          pathComponents: [], children: []),
      ]
    }

    func asset(_ id: String, year: Int = 2025, month: Int = 1) -> AssetDescriptor {
      let date = Calendar.current.date(from: DateComponents(year: year, month: month, day: 15))!
      return TestAssetFactory.makeAsset(
        id: id, creationDate: date, hasAdjustments: true, isLivePhoto: true)
    }

    func setSettings(high: Bool) {
      manager.versionSelection = high ? .editedWithOriginals : .edited
      manager.livePhotosPairedExport = high
      manager.videoLayout = high ? .subfolder : .flat
    }

    func prepared(_ tasks: [Task<Void, Never>]) async {
      #expect(!tasks.isEmpty, "Dispatch must register its preparation synchronously")
      for task in tasks { await task.value }
    }

    func assertJobs(_ expected: [String], high: Bool, selection: ExportVersionSelection? = nil) {
      let jobs = manager.pendingJobs
      #expect(
        jobs.map {
          "\($0.assetLocalIdentifier)|\($0.placement.kind.rawValue)|\($0.placement.relativePath)"
        }.sorted()
          == expected.sorted())
      #expect(
        jobs.allSatisfy { $0.selection == (selection ?? (high ? .editedWithOriginals : .edited)) })
      #expect(jobs.allSatisfy { $0.livePhotosPaired == high })
      #expect(jobs.allSatisfy { $0.videoLayout == (high ? .subfolder : .flat) })
      #expect(manager.isPaused)
      #expect(writer.writeCalls.isEmpty)
    }

    func cleanup() {
      manager.cancelAndClear()
      timeline.flushForTesting()
      collections.flushForTesting()
      try? FileManager.default.removeItem(at: root)
      destination.cleanup()
    }
  }

  @Test(arguments: Mode.allCases, [false, true])
  func everyStartKeepsClickTimeSettings(mode: Mode, high: Bool) async {
    let f = Fixture()
    defer { f.cleanup() }
    f.setSettings(high: high)
    mode.start(f.manager)
    let tasks = f.manager.currentPreparationTasks
    f.setSettings(high: !high)
    await f.prepared(tasks)
    f.assertJobs(mode.expected, high: high)
  }

  @Test(arguments: Mode.dispatched, [false, true])
  func dispatcherKeepsClickTimeSettings(mode: Mode, high: Bool) async {
    let f = Fixture()
    defer { f.cleanup() }
    f.setSettings(high: high)
    f.manager.startExport(selection: mode.selection)
    let tasks = f.manager.currentPreparationTasks
    f.setSettings(high: !high)
    await f.prepared(tasks)
    f.assertJobs(mode.expected, high: high)
  }

  @Test(arguments: Mode.overridden, [false, true])
  func runSelectionOverrideDoesNotMutateToolbar(mode: Mode, high: Bool) async {
    let f = Fixture()
    defer { f.cleanup() }
    f.setSettings(high: high)
    let override: ExportVersionSelection = high ? .edited : .editedWithOriginals
    mode.start(f.manager, override: override)
    let tasks = f.manager.currentPreparationTasks
    #expect(f.manager.versionSelection == (high ? .editedWithOriginals : .edited))
    // Keep selection opposite the override: a deferred toolbar read must fail.
    f.manager.livePhotosPairedExport = !high
    f.manager.videoLayout = high ? .flat : .subfolder
    await f.prepared(tasks)
    #expect(f.manager.versionSelection == (high ? .editedWithOriginals : .edited))
    f.assertJobs(mode.expected, high: high, selection: override)
  }

  @Test(arguments: [Mode.month, .favorites], [false, true])
  func clickTimeSettingsAlsoControlExistingHistoryEligibility(mode: Mode, high: Bool) async {
    let f = Fixture()
    defer { f.cleanup() }
    let id = mode == .month ? "t1" : "fav"
    if mode == .month {
      f.timeline.markVariantExported(
        assetId: id, variant: .edited, year: 2025, month: 1, relPath: "2025/01/",
        filename: "EDITED.JPG", exportedAt: Date())
    } else {
      let placement = ExportPlacement.favorites()
      f.collections.upsertPlacement(placement)
      f.collections.markVariantExported(
        assetId: id, placement: placement, variant: .edited, filename: "EDITED.JPG",
        exportedAt: Date())
    }
    f.setSettings(high: high)
    mode.start(f.manager)
    let tasks = f.manager.currentPreparationTasks
    f.setSettings(high: !high)
    await f.prepared(tasks)
    f.assertJobs(high ? mode.expected : [], high: high)
  }

  @Test(arguments: [Mode.month, .favorites], [false, true])
  func admissionRejectionPreservesMessagesCountersAndPreparation(mode: Mode, importing: Bool) async
  {
    let f = Fixture()
    defer { f.cleanup() }
    if importing {
      f.manager.startImport()
      #expect(f.manager.isImporting)
    } else if mode == .month {
      f.timeline.configure(for: nil)
    } else {
      f.collections.configure(for: nil)
    }
    let importTask = f.manager.importTask
    f.manager.progressState.emptyRunMessage = "Existing empty message"
    f.manager.progressState.queueWarningMessage = "Existing warning"
    f.manager.progressState.totalJobsEnqueued = 9
    f.manager.progressState.totalJobsCompleted = 4
    let generation = f.manager.generation
    mode.start(f.manager)
    #expect(f.manager.currentPreparationTasks.isEmpty)
    #expect(f.manager.pendingJobs.isEmpty)
    #expect(!f.manager.isEnqueueingAll)
    #expect(f.manager.emptyRunMessage == "Existing empty message")
    #expect(f.manager.queueWarningMessage == "Existing warning")
    #expect(f.manager.totalJobsEnqueued == 9)
    #expect(f.manager.totalJobsCompleted == 4)
    #expect(f.manager.generation == generation)
    if importing { f.manager.cancelImport() }
    await importTask?.value
  }

  @Test func busyBulkRejectionPreservesExistingPreparation() async {
    let f = Fixture()
    defer { f.cleanup() }
    f.manager.startExportAll()
    let tasks = f.manager.currentPreparationTasks
    #expect(tasks.count == 1)
    #expect(f.manager.isEnqueueingAll)
    f.manager.progressState.emptyRunMessage = "Existing empty message"
    f.manager.progressState.queueWarningMessage = "Existing warning"
    f.manager.progressState.totalJobsEnqueued = 9
    f.manager.progressState.totalJobsCompleted = 4
    let generation = f.manager.generation
    f.manager.startExportCollectionsSelection(.empty)
    #expect(f.manager.currentPreparationTasks.count == 1)
    #expect(f.manager.emptyRunMessage == "Existing empty message")
    #expect(f.manager.queueWarningMessage == "Existing warning")
    #expect(f.manager.totalJobsEnqueued == 9)
    #expect(f.manager.totalJobsCompleted == 4)
    #expect(f.manager.generation == generation)
    #expect(f.manager.pendingJobs.isEmpty)
    await f.prepared(tasks)
    f.assertJobs(Mode.all.expected, high: false)
  }

  @Test func heicConversionRemainsLiveAfterEnqueue() async {
    let f = Fixture()
    defer { f.cleanup() }
    let asset = TestAssetFactory.makeAsset(id: "heic", originalUTI: "public.heic")
    f.library.assetsByYearMonth["2025-1"] = [asset]
    f.library.resourcesByAssetId["heic"] = [
      TestAssetFactory.makeResource(originalFilename: "IMAGE.HEIC")
    ]
    f.manager.convertHEICToJPEG = false
    f.manager.startExportMonth(year: 2025, month: 1)
    await f.prepared(f.manager.currentPreparationTasks)
    #expect(f.manager.pendingJobs.map(\.assetLocalIdentifier) == ["heic"])
    f.manager.convertHEICToJPEG = true
    f.manager.resume()
    await f.manager.waitForQueueDrained()
    #expect(f.converter.convertCalls.count == 1)
    #expect(f.timeline.exportInfo(assetId: "heic")?.variants[.edited]?.filename == "IMAGE.JPG")
  }
}
