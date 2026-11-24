import Foundation
import Testing

@testable import Photo_Export

struct AutoExportPresentationTests {
  @Test func statusCountdownUsesTheSuppliedTimeAndClampsExpiredDeadlines() {
    let now = Date(timeIntervalSince1970: 100)
    let state = AutoSyncState.scheduled(reason: .photosChanged, fireAt: now.addingTimeInterval(1.6))
    #expect(AutoExportPresentation.statusHeadline(state) == "Run scheduled")
    #expect(AutoExportPresentation.statusDetail(state, now: now) == "library changed — fires in 2s")
    #expect(
      AutoExportPresentation.statusDetail(state, now: now.addingTimeInterval(5))
        == "library changed — fires in 0s")
    #expect(
      AutoExportPresentation.statusHeadline(.blocked(.noScopesSelected))
        == "Blocked — pick what to export")
    #expect(
      AutoExportPresentation.statusHeadline(.waiting(.destinationChecking))
        == "Waiting — checking the destination")
    #expect(AutoExportPresentation.statusHeadline(.running(reason: .appLaunch)) == "Exporting…")
    #expect(
      AutoExportPresentation.statusDetail(.running(reason: .appLaunch), now: now) == "app launch")
    #expect(AutoExportPresentation.statusDetail(.idle, now: now) == nil)
  }

  @Test func catchUpCountsDurationAndOutcomeRemainDistinct() {
    func label(
      _ result: PhotoLibraryPersistentChangeAdapter.CatchUpSummary.Result, duration: TimeInterval
    ) -> String {
      AutoExportPresentation.catchUpLabel(
        .init(
          startedAt: Date(timeIntervalSince1970: 0),
          finishedAt: Date(timeIntervalSince1970: duration),
          trigger: "test", result: result))
    }
    #expect(
      label(.capturedBaseline, duration: 0.5) == "Last library check: captured baseline in 500 ms")
    #expect(
      label(.emittedChanges(count: 1), duration: 1.4) == "Last library check: 1 change in 1.4 s")
    #expect(
      label(.emittedChanges(count: 2), duration: 0.5) == "Last library check: 2 changes in 500 ms")
    #expect(
      label(.detailsUnavailable(failures: 3), duration: 0.5)
        == "Last library check: details unavailable (3 failures) in 500 ms")
    #expect(
      label(.fetchError(description: "offline"), duration: 0.5)
        == "Last library check: offline in 500 ms")
  }

  @Test func lastRunShowsFailuresAndNoncompletedOutcomeWithoutChangingCounts() {
    func summary(result: ExportRunResult, failures: Int) -> ExportRunSummary {
      .init(
        context: .init(
          source: .autoSync, visibility: .background, scope: .timelineFullLibrary,
          selection: .edited),
        endedAt: .distantPast, enqueuedCount: 5, completedCount: 3, failedCount: failures,
        skippedCount: 2, cancelReason: nil, result: result)
    }
    #expect(
      AutoExportPresentation.lastRunDetail(summary(result: .completed, failures: 0)) == "3 exported"
    )
    #expect(
      AutoExportPresentation.lastRunDetail(summary(result: .failed, failures: 2))
        == "3 exported, 2 failed (failed)")
    #expect(
      AutoExportPresentation.lastRunDetail(summary(result: .cancelled, failures: 0))
        == "3 exported (cancelled)")
  }
}
