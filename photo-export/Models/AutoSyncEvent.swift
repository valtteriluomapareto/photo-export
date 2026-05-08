import Foundation

/// Inputs the AutoSync reducer reacts to. Plan §"State Reducer" — one event per
/// observable change in the manager's environment.
///
/// Events arrive serialized through the effect runner; the reducer is invoked once per
/// event with no mutation in flight. Effects emitted by the reducer are dispatched
/// after `reduce` returns, and any new events they produce (e.g.
/// `exportRunStateChanged` triggered by a `startRun` effect) are queued behind the
/// current event's effects.
enum AutoSyncEvent: Sendable {
  /// User toggled Enable Auto Export.
  case enabledChanged(Bool)

  /// Destination identity, availability, or safety state changed.
  case destinationChanged(DestinationSnapshot)

  /// Auto Export scope checkboxes changed in Settings.
  case scopeSelectionChanged(AutoExportScopeSelection)

  /// Include-originals (or future export-version) selection changed.
  case versionSelectionChanged(ExportVersionSelection)

  /// Photos library reported a persistent change. The reducer extracts inserted /
  /// updated / deleted ids and decides whether to schedule a targeted re-evaluation,
  /// fall back to bounded full reconciliation, or no-op.
  case photosChanged(PhotoLibraryPersistentChangeEvent)

  /// `PHPhotoLibrary.fetchPersistentChanges(since:)` failed for the current
  /// persistent-change token. Plan §"Photo Library Changes": "Distinguish three
  /// failure modes from `fetchPersistentChanges(since:)` and route each explicitly:
  /// token-expired, token-invalid, and details-unavailable. All three reset the
  /// affected destination's `lastDurablyRecordedToken` ... and schedule one bounded
  /// full reconciliation."
  case photosChangeFetchFailed(PhotoLibraryPersistentChangeFetchError)

  /// `ExportManager`'s active-run state changed. Used to detect a run starting,
  /// completing, or being cancelled out from under the reducer.
  case exportRunStateChanged(ExportRunState)

  /// An auto-sync run we started has reached a terminal state. The summary's
  /// `result` distinguishes successful completion from `.failed` / `.cancelled` /
  /// `.interrupted`; the reducer only clears dirty work on `.completed` so
  /// transient failures keep their pending IDs intact for retry.
  case autoSyncRunCompleted(ExportRunSummary)

  /// Import Existing Backup started or finished. AutoSync defers while import is
  /// active and re-evaluates afterward.
  case importStateChanged(isImporting: Bool)

  /// A debounce timer the reducer scheduled fired. The reason matches the
  /// `scheduleDebounce` effect that scheduled it.
  case debounceFired(AutoSyncReason)

  /// The retry timer fired. Used when at least one variant is in retry backoff and
  /// the next eligible time has arrived.
  case retryTimerFired

  /// A user-visible manual full export finished — clears compatible pending auto-sync
  /// dirty work for the same destination/selection/scope.
  case manualFullExportCompleted(ExportRunSummary)

  /// Persisted dirty state for `destinationId` was loaded from disk. Dispatched
  /// by the manager on destination-change so accumulated targeted-asset work
  /// survives app restart. Carries no effects — the reducer just merges into
  /// `dirtyStateByDestination`. Other per-destination persisted state
  /// (`lastRunSummary`, `lastDurablyRecordedToken`) does not flow through this
  /// event because the reducer doesn't read it; the manager loads and surfaces
  /// it directly.
  case destinationDirtyStateLoaded(destinationId: String, dirtyState: AutoSyncDirtyState)
}
