import Foundation

/// Counts of cleanup work performed during one export run, accumulated across the
/// enqueue phase of every scope the run covered. Surfaced in:
/// - the toolbar's empty-run message (so a mirroring run that deletes files but
///   enqueues nothing doesn't read as "already exported"), and
/// - `ExportRunSummary.cleanup`, which AutoSync's run summary store persists and
///   Settings → Auto Export renders.
///
/// All counts are per-run deltas, never cumulative across runs.
struct ExportCleanupSummary: Codable, Equatable, Sendable {
  /// Files removed from the destination because their source asset no longer
  /// exists in the library ("Remove deleted files") or because a re-export
  /// replaced a variant under a new filename ("Replace updated files" cleanup).
  var removedFiles: Int
  /// Records removed from the record stores for those assets, plus the count of
  /// stale-album placements dropped (the automatic folder-structure cleanup
  /// that "Remove deleted files" implies).
  var removedRecords: Int
  /// Empty directories removed bottom-up (automatic folder-structure
  /// cleanup).
  var removedFolders: Int

  static let zero = ExportCleanupSummary(removedFiles: 0, removedRecords: 0, removedFolders: 0)

  var totalRemoved: Int { removedFiles + removedRecords + removedFolders }

  var isEmpty: Bool { totalRemoved == 0 }

  /// Combines another summary into this one (mutating union of counts).
  mutating func accumulate(_ other: ExportCleanupSummary) {
    removedFiles += other.removedFiles
    removedRecords += other.removedRecords
    removedFolders += other.removedFolders
  }

  func accumulating(_ other: ExportCleanupSummary) -> ExportCleanupSummary {
    var copy = self
    copy.accumulate(other)
    return copy
  }

  /// One-line user-facing rendering for the toolbar message slot.
  var userMessage: String {
    var parts: [String] = []
    if removedFiles > 0 {
      parts.append(
        removedFiles == 1 ? "removed 1 deleted file" : "removed \(removedFiles) deleted files")
    }
    if removedRecords > 0 {
      parts.append(
        removedRecords == 1 ? "cleared 1 stale record" : "cleared \(removedRecords) stale records")
    }
    if removedFolders > 0 {
      parts.append(
        removedFolders == 1 ? "deleted 1 empty folder" : "deleted \(removedFolders) empty folders")
    }
    guard !parts.isEmpty else { return "" }
    return "Cleanup " + parts.joined(separator: ", ") + "."
  }
}
