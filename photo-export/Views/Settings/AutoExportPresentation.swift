import Foundation

/// Pure settings copy and countdown rules; views retain their original observed owners.
enum AutoExportPresentation {
  static func exportNowFooter(_ state: AutoSyncState) -> String {
    switch state {
    case .disabled:
      return "Enable Auto Export above to use Export Now."
    case .blocked(.noScopesSelected):
      return "Pick at least one scope above first."
    case .blocked(.destinationMissing):
      return "Select an export destination first."
    case .blocked(.destinationUnsafe):
      return "The destination has unresolved issues. Open the destination indicator to review."
    case .blocked(.photosAccessMissing):
      return PhotosAccessGuidance.message
    case .blocked:
      return "Auto Export is blocked. Resolve the issue above to run now."
    case .running:
      return "A run is already in progress."
    case .waiting(.destinationUnavailable):
      return
        "The destination drive isn't connected. Export Now will queue the run for when it's reachable."
    case .waiting(.destinationChecking):
      return "Checking the destination folder. Export Now will run if the folder passes the check."
    case .waiting:
      return "Auto Export will run shortly."
    case .scheduled, .idle:
      return "Bypass the debounce and start a run right now."
    }
  }

  static func statusHeadline(_ state: AutoSyncState) -> String {
    switch state {
    case .disabled: return "Auto Export is off"
    case .idle: return "Up to date"
    case .scheduled: return "Run scheduled"
    case .running: return "Exporting\u{2026}"
    case .waiting(let reason): return "Waiting — \(reason.userFacingLabel)"
    case .blocked(let reason): return "Blocked — \(reason.userFacingLabel)"
    }
  }

  static func statusDetail(_ state: AutoSyncState, now: Date) -> String? {
    switch state {
    case .scheduled(let reason, let fireAt):
      let secs = max(0, Int(fireAt.timeIntervalSince(now).rounded()))
      return "\(reason.userFacingLabel) — fires in \(secs)s"
    case .running(let reason):
      return reason.userFacingLabel
    default:
      return nil
    }
  }

  static func lastRunDetail(_ summary: ExportRunSummary) -> String {
    let counts = "\(summary.completedCount) exported"
    let failedSuffix = summary.failedCount > 0 ? ", \(summary.failedCount) failed" : ""
    let resultSuffix = summary.result == .completed ? "" : " (\(summary.result.rawValue))"
    return counts + failedSuffix + resultSuffix
  }

  static func catchUpLabel(_ summary: PhotoLibraryPersistentChangeAdapter.CatchUpSummary) -> String
  {
    let durationMs = Int(summary.duration * 1000)
    let durationText =
      durationMs < 1000 ? "\(durationMs) ms" : String(format: "%.1f s", summary.duration)
    switch summary.result {
    case .capturedBaseline:
      return "Last library check: captured baseline in \(durationText)"
    case .emittedChanges(let count):
      return "Last library check: \(count) change\(count == 1 ? "" : "s") in \(durationText)"
    case .detailsUnavailable(let failures):
      return "Last library check: details unavailable (\(failures) failures) in \(durationText)"
    case .fetchError(let description):
      return "Last library check: \(description) in \(durationText)"
    }
  }
}
