import Foundation

/// Abstracts file system operations for testability.
/// FileIOService conforms in production; tests inject a fake.
protocol FileSystemService: Sendable {
  func moveItemAtomically(from src: URL, to dst: URL) throws
  func applyTimestamps(creationDate: Date, to url: URL)
  func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws
  func fileExists(atPath: String) -> Bool
  func removeItem(at url: URL) throws
  /// Moves `url` to the macOS Trash instead of deleting it, so cleanup
  /// deletions stay recoverable until the Trash is emptied. Returns the
  /// item's new location in the Trash when the volume supports it.
  func trashItem(at url: URL) throws -> URL?
  /// Copies a file from `src` to `dst`. On APFS volumes (typical for the user's chosen
  /// destination), `FileManager.copyItem(at:to:)` performs copy-on-write at the
  /// filesystem layer, so duplicates use no extra bytes until either copy is modified.
  /// On non-APFS destinations this is a real copy. The reuse-source path in
  /// `ExportManager.exportSingleVariant` calls this when an asset is already exported
  /// elsewhere, avoiding a PhotoKit re-fetch.
  func copyItem(from src: URL, to dst: URL) throws
}

extension FileSystemService {
  /// Default: no Trash support — permanent removal. Production
  /// (`FileIOService`) and the test fake override this.
  func trashItem(at url: URL) throws -> URL? {
    try removeItem(at: url)
    return nil
  }
}
