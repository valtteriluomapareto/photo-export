import Foundation

/// Current AutoSync state. Mapped 1:1 to the State Model section of the auto-sync plan.
///
/// State carries the reason inline:
/// - `waiting` and `blocked` carry an `AutoSyncBlockedReason` (why the run can't proceed).
/// - `scheduled` carries an `AutoSyncReason` (the trigger that will fire) plus its `fireAt`.
/// - `running` carries a `runId` (the active `ExportRunContext.runId`) plus the trigger
///   reason for diagnostics.
///
/// Run history (lastRunSummary, lastFailureSummary, etc.) lives separately on
/// `AutoSyncManager`, not on the state — the plan distinguishes "current state" from
/// "persisted summaries" so a `nil`-summary new install isn't conflated with an
/// `.idle` state.
enum AutoSyncState: Equatable, Sendable {
  /// User has not enabled Auto Export. The reducer accepts events but emits no effects
  /// other than persistence-clearing in response to teardown.
  case disabled

  /// Auto Export is enabled but currently waiting on a precondition that is expected to
  /// resolve transiently (e.g. destination just unmounted; user just expanded limited
  /// access). Distinct from `.blocked`, which requires user action.
  case waiting(AutoSyncBlockedReason)

  /// Auto Export is enabled and ready; no work is pending. The reducer transitions to
  /// `.scheduled` when an event creates work.
  case idle

  /// A run is queued and will fire after the debounce. `fireAt` is the absolute time
  /// the timer is set to expire; the effect runner schedules a real `Task.sleep` against
  /// it.
  case scheduled(reason: AutoSyncReason, fireAt: Date)

  /// Auto Export is enabled but cannot run until the user takes action — e.g. confirm
  /// an existing non-empty backup, expand limited Photos access, or resolve a
  /// migration conflict. Distinct from `.waiting` because the resolution requires a
  /// user-visible step rather than a transient state change.
  case blocked(AutoSyncBlockedReason)

  /// A run is in flight. `runId` matches the `ExportRunContext.runId` of the run the
  /// effect runner started; the reducer transitions back to `.idle` (or another
  /// terminal) when the matching `ExportRunSummary` arrives via
  /// `exportRunStateChanged`.
  case running(runId: UUID, reason: AutoSyncReason)
}
