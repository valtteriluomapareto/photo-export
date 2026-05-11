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
  /// Per-variant failure detail. Empty for clean runs; populated for runs
  /// that hit at least one failure. AutoSync's reducer reads this to
  /// record failures into `AutoSyncRetryState`; the Export Issues UI
  /// (Phase 4) reads it to group failures for the user. Note that
  /// `failedCount` is the count of *additions* to this list during the run
  /// — they should agree, but `failures` carries the structured detail.
  let failures: [ExportRunFailureDetail]

  init(
    context: ExportRunContext,
    endedAt: Date,
    enqueuedCount: Int,
    completedCount: Int,
    failedCount: Int,
    skippedCount: Int,
    cancelReason: ExportCancelReason?,
    result: ExportRunResult,
    failures: [ExportRunFailureDetail] = []
  ) {
    self.context = context
    self.endedAt = endedAt
    self.enqueuedCount = enqueuedCount
    self.completedCount = completedCount
    self.failedCount = failedCount
    self.skippedCount = skippedCount
    self.cancelReason = cancelReason
    self.result = result
    self.failures = failures
  }

  /// Custom decoder so persisted summaries from before the `failures` field
  /// existed still load — they're treated as having no detail. Without
  /// this, the JSON-on-disk lastRunSummary written by older builds would
  /// fail to decode on launch.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.context = try c.decode(ExportRunContext.self, forKey: .context)
    self.endedAt = try c.decode(Date.self, forKey: .endedAt)
    self.enqueuedCount = try c.decode(Int.self, forKey: .enqueuedCount)
    self.completedCount = try c.decode(Int.self, forKey: .completedCount)
    self.failedCount = try c.decode(Int.self, forKey: .failedCount)
    self.skippedCount = try c.decode(Int.self, forKey: .skippedCount)
    self.cancelReason = try c.decodeIfPresent(
      ExportCancelReason.self, forKey: .cancelReason)
    self.result = try c.decode(ExportRunResult.self, forKey: .result)
    self.failures =
      (try? c.decode([ExportRunFailureDetail].self, forKey: .failures)) ?? []
  }

  private enum CodingKeys: String, CodingKey {
    case context, endedAt, enqueuedCount, completedCount, failedCount, skippedCount,
      cancelReason, result, failures
  }

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
