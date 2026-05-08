import Foundation

/// Side-effect emitted by the AutoSync reducer. The reducer is pure — every observable
/// effect of an event is one of these cases. The effect runner (in `AutoSyncManager`)
/// translates them into real timers, run starts, persistence writes, and token
/// advances; tests assert the effect list directly without executing it.
///
/// Plan §"State Reducer" defines the dispatch contract: effects are returned as a list
/// per `reduce` call and dispatched after the reducer returns; events produced by an
/// effect (e.g. `exportRunStateChanged` from `startRun`) are queued and processed after
/// the current event's effects complete. Timer cancellation is itself an effect
/// (`cancelDebounce`, `cancelRetryTimer`), not a reducer side effect.
///
/// **Effect-list ordering is load-bearing.** The runner must process effects in the
/// order returned. The reducer relies on this for at least one durability invariant:
/// when a `photosChanged` event produces both `persistDirtyState` and
/// `advancePersistentChangeToken`, the persist effect is emitted *before* the token
/// advance. Plan §"Photo Library Changes": "Advance the token only after a dirty
/// event has been durably recorded" — if the token were advanced first and the
/// process crashed before the dirty write committed, the next launch would skip the
/// range without recording the dirty IDs. Pinned by reducer tests that assert effect
/// list equality (not just `.contains`).
enum AutoSyncEffect: Equatable, Sendable {
  /// Schedule a debounce timer for `reason` to fire at `fireAt`. If a debounce for the
  /// same reason is already scheduled, the runner replaces it (the most recent
  /// scheduling wins).
  case scheduleDebounce(AutoSyncReason, fireAt: Date)

  /// Cancel any scheduled debounce timer for `reason`.
  case cancelDebounce(AutoSyncReason)

  /// Schedule the retry timer to fire at `fireAt`. There is at most one retry timer
  /// in flight at a time.
  case scheduleRetryTimer(fireAt: Date)

  /// Cancel the retry timer if any is scheduled.
  case cancelRetryTimer

  /// Start an export run. The effect carries the parameters needed to construct the
  /// `ExportRunContext`; the runner generates the `runId` (UUID) and `startedAt`
  /// (clock-now) when it dispatches the run, so tests can assert effects without
  /// having to mock UUID generation. The runner reports back via
  /// `exportRunStateChanged` events as the run progresses.
  case startRun(StartRunSpec)

  /// Persist the current per-destination dirty state. The runner writes through the
  /// configured `AutoSyncDirtyStateStore`.
  case persistDirtyState(AutoSyncDirtyState, destinationId: String)

  /// Persist a finished run's summary as `lastRunSummary` for the destination.
  case persistRunSummary(ExportRunSummary, destinationId: String)

  /// Advance the per-destination persistent-change token snapshot. Called after the
  /// destination has durably recorded its dirty IDs / full-reconciliation intent for
  /// the change set, per the plan's "advance only after durable record" ordering.
  case advancePersistentChangeToken(Data, destinationId: String)
}

/// Parameters needed to construct an `ExportRunContext`. The runner adds `runId` and
/// `startedAt` at dispatch time. Equatable so tests can assert effect lists.
struct StartRunSpec: Equatable, Sendable {
  let source: ExportRunSource
  let visibility: ExportRunVisibility
  let reason: AutoSyncReason
  let scope: ExportRunScope
  let selection: ExportVersionSelection
}
