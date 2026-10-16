import Foundation

/// Persists `AutoSyncRetryState` per destination. Production uses a JSON file under
/// `AutoSync/destinations/<destinationId>/retryState.json`; tests use the in-memory variant
/// in `photo-exportTests/TestHelpers/`.
@MainActor
protocol AutoSyncRetryStateStore: AnyObject {
  /// Only a missing file is empty. Corruption and inaccessible IO throw.
  func load(destinationId: String) throws -> AutoSyncRetryState

  /// Persists `state` for `destinationId`, replacing any prior value.
  func save(_ state: AutoSyncRetryState, destinationId: String) throws

  /// Removes any stored state for `destinationId`.
  func deleteState(destinationId: String) throws
}
