import Foundation

/// Replaces an internal persistence file in one atomic rename. Unlike exported media,
/// snapshots intentionally replace an existing file. Source and destination must be
/// on the same filesystem; a failed replacement must leave the destination intact.
protocol AtomicFileReplacing: Sendable {
  func replaceItemAtomically(from source: URL, to destination: URL) throws
}
