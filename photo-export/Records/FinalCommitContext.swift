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
