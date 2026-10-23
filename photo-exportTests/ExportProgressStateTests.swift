import Testing

@testable import Photo_Export

/// What each reader of the progress state registers: `MonthRow` reads only the in-flight
/// placement, and `ExportProgressBar` reads the counters, filename, render activity and
/// messages.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ExportProgressStateTests {
  @Test func monthRowReadsAreNotNotifiedByPerAssetProgress() {
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

  @Test func progressBarReadsAreNotifiedForEachField() {
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
