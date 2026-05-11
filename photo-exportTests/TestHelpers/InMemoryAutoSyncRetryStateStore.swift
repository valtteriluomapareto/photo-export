import Foundation

@testable import Photo_Export

/// In-memory `AutoSyncRetryStateStore` for tests. Mirrors `InMemoryAutoSyncDirtyStateStore`
/// — including the fault-injection knobs (`nextSaveError`, `nextDeleteError`) so tests can
/// pin error-handling logic in callers.
@MainActor
final class InMemoryAutoSyncRetryStateStore: AutoSyncRetryStateStore {
  private var storage: [String: AutoSyncRetryState]

  /// If non-nil, the next call to `save` throws this error and clears the slot.
  var nextSaveError: Error?
  /// If non-nil, the next call to `deleteState` throws this error and clears the slot.
  var nextDeleteError: Error?

  init(initial: [String: AutoSyncRetryState] = [:]) {
    self.storage = initial
  }

  func load(destinationId: String) -> AutoSyncRetryState {
    storage[destinationId] ?? .empty
  }

  func save(_ state: AutoSyncRetryState, destinationId: String) throws {
    if let error = nextSaveError {
      nextSaveError = nil
      throw error
    }
    storage[destinationId] = state
  }

  func deleteState(destinationId: String) throws {
    if let error = nextDeleteError {
      nextDeleteError = nil
      throw error
    }
    storage.removeValue(forKey: destinationId)
  }

  /// Test-only inspection — destinations the store currently has entries for.
  var savedDestinationIds: Set<String> {
    Set(storage.keys)
  }
}
