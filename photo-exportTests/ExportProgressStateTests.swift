import Testing

@testable import Photo_Export

/// What each reader of the progress state registers: `MonthRow` reads only the in-flight
/// placement, and `ExportProgressBar` reads the counters, filename, render activity and
/// messages.
@MainActor
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

  /// The message is cleared on every new export, usually while already empty; that write is
  /// still delivered to Combine subscribers but must not re-render the progress bar.
  @Test func clearingAnEmptyMessageIsDeliveredButNotObserved() {
    let progress = ExportProgressState()
    let bar = ObservationProbe { _ = progress.emptyRunMessage }
    var delivered: [String?] = []
    let subscription = progress.emptyRunMessagePublisher.dropFirst().sink { delivered.append($0) }
    progress.emptyRunMessage = nil
    #expect(delivered == [nil])
    #expect(bar.changeCount == 0)
    progress.emptyRunMessage = "Nothing new to export."
    #expect(bar.changeCount == 1)
    subscription.cancel()
  }
}
