import Foundation
import Testing

@testable import Photo_Export

/// Exact progress sources keep independent Observation dependencies while presentation
/// readers follow bounded clock publications and immediate run boundaries.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ExportProgressStateTests {
  @MainActor
  private final class Fixture {
    let root = TestScratch.directory("ProgressPresentation")
    let clock = TestClock()
    let destination = FakeExportDestination()
    let service = FakePhotoLibraryService()
    let writer = FakeAssetResourceWriter()
    let timeline: ExportRecordStore
    let collections: CollectionExportRecordStore
    let manager: ExportManager

    init() {
      timeline = ExportRecordStore(baseDirectoryURL: root, notificationClock: clock)
      collections = CollectionExportRecordStore(baseDirectoryURL: root, notificationClock: clock)
      timeline.configure(for: "A")
      collections.configure(for: "A")
      manager = ExportManager(
        photoLibraryService: service, exportDestination: destination,
        exportRecordStore: timeline, collectionExportRecordStore: collections,
        assetResourceWriter: writer, fileSystem: FakeFileSystem(),
        progressClock: clock, userDefaults: TestScratch.defaults("ProgressPresentation"))
    }

    func enqueue() {
      manager.queueCoordinator.enqueue(
        (1...3).map {
          .init(
            assetLocalIdentifier: "queued-\($0)", placement: .timeline(year: 2026, month: 9),
            selection: .edited)
        })
    }

    func close() async {
      let task = manager.currentTask
      manager.cancelAndClear()
      if let task { _ = await finished(task) }
      try? await timeline.flush()
      try? await collections.flush()
      destination.cleanup()
      try? FileManager.default.removeItem(at: root)
    }
  }

  @Test(arguments: ["enqueue", "completion", "pause", "replacement"])
  func immediateBoundaryCancellationKeepsCoordinatorAndMirrorsCleared(boundary: String) async throws
  {
    let f = Fixture()
    let gate = AsyncCheckpoint()
    try await withCleanup {
      let progress = f.manager.progressState
      let queue = f.manager.queueCoordinator!
      var held: Task<Void, Never>?
      if boundary == "completion" || boundary == "replacement" {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 15))!
        f.service.assetsByYearMonth["2026-9"] = [
          TestAssetFactory.makeAsset(id: "completing", creationDate: date)
        ]
        f.service.resourcesByAssetId["completing"] = [
          ResourceDescriptor(type: .photo, originalFilename: "complete.JPG")
        ]
        f.writer.checkpoint = gate
        queue.enqueue([
          .init(
            assetLocalIdentifier: "completing",
            placement: .timeline(year: 2026, month: 9), selection: .edited)
        ])
        queue.processQueueIfNeeded()
        try #require(await gate.waitForEnter(count: 1))
        held = queue.currentTask
      } else if boundary == "pause" {
        f.enqueue()
        progress.currentAssetFilename = "waiting.JPG"
      }
      var cancelled = false
      let bar = ObservationProbe(
        { _ = progress.presentation },
        onChange: {
          guard !cancelled else { return }
          cancelled = true
          f.manager.cancelAndClear()
          if boundary == "replacement" { f.enqueue() }
        })
      switch boundary {
      case "enqueue": f.enqueue()
      case "completion", "replacement":
        await gate.releaseAll()
        if let held { _ = await finished(held) }
      default: f.manager.pause()
      }
      #expect(cancelled)
      if boundary == "replacement" {
        #expect(queue.pendingJobs.count == 3)
        #expect(queue.totalJobsEnqueued == 3)
        #expect(queue.totalJobsCompleted == 0)
        #expect(f.manager.totalJobsCompleted == 0)
        #expect(!queue.isProcessing)
        #expect(!queue.isRunning)
        #expect(queue.currentTask == nil)
        #expect(f.writer.writeCalls.count == 1)
        bar.stop()
        queue.processQueueIfNeeded()
        #expect(queue.isProcessing)
        return
      }
      #expect(queue.totalJobsEnqueued == 0)
      #expect(queue.totalJobsCompleted == 0)
      #expect(f.manager.totalJobsEnqueued == 0)
      #expect(f.manager.totalJobsCompleted == 0)
      #expect(!queue.isRunning)
      #expect(!queue.isPaused)
      #expect(!queue.isProcessing)
      #expect(!f.manager.isRunning)
      #expect(!f.manager.isPaused)
      #expect(queue.queueCount == 0)
      #expect(f.manager.queueCount == 0)
      #expect(queue.pendingJobs.isEmpty)
      #expect(queue.queuedCountsByPlacementId.isEmpty)
      #expect(queue.currentTask == nil)
      #expect(f.manager.currentJobAssetId == nil)
      #expect(f.manager.currentJobPlacement == nil)
      #expect(
        queue.monthState(placementId: ExportPlacement.timeline(year: 2026, month: 9).id).snapshot
          == .init())
      #expect(progress.presentation == .init())
      #expect(f.writer.writeCalls.count == (boundary == "completion" ? 1 : 0))
      bar.stop()
      f.enqueue()
      queue.processQueueIfNeeded()
      #expect(queue.isProcessing)
      #expect(queue.isRunning)
      #expect(queue.currentTask != nil)
    } cleanup: {
      await gate.releaseAll()
      await f.close()
    }
  }

  @Test func presentationPublishesOncePerWindowWithTheLatestSources() {
    let clock = TestClock()
    let progress = ExportProgressState(clock: clock)
    progress.totalJobsEnqueued = 4
    let bar = ObservationProbe { _ = progress.presentation }
    progress.totalJobsCompleted = 1
    progress.currentAssetFilename = "first.JPG"
    progress.totalJobsCompleted = 2
    progress.currentAssetFilename = "latest.JPG"
    progress.renderActivity = .rendering
    #expect(progress.totalJobsCompleted == 2)
    #expect(bar.changeCount == 0)
    #expect(clock.pendingCount == 1)
    clock.advance(by: 0.199)
    #expect(bar.changeCount == 0)
    clock.advance(by: 0.002)
    #expect(bar.changeCount == 1)
    #expect(progress.presentation.totalJobsCompleted == 2)
    #expect(progress.presentation.currentAssetFilename == "latest.JPG")
    #expect(progress.presentation.renderActivity == .rendering)
    #expect(clock.pendingCount == 0)
  }

  @Test func startPauseAndCancelFlushExactManagerSourcesImmediately() async {
    let f = Fixture()
    await withCleanup {
      let progress = f.manager.progressState
      f.enqueue()
      #expect(progress.presentation.totalJobsEnqueued == 3)
      #expect(f.manager.queueCount == 3)
      progress.currentAssetFilename = "before-start.JPG"
      #expect(progress.presentation.currentAssetFilename == nil)
      f.manager.queueCoordinator.processQueueIfNeeded()
      #expect(f.manager.isRunning)
      #expect(progress.presentation.currentAssetFilename == "before-start.JPG")
      progress.totalJobsCompleted = 1
      progress.currentAssetFilename = "before-pause.JPG"
      #expect(f.manager.totalJobsCompleted == 1)
      #expect(progress.presentation.totalJobsCompleted == 0)
      f.manager.pause()
      #expect(f.manager.isPaused)
      #expect(progress.presentation.totalJobsCompleted == 1)
      #expect(progress.presentation.currentAssetFilename == "before-pause.JPG")
      f.manager.clearCurrentJobIdentifiers(keepingPlacement: true)
      #expect(progress.currentAssetFilename == "before-pause.JPG")
      progress.currentAssetFilename = "before-cancel.JPG"
      f.manager.cancelAndClear()
      #expect(progress.presentation == .init())
      #expect(f.manager.queueCount == 0)
      #expect(!f.manager.isRunning)
      let bar = ObservationProbe { _ = progress.presentation }
      f.clock.advance(by: 1)
      #expect(bar.changeCount == 0)
      #expect(f.clock.pendingCount == 0)
    } cleanup: {
      await f.close()
    }
  }

  @Test func finishAndFeedbackVisibilityFlushWithoutATick() {
    let clock = TestClock()
    let progress = ExportProgressState(clock: clock)
    progress.totalJobsEnqueued = 2
    progress.totalJobsCompleted = 1
    progress.currentAssetFilename = "last.JPG"
    progress.totalJobsCompleted = 2
    #expect(progress.presentation.totalJobsCompleted == 2)
    #expect(progress.presentation.currentAssetFilename == "last.JPG")
    #expect(clock.pendingCount == 0)
    progress.manualSummary = .init(completedCount: 2, failedCount: 0, failureMessage: nil)
    #expect(progress.presentation.manualSummary == progress.manualSummary)
    progress.manualSummary?.isDismissed = true
    #expect(progress.presentation.manualSummary?.isDismissed == true)
    progress.totalJobsEnqueued = 0
    progress.emptyRunMessage = "Nothing new to export."
    #expect(progress.presentation.emptyRunMessage == "Nothing new to export.")
    progress.emptyRunMessage = nil
    #expect(progress.presentation.emptyRunMessage == nil)
  }

  @Test func cancellationDuringPresentationPublicationCannotRestoreOldProgress() async {
    let f = Fixture()
    await withCleanup {
      let progress = f.manager.progressState
      f.enqueue()
      progress.totalJobsCompleted = 1
      progress.currentAssetFilename = "obsolete.JPG"
      var cancelled = false
      let bar = ObservationProbe(
        { _ = progress.presentation },
        onChange: {
          guard !cancelled else { return }
          cancelled = true
          f.manager.cancelAndClear()
        })
      f.clock.advance(by: 0.2)
      #expect(cancelled)
      #expect(progress.presentation == .init())
      #expect(f.manager.totalJobsEnqueued == 0)
      #expect(f.manager.totalJobsCompleted == 0)
      #expect(f.manager.queueCount == 0)
      #expect(f.clock.pendingCount == 0)
      let before = bar.changeCount
      f.clock.advance(by: 1)
      #expect(bar.changeCount == before)
      bar.stop()
    } cleanup: {
      await f.close()
    }
  }

  @Test func placementReadsAreNotNotifiedByPerAssetProgress() {
    let progress = ExportProgressState()
    let row = ObservationProbe { _ = progress.currentJobPlacement }
    progress.totalJobsEnqueued = 2
    progress.totalJobsCompleted = 1
    progress.currentAssetFilename = "IMG_0001.JPG"
    progress.renderActivity = .rendering
    progress.emptyRunMessage = "Nothing new to export."
    progress.queueWarningMessage = "Some albums could not be listed."
    progress.manualSummary = ManualExportSummary(
      completedCount: 1, failedCount: 0, failureMessage: nil)
    #expect(row.changeCount == 0)
    progress.currentJobPlacement = .timeline(year: 2026, month: 9)
    progress.currentJobPlacement = .timeline(year: 2026, month: 9)
    #expect(row.changeCount == 1, "An equal placement write must not re-render the rows")
    progress.currentJobPlacement = nil
    #expect(row.changeCount == 2)
  }

  @Test func sourceFieldsKeepIndependentObservation() {
    let progress = ExportProgressState()
    let bar = ObservationProbe {
      _ = progress.manualSummary
      _ = progress.totalJobsEnqueued
      _ = progress.totalJobsCompleted
      _ = progress.currentAssetFilename
      _ = progress.renderActivity
      _ = progress.emptyRunMessage
      _ = progress.queueWarningMessage
    }
    progress.totalJobsEnqueued = 2
    progress.totalJobsCompleted = 1
    progress.currentAssetFilename = "IMG_0001.JPG"
    progress.renderActivity = .downloading
    progress.emptyRunMessage = "Nothing new to export."
    progress.queueWarningMessage = "Some albums could not be listed."
    progress.manualSummary = ManualExportSummary(
      completedCount: 1, failedCount: 0, failureMessage: nil)
    progress.manualSummary?.isDismissed = true
    #expect(bar.changeCount == 8)
    progress.currentJobPlacement = .timeline(year: 2026, month: 9)
    #expect(bar.changeCount == 8)
  }

  /// Clearing feedback that is already empty leaves progress readers quiet.
  @Test func clearingAnEmptyMessageIsNotObserved() {
    let progress = ExportProgressState()
    let bar = ObservationProbe { _ = progress.emptyRunMessage }
    progress.emptyRunMessage = nil
    #expect(bar.changeCount == 0)
    progress.emptyRunMessage = "Nothing new to export."
    #expect(bar.changeCount == 1)
  }

  /// Feedback changes notify only the readers that display the message.
  @Test func emptyRunMessageWriteNotifiesOnlyItsOwnReaders() {
    let progress = ExportProgressState()
    let message = ObservationProbe { _ = progress.emptyRunMessage }
    let siblings = [
      ObservationProbe { _ = progress.manualSummary },
      ObservationProbe { _ = progress.totalJobsEnqueued },
      ObservationProbe { _ = progress.totalJobsCompleted },
      ObservationProbe { _ = progress.currentAssetFilename },
      ObservationProbe { _ = progress.renderActivity },
      ObservationProbe { _ = progress.queueWarningMessage },
      ObservationProbe { _ = progress.currentJobPlacement },
    ]
    progress.emptyRunMessage = "Nothing new to export."
    #expect(message.changeCount == 1)
    #expect(siblings.map(\.changeCount) == Array(repeating: 0, count: siblings.count))
  }
}
