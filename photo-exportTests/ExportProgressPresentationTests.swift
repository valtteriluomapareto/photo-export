import Testing

@testable import Photo_Export

@MainActor
struct ExportProgressPresentationTests {
  @Test func dismissedSummarySuppressesStaleJobsAndEmptyFeedback() {
    var source = ExportProgressState.Presentation()
    #expect(ExportProgressPresentation.content(for: source) == .hidden)
    source.emptyRunMessage = "Nothing new"
    #expect(ExportProgressPresentation.content(for: source) == .empty("Nothing new"))
    source.totalJobsEnqueued = 3
    #expect(ExportProgressPresentation.content(for: source) == .active)
    let summary = ManualExportSummary(completedCount: 3, failedCount: 1, failureMessage: nil)
    source.manualSummary = summary
    #expect(ExportProgressPresentation.content(for: source) == .summary(summary))
    source.manualSummary?.isDismissed = true
    #expect(ExportProgressPresentation.content(for: source) == .hidden)
  }

  @Test func activityLabelsDescribeTheCurrentOperationWithoutInventingAFilename() {
    #expect(ExportProgressPresentation.renderActivityHint(nil) == nil)
    #expect(ExportProgressPresentation.renderActivityHint(.downloading) == "(downloading…)")
    #expect(ExportProgressPresentation.renderActivityHint(.rendering) == "(rendering…)")
    #expect(ExportProgressPresentation.currentAssetLabel(filename: nil, activity: nil) == "")
    #expect(
      ExportProgressPresentation.currentAssetLabel(filename: nil, activity: .downloading)
        == "Downloading from iCloud")
    #expect(
      ExportProgressPresentation.currentAssetLabel(filename: "A.JPG", activity: .downloading)
        == "Downloading A.JPG from iCloud")
    #expect(
      ExportProgressPresentation.currentAssetLabel(filename: nil, activity: .rendering)
        == "Rendering edited video")
    #expect(
      ExportProgressPresentation.currentAssetLabel(filename: "A.MOV", activity: .rendering)
        == "Rendering edited A.MOV")
    #expect(
      ExportProgressPresentation.countTooltip(for: .editedWithOriginals).contains(
        "Counts assets, not files"))
  }
}
