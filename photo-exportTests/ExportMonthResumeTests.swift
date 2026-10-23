import Foundation
import Testing

@testable import Photo_Export

@MainActor
struct ExportMonthResumeTests {
  @MainActor
  private final class Fixture {
    let root = TestScratch.directory("ExportMonthResume")
    let suite = TestScratch.suiteName("ExportMonthResume")
    let library = FakePhotoLibraryService()
    let destination = FakeExportDestination()
    let writer = FakeAssetResourceWriter()
    let fileSystem = FakeFileSystem()
    let gate = AsyncCheckpoint()
    let store: ExportRecordStore
    let collections: CollectionExportRecordStore
    let manager: ExportManager
    var tasks: [Task<Void, Never>] = []

    init() {
      store = ExportRecordStore(baseDirectoryURL: root)
      collections = CollectionExportRecordStore(baseDirectoryURL: root)
      store.configure(for: "test")
      collections.configure(for: "test")
      writer.checkpoint = gate
      manager = ExportManager(
        photoLibraryService: library, exportDestination: destination,
        exportRecordStore: store, collectionExportRecordStore: collections,
        assetResourceWriter: writer, fileSystem: fileSystem,
        userDefaults: TestScratch.defaults(suiteName: suite))
    }

    func add(_ id: String, month: Int = 1, edited: Bool = false) {
      let date = Calendar.current.date(from: DateComponents(year: 2025, month: month, day: 15))!
      library.assetsByYearMonth["2025-\(month)", default: []].append(
        TestAssetFactory.makeAsset(id: id, creationDate: date, hasAdjustments: edited))
      var resources = [TestAssetFactory.makeResource(type: .photo, originalFilename: "\(id).JPG")]
      if edited {
        resources.append(
          TestAssetFactory.makeResource(type: .fullSizePhoto, originalFilename: "\(id).JPG"))
      }
      library.resourcesByAssetId[id] = resources
    }

    func prepared() async {
      let preparations = manager.currentPreparationTasks
      tasks += preparations
      for task in preparations { await task.value }
    }

    func captureCurrentTask() throws -> Task<Void, Never> {
      let task = try #require(manager.currentTask)
      tasks.append(task)
      return task
    }

    func cleanup() async {
      tasks += manager.currentPreparationTasks
      if let task = manager.currentTask { tasks.append(task) }
      if let task = manager.importTask { tasks.append(task) }
      manager.cancelImport()
      manager.cancelAndClear()
      await gate.releaseAll()
      for task in tasks { await task.value }
      try? await store.flush()
      try? await collections.flush()
      destination.cleanup()
      try? FileManager.default.removeItem(at: root)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func parkedMonthResumesOriginalMixedQueueWithoutRescanning() async throws {
    let f = Fixture()
    do {
      f.add("done")
      f.add("first")
      f.add("second", edited: true)
      f.add("other", month: 2)
      f.store.markVariantExported(
        assetId: "done", variant: .original, year: 2025, month: 1,
        relPath: "2025/01/", filename: "done.JPG", exportedAt: Date())
      let history = f.store.exportInfo(assetId: "done")
      f.manager.versionSelection = .editedWithOriginals
      f.manager.livePhotosPairedExport = true
      f.manager.videoLayout = .subfolder
      let originalSettings = ExportSettingsSnapshot(manager: f.manager)
      f.manager.startExportMonth(year: 2025, month: 1)
      await f.prepared()
      let firstStarted = await f.gate.waitForEnter(count: 1)
      try #require(firstStarted)
      let first = try f.captureCurrentTask()
      f.manager.queueCoordinator.enqueue([
        .init(
          assetLocalIdentifier: "other", placement: .timeline(year: 2025, month: 2),
          settings: originalSettings)
      ])
      f.manager.pause()
      await f.gate.release()
      await first.value
      let parked = f.manager.isPaused && !f.manager.isProcessing && !f.manager.isRunning
      try #require(parked)
      #expect(f.manager.totalJobsCompleted == 1)
      #expect(f.manager.pendingJobs.map(\.assetLocalIdentifier) == ["second", "other"])
      let completed = f.store.exportInfo(assetId: "first")
      let file = try f.destination.urlForMonth(year: 2025, month: 1, createIfNeeded: false)
        .appendingPathComponent("first.JPG")
      let bytes = try Data(contentsOf: file)
      let generation = f.manager.generation
      let scans = f.library.fetchAssetsCalls.count
      let enqueued = f.manager.totalJobsEnqueued
      f.manager.versionSelection = .edited
      f.manager.livePhotosPairedExport = false
      f.manager.videoLayout = .flat
      f.manager.progressState.queueWarningMessage = "Keep the warning for this queue"

      f.manager.startExportMonth(year: 2025, month: 1)

      let resumed = !f.manager.isPaused
      #expect(resumed)
      #expect(f.manager.currentPreparationTasks.isEmpty)
      #expect(f.manager.generation == generation)
      #expect(f.manager.totalJobsEnqueued == enqueued)
      #expect(f.manager.totalJobsCompleted == 1)
      #expect(f.manager.progressState.queueWarningMessage == "Keep the warning for this queue")
      #expect(f.manager.pendingJobs.allSatisfy { $0.settings == originalSettings })
      try #require(resumed)
      let secondStarted = await f.gate.waitForEnter(count: 2)
      try #require(secondStarted)
      _ = try f.captureCurrentTask()
      #expect(f.library.fetchAssetsCalls.count == scans)
      await f.gate.releaseAll()
      await f.manager.waitForQueueDrained()
      #expect(f.writer.writeCalls.map(\.assetId) == ["first", "second", "second", "other"])
      #expect(f.fileSystem.moveCalls.count == 4)
      #expect(Set(f.fileSystem.moveCalls.map { $0.to.path }).count == 4)
      #expect(f.store.exportInfo(assetId: "done") == history)
      #expect(f.store.exportInfo(assetId: "first") == completed)
      #expect(try Data(contentsOf: file) == bytes)
      #expect(f.store.exportInfo(assetId: "second")?.variants[.original]?.status == .done)
      #expect(f.store.exportInfo(assetId: "second")?.variants[.edited]?.status == .done)
      #expect(f.store.exportInfo(assetId: "other")?.month == 2)
      #expect(f.manager.totalJobsEnqueued == 3 && f.manager.totalJobsCompleted == 3)
      #expect(!f.manager.isRunning && !f.manager.isPaused && f.manager.queueCount == 0)
    } catch {
      await f.cleanup()
      throw error
    }
    await f.cleanup()
  }

  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func monthActionResumesWhileMatchingWriterIsHeld(hasMatchingPendingJob: Bool) async throws {
    let f = Fixture()
    do {
      f.add("first")
      if hasMatchingPendingJob { f.add("second") }
      f.manager.startExportMonth(year: 2025, month: 1)
      await f.prepared()
      let started = await f.gate.waitForEnter(count: 1)
      try #require(started)
      _ = try f.captureCurrentTask()
      f.manager.pause()
      let generation = f.manager.generation
      let scans = f.library.fetchAssetsCalls.count
      let enqueued = f.manager.totalJobsEnqueued
      #expect(f.manager.queuedCount(year: 2025, month: 1) == (hasMatchingPendingJob ? 1 : 0))

      f.manager.startExportMonth(year: 2025, month: 1)

      let resumed = !f.manager.isPaused
      #expect(resumed)
      #expect(f.manager.currentPreparationTasks.isEmpty)
      #expect(f.manager.generation == generation)
      #expect(f.manager.totalJobsEnqueued == enqueued)
      #expect(f.manager.totalJobsCompleted == 0)
      #expect(f.writer.writeCalls.count == 1 && f.fileSystem.moveCalls.isEmpty)
      try #require(resumed)
      await f.gate.releaseAll()
      await f.manager.waitForQueueDrained()
      #expect(f.library.fetchAssetsCalls.count == scans)
      #expect(
        f.writer.writeCalls.map(\.assetId)
          == (hasMatchingPendingJob ? ["first", "second"] : ["first"]))
      #expect(f.fileSystem.moveCalls.count == enqueued)
      #expect(f.manager.totalJobsCompleted == enqueued && f.manager.totalJobsEnqueued == enqueued)
      #expect(!f.manager.isPaused && !f.manager.isRunning)
    } catch {
      await f.cleanup()
      throw error
    }
    await f.cleanup()
  }

  enum Rejection: CaseIterable { case photos, failedStore, importing }

  @Test(.timeLimit(.minutes(1)), arguments: Rejection.allCases)
  func matchingQueueStillRespectsAdmission(rejection: Rejection) async throws {
    let f = Fixture()
    do {
      f.add("pending")
      switch rejection {
      case .photos: f.library.isAuthorized = false
      case .failedStore:
        let directory = f.root.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("invalid json".utf8).write(
          to: directory.appendingPathComponent("export-records.json"))
        f.store.configure(for: "broken")
        let failed = f.store.state == .failed
        try #require(failed)
      case .importing:
        f.manager.startImport()
        let importing = f.manager.isImporting
        try #require(importing)
      }
      f.manager.queueCoordinator.pause()
      let jobs = [
        ExportManager.ExportJob(
          assetLocalIdentifier: "pending", placement: .timeline(year: 2025, month: 1),
          selection: .edited)
      ]
      f.manager.queueCoordinator.enqueue(jobs)
      let generation = f.manager.generation
      f.manager.startExportMonth(year: 2025, month: 1)
      await f.prepared()
      #expect(f.manager.isPaused)
      #expect(Array(f.manager.pendingJobs) == jobs)
      #expect(f.manager.totalJobsEnqueued == 1 && f.manager.totalJobsCompleted == 0)
      #expect(f.manager.generation == generation)
      #expect(f.writer.writeCalls.isEmpty && f.library.fetchAssetsCalls.isEmpty)
    } catch {
      await f.cleanup()
      throw error
    }
    await f.cleanup()
  }

  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func absentMonthUsesNormalEnqueueAndDoesNotResumeUnrelatedQueue(stalePlacement: Bool) async throws
  {
    let f = Fixture()
    do {
      f.add("finished")
      f.add("other", month: 2)
      f.add("new", month: 3)
      f.manager.startExportMonth(year: 2025, month: 1)
      await f.prepared()
      let started = await f.gate.waitForEnter(count: 1)
      try #require(started)
      let first = try f.captureCurrentTask()
      f.manager.pause()
      await f.gate.releaseAll()
      await first.value
      // The coordinator retains its resolved task handle after parking.
      let parked = !f.manager.isProcessing && f.manager.currentTask != nil && f.manager.isPaused
      try #require(parked)
      f.manager.queueCoordinator.enqueue([
        .init(
          assetLocalIdentifier: "other", placement: .timeline(year: 2025, month: 2),
          selection: .edited)
      ])
      if stalePlacement {
        // Exercise the host seam with stale UI identifiers but no processing owner.
        f.manager.setCurrentJob(
          .init(
            assetLocalIdentifier: "finished", placement: .timeline(year: 2025, month: 3),
            selection: .edited))
      }
      f.manager.startExportMonth(year: 2025, month: 3)
      await f.prepared()
      #expect(f.manager.isPaused && !f.manager.isProcessing)
      #expect(f.manager.pendingJobs.map(\.assetLocalIdentifier) == ["other", "new"])
      #expect(f.manager.totalJobsEnqueued == 3 && f.manager.totalJobsCompleted == 1)
      #expect(f.writer.writeCalls.map(\.assetId) == ["finished"])
      #expect(f.library.fetchAssetsCalls.map { $0.month } == [1, 3])
    } catch {
      await f.cleanup()
      throw error
    }
    await f.cleanup()
  }
}
