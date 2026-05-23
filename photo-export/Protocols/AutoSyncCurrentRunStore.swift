import Foundation

/// Persists the in-flight `AutoSyncRunJournal` per destination. On-disk path:
/// `<App Support>/<bundle-id>/AutoSync/destinations/<destinationId>/currentRun.json`.
///
/// Lifecycle matches the AutoSync fan-out task in `AutoSyncManager.startRun`:
///   1. `save` is called before the first sub-scope iteration to record that
///      a run is in flight.
///   2. `save` is called again at the top of each sub-scope iteration to
///      update `currentScope`.
///   3. `clear` is called once the fan-out exits (clean completion, cancellation,
///      or break on a non-`.completed` sub-summary).
///
/// If a journal file remains on the next launch, the previous session's
/// AutoSync fan-out was killed mid-flight. The diagnostic report surfaces it.
@MainActor
protocol AutoSyncCurrentRunStore: AnyObject {
  /// Loads the journal for `destinationId`. Returns `nil` when no journal
  /// exists — either because no run is in flight, or because the previous
  /// run completed cleanly and the file was deleted by `clear`.
  func load(destinationId: String) -> AutoSyncRunJournal?

  /// Persists `journal` as the in-flight record for `destinationId`,
  /// replacing any prior value. Throws when the underlying store cannot
  /// complete the write.
  func save(_ journal: AutoSyncRunJournal, destinationId: String) throws

  /// Removes any stored journal for `destinationId`. No-op when no file
  /// exists. Called from the fan-out task's exit path to signal clean
  /// completion.
  func clear(destinationId: String) throws
}
