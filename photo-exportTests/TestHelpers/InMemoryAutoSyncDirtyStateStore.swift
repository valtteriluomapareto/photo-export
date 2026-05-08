import Foundation

@testable import Photo_Export

/// In-memory `AutoSyncDirtyStateStore` for tests. No disk IO; throws never; preserves the
/// production contract of returning `.empty` for unknown destinations.
@MainActor
final class InMemoryAutoSyncDirtyStateStore: AutoSyncDirtyStateStore {
  private var storage: [String: AutoSyncDirtyState]

  init(initial: [String: AutoSyncDirtyState] = [:]) {
    self.storage = initial
  }

  func load(destinationId: String) -> AutoSyncDirtyState {
    storage[destinationId] ?? .empty
  }

  func save(_ state: AutoSyncDirtyState, destinationId: String) throws {
    storage[destinationId] = state
  }

  func deleteState(destinationId: String) throws {
    storage.removeValue(forKey: destinationId)
  }

  /// Test-only inspection — returns the destinationIds the store currently has entries for.
  var savedDestinationIds: Set<String> {
    Set(storage.keys)
  }
}
