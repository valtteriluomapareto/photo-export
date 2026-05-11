import Foundation

@testable import Photo_Export

/// Test error used by the in-memory stores when a `nextSaveError` / `nextLoadError` /
/// `nextDeleteError` knob is set. Lets tests assert that callers correctly propagate
/// thrown failures without depending on a real filesystem failure.
struct InMemoryAutoSyncStoreError: Error, Equatable, Sendable {
  let label: String
  init(_ label: String = "test") {
    self.label = label
  }
}

/// In-memory `AutoSyncDirtyStateStore` for tests. No disk IO. Production callers can throw
/// from `save` / `deleteState`, so the test double exposes optional `next*Error` knobs for
/// fault-injection — set the knob, call the operation, and the corresponding error is
/// thrown once and then cleared.
@MainActor
final class InMemoryAutoSyncDirtyStateStore: AutoSyncDirtyStateStore {
  private var storage: [String: AutoSyncDirtyState]

  /// If non-nil, the next call to `save` throws this error and clears the slot.
  var nextSaveError: Error?
  /// If non-nil, the next call to `deleteState` throws this error and clears the slot.
  var nextDeleteError: Error?

  init(initial: [String: AutoSyncDirtyState] = [:]) {
    self.storage = initial
  }

  func load(destinationId: String) -> AutoSyncDirtyState {
    storage[destinationId] ?? .empty
  }

  func save(_ state: AutoSyncDirtyState, destinationId: String) throws {
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
