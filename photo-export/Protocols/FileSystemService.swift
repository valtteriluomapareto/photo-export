import Foundation

/// Abstracts file system operations for testability.
/// FileIOService conforms in production; tests inject a fake.
protocol FileSystemService: Sendable {
  func moveItemAtomically(from src: URL, to dst: URL) throws
  func applyTimestamps(creationDate: Date, to url: URL)
  func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws
  func fileExists(atPath: String) -> Bool
  func removeItem(at url: URL) throws
  /// Copies a file from `src` to `dst`. On APFS volumes (typical for the user's chosen
  /// destination), `FileManager.copyItem(at:to:)` performs copy-on-write at the
  /// filesystem layer, so duplicates use no extra bytes until either copy is modified.
  /// On non-APFS destinations this is a real copy. The reuse-source path in
  /// `VariantExporter` invokes this synchronous primitive on an explicit utility
  /// worker and awaits physical completion before releasing destination access.
  func copyItem(from src: URL, to dst: URL) throws
}
