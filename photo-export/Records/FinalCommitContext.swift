import Foundation

/// MainActor-owned history retained only while a final file commit is outstanding.
/// Reuses the store's serial JSONL writer and follows its latest destination state.
@MainActor
final class FinalCommitContext<Snapshot: Codable & Sendable, Mutation: Codable & Sendable> {
  let destinationId: String
  var file: JSONLRecordFile<Snapshot, Mutation>
  var snapshot: Snapshot
  var needsCorruptionRecovery = false

  init(destinationId: String, file: JSONLRecordFile<Snapshot, Mutation>, snapshot: Snapshot) {
    self.destinationId = destinationId
    self.file = file
    self.snapshot = snapshot
  }
}

/// Where a store put an acknowledged final commit, and so whose write it still owes a flush.
enum FinalCommitLanding: Equatable {
  /// Deferred behind a corrupt load or held while its destination loads; nothing written yet.
  case held
  /// Recorded in the active history through the store's ordinary append.
  case recorded
  /// Written to the parked history of a destination the store is no longer configured for.
  case parked
}
