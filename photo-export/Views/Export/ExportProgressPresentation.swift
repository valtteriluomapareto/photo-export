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

  static func renderActivityHint(_ activity: RenderActivity?) -> String? {
    switch activity {
    case .none: return nil
    case .downloading: return "(downloading…)"
    case .rendering: return "(rendering…)"
    }
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

  static func countTooltip(for selection: ExportVersionSelection) -> String {
    switch selection {
    case .editedWithOriginals:
      return
        "Counts assets, not files. Each adjusted asset writes both an edited file and a "
        + "_orig companion but counts once. The filename is whichever file is currently "
        + "being written."
    case .edited:
      return
        "Counts assets. The filename is the file currently being written for the asset "
        + "in progress."
    }
  }

}
