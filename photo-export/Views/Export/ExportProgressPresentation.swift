import Foundation

/// Pure display rules; the view retains the observed progress owner and real controls.
enum ExportProgressPresentation {
  enum Content: Equatable {
    case hidden
    case summary(ManualExportSummary)
    case active
    case empty(String)
  }

  static func content(for source: ExportProgressState.Presentation) -> Content {
    if let summary = source.manualSummary {
      return summary.isDismissed ? .hidden : .summary(summary)
    }
    if source.totalJobsEnqueued > 0 { return .active }
    return source.emptyRunMessage.map(Content.empty) ?? .hidden
  }

  static func currentAssetLabel(filename: String?, activity: RenderActivity?) -> String {
    let filename = filename ?? ""
    switch activity {
    case .none:
      return filename.isEmpty ? "" : "Currently exporting \(filename)"
    case .downloading:
      return filename.isEmpty
        ? "Downloading from iCloud" : "Downloading \(filename) from iCloud"
    case .rendering:
      return filename.isEmpty ? "Rendering edited video" : "Rendering edited \(filename)"
    }
  }
}
