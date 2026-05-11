import Foundation

/// Persists the most recent `ExportRunSummary` per destination. Plan
/// §"Persistence Keys": `AutoSync/destinations/<destinationId>/lastRunSummary.json`.
/// Surfaced to the UI via `AutoSyncManager.lastRunSummary` so the Auto Export
/// status pill can render "last run: 12 exported, 1 failed" copy across app
/// launches.
@MainActor
protocol AutoSyncRunSummaryStore: AnyObject {
  /// Loads the most recent summary for `destinationId`. Returns nil when no
  /// summary has been recorded yet (or when the file is corrupt — see the
  /// production implementation's decode-error handling).
  func load(destinationId: String) -> ExportRunSummary?

  /// Persists `summary` as the latest for `destinationId`, replacing any prior
  /// value. Throws when the underlying store cannot complete the write.
  func save(_ summary: ExportRunSummary, destinationId: String) throws

  /// Removes any stored summary for `destinationId`.
  func deleteSummary(destinationId: String) throws
}
