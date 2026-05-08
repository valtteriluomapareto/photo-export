import Foundation

@testable import Photo_Export

/// In-memory `AutoSyncPerDestinationTokenStore` for tests. Mirrors the pattern
/// in `InMemoryAutoSyncDirtyStateStore`.
@MainActor
final class InMemoryAutoSyncPerDestinationTokenStore: AutoSyncPerDestinationTokenStore {
  private var storage: [String: Data]

  var nextSaveError: Error?
  var nextDeleteError: Error?

  init(initial: [String: Data] = [:]) {
    self.storage = initial
  }

  func load(destinationId: String) -> Data? {
    storage[destinationId]
  }

  func save(_ token: Data, destinationId: String) throws {
    if let error = nextSaveError {
      nextSaveError = nil
      throw error
    }
    storage[destinationId] = token
  }

  func deleteToken(destinationId: String) throws {
    if let error = nextDeleteError {
      nextDeleteError = nil
      throw error
    }
    storage.removeValue(forKey: destinationId)
  }

  var savedDestinationIds: Set<String> {
    Set(storage.keys)
  }
}
