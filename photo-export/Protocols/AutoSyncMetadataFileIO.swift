import Darwin
import Foundation

/// Narrow IO boundary for the two recoverable AutoSync JSON files.
protocol AutoSyncMetadataFileIO: Sendable {
  func readIfPresent(at url: URL) throws -> Data?
  func preserve(_ data: Data, at url: URL) throws
  func writeAtomically(_ data: Data, to url: URL) throws
}

struct ProductionAutoSyncMetadataFileIO: AutoSyncMetadataFileIO {
  func readIfPresent(at url: URL) throws -> Data? {
    do {
      return try Data(contentsOf: url)
    } catch {
      let nsError = error as NSError
      let missing =
        (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError)
        || (nsError.domain == NSPOSIXErrorDomain && nsError.code == ENOENT)
      // A dangling symlink is an existing unreadable source, not a new store.
      var metadata = stat()
      if missing && lstat(url.path, &metadata) != 0 && errno == ENOENT { return nil }
      throw error
    }
  }

  func preserve(_ data: Data, at url: URL) throws {
    try data.write(to: url, options: .withoutOverwriting)
  }

  func writeAtomically(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .atomic)
  }
}
