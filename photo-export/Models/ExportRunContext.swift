import Foundation

/// Per-run context carried through the awaitable export-run API. Manual and Auto Export runs
/// share this shape; the source/visibility fields drive UI gating decisions and the summary's
/// scope is preserved on the run output for diagnostics.
struct ExportRunContext: Equatable, Codable, Sendable {
  let runId: UUID
  let source: ExportRunSource
  let visibility: ExportRunVisibility
  let reason: AutoSyncReason?
  let scope: ExportRunScope
  let selection: ExportVersionSelection
  let startedAt: Date

  init(
    runId: UUID = UUID(),
    source: ExportRunSource,
    visibility: ExportRunVisibility,
    reason: AutoSyncReason? = nil,
    scope: ExportRunScope,
    selection: ExportVersionSelection,
    startedAt: Date = Date()
  ) {
    self.runId = runId
    self.source = source
    self.visibility = visibility
    self.reason = reason
    self.scope = scope
    self.selection = selection
    self.startedAt = startedAt
  }
}

/// Terminal report produced when a run resolves. Counts and `cancelReason` describe how the
/// run ended; `result` is the single canonical outcome.
struct ExportRunSummary: Equatable, Codable, Sendable {
  let context: ExportRunContext
  let endedAt: Date
  let enqueuedCount: Int
  let completedCount: Int
  let failedCount: Int
  let skippedCount: Int
  let cancelReason: ExportCancelReason?
  let result: ExportRunResult

  var duration: TimeInterval {
    endedAt.timeIntervalSince(context.startedAt)
  }
}

/// Snapshot of the export manager's run state, observed by `AutoSyncManager` to drive reducer
/// events without polling. `nil` `activeContext` means no run is in flight.
struct ExportRunState: Equatable, Sendable {
  let activeContext: ExportRunContext?
  let isManualActive: Bool
  let isAutoSyncActive: Bool

  static let idle = ExportRunState(
    activeContext: nil, isManualActive: false, isAutoSyncActive: false)
}
