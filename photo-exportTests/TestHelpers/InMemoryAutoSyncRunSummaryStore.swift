import Foundation

@testable import Photo_Export

/// In-memory `AutoSyncRunSummaryStore` for tests. Mirrors the pattern in
/// `InMemoryAutoSyncDirtyStateStore`: simple dictionary backing,
/// `nextSaveError` / `nextDeleteError` knobs for fault-injection.
@MainActor
final class InMemoryAutoSyncRunSummaryStore: AutoSyncRunSummaryStore {
  private var storage: [String: ExportRunSummary]

  var nextSaveError: Error?
  var nextDeleteError: Error?

  init(initial: [String: ExportRunSummary] = [:]) {
    self.storage = initial
  }

  func load(destinationId: String) -> ExportRunSummary? {
    storage[destinationId]
  }

  func save(_ summary: ExportRunSummary, destinationId: String) throws {
    if let error = nextSaveError {
      nextSaveError = nil
      throw error
    }
    storage[destinationId] = summary
  }

  func deleteSummary(destinationId: String) throws {
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
