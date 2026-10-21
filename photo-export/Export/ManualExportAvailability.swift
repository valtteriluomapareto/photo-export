import Foundation

/// Whether a manual export can start into one history, and why not. Every manual export
/// control reads this one rule, which matches what `ExportManager`'s start methods accept, so a
/// control is disabled with a reason instead of dropping the click.
enum ManualExportAvailability: Equatable, Sendable {
  case available
  /// The destination can't take exports; `ExportDestinationManager.exportUnavailableHelp`
  /// says why.
  case destinationUnavailable
  /// The destination's history is still being read. This ends on its own.
  case loadingHistory
  /// The history needs recovery (the export history alert says how) or has no destination.
  case historyUnavailable

  static let loadingHistoryText = "Loading export history\u{2026}"

  init(destinationCanExport: Bool, history: RecordStoreState) {
    if !destinationCanExport {
      self = .destinationUnavailable
    } else if history == .loading {
      self = .loadingHistory
    } else if history != .ready {
      self = .historyUnavailable
    } else {
      self = .available
    }
  }

  var canStart: Bool { self == .available }

  /// Why the control can't start, for its help; `nil` when it can.
  func unavailableHelp(destinationHelp: String) -> String? {
    switch self {
    case .available: nil
    case .destinationUnavailable: destinationHelp
    case .loadingHistory: Self.loadingHistoryText
    case .historyUnavailable:
      "Export history isn\u{2019}t available. Resolve the export history alert to export."
    }
  }
}
