import Foundation

/// Persists `AutoSyncDirtyState` per destination. The production implementation lives in
/// App Support (`AutoSync/destinations/<destinationId>/dirtyState.json`); the in-memory
/// variant in `photo-exportTests/TestHelpers/` powers reducer and state-machine tests
/// without disk IO.
@MainActor
protocol AutoSyncDirtyStateStore: AnyObject {
  /// Loads the state for a destination, returning `.empty` when no record exists.
  func load(destinationId: String) -> AutoSyncDirtyState

  /// Persists `state` for `destinationId`, replacing any prior value. Throws when the
  /// underlying store cannot complete the write (e.g., disk full); the caller decides
  /// whether to log, surface, or retry.
  func save(_ state: AutoSyncDirtyState, destinationId: String) throws

  /// Removes any stored state for `destinationId`. Used when the destination's record store
  /// is deleted or the user explicitly clears auto-sync state from settings.
  func deleteState(destinationId: String) throws
}
