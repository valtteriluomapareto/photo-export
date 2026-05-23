import Foundation

@testable import Photo_Export

/// In-memory `AutoSyncCurrentRunStore` for tests. Mirrors the pattern in
/// `InMemoryAutoSyncRunSummaryStore`: simple dictionary backing, optional
/// `nextSaveError` / `nextClearError` knobs for fault-injection on the
/// next call only.
@MainActor
final class InMemoryAutoSyncCurrentRunStore: AutoSyncCurrentRunStore {
  private var storage: [String: AutoSyncRunJournal]

  var nextSaveError: Error?
  var nextClearError: Error?

  init(initial: [String: AutoSyncRunJournal] = [:]) {
    self.storage = initial
  }

  func load(destinationId: String) -> AutoSyncRunJournal? {
    storage[destinationId]
  }

  func save(_ journal: AutoSyncRunJournal, destinationId: String) throws {
    if let error = nextSaveError {
      nextSaveError = nil
      throw error
    }
    storage[destinationId] = journal
  }

  func clear(destinationId: String) throws {
    if let error = nextClearError {
      nextClearError = nil
      throw error
    }
    storage.removeValue(forKey: destinationId)
  }

  var savedDestinationIds: Set<String> {
    Set(storage.keys)
  }
}
