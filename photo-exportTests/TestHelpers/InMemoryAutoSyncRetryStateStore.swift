import Foundation

@testable import Photo_Export

/// In-memory `AutoSyncRetryStateStore` for tests. Mirrors `InMemoryAutoSyncDirtyStateStore`
/// in shape and contract.
@MainActor
final class InMemoryAutoSyncRetryStateStore: AutoSyncRetryStateStore {
  private var storage: [String: AutoSyncRetryState]

  init(initial: [String: AutoSyncRetryState] = [:]) {
    self.storage = initial
  }

  func load(destinationId: String) -> AutoSyncRetryState {
    storage[destinationId] ?? .empty
  }

  func save(_ state: AutoSyncRetryState, destinationId: String) throws {
    storage[destinationId] = state
  }

  func deleteState(destinationId: String) throws {
    storage.removeValue(forKey: destinationId)
  }

  /// Test-only inspection — destinations the store currently has entries for.
  var savedDestinationIds: Set<String> {
    Set(storage.keys)
  }
}
