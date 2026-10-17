import Foundation

/// Presentation for existing destination validation outcomes; never an export gate.
enum ExportDestinationStatus: Equatable, Sendable {
  case noSelection, ready, unreachable, permissionRequired, readOnly, notDirectory,
    bookmarkSaveFailed

  var statusMessage: String? {
    switch self {
    case .noSelection: "No export folder selected"
    case .ready: nil
    case .unreachable: "Export folder is not reachable (drive unplugged?)"
    case .permissionRequired: "Export folder permission needs to be re-selected"
    case .readOnly: "Export folder is read-only"
    case .notDirectory: "Selected path is not a folder"
    case .bookmarkSaveFailed: "Failed to save access to selected folder"
    }
  }

  var exportHelp: String {
    switch self {
    case .noSelection: "Choose an export folder to export."
    case .ready: "Export folder is ready."
    case .unreachable:
      "Export folder is unavailable. Reconnect the drive or network share to export."
    case .permissionRequired:
      "Export folder access needs restoring. Reconnect the drive, then choose the same folder if needed."
    case .readOnly:
      "Export folder is read-only. Allow write access or choose a writable folder."
    case .notDirectory:
      "Selected export path is not a folder. Choose the export folder again."
    case .bookmarkSaveFailed:
      "Could not save folder access. Choose the export folder again."
    }
  }

  var offersFolderSelection: Bool {
    switch self {
    case .permissionRequired, .readOnly, .notDirectory, .bookmarkSaveFailed: true
    case .noSelection, .ready, .unreachable: false
    }
  }

  var warningMessage: String? {
    switch self {
    case .noSelection, .ready: nil
    default: exportHelp
    }
  }
}
