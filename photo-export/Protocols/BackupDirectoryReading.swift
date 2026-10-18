import Foundation

/// Read-only directory/type inspection for backup scanning, with explicit IO failures.
protocol BackupDirectoryReading: Sendable {
  func contentsOfDirectory(at url: URL, keys: [URLResourceKey]) throws -> [URL]
  func resourceValues(at url: URL, keys: Set<URLResourceKey>) throws -> URLResourceValues
}

struct ProductionBackupDirectoryReader: BackupDirectoryReading {
  func contentsOfDirectory(at url: URL, keys: [URLResourceKey]) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
      at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
  }

  func resourceValues(at url: URL, keys: Set<URLResourceKey>) throws -> URLResourceValues {
    try url.resourceValues(forKeys: keys)
  }
}

struct BackupScanReadError: LocalizedError {
  let path: String
  let detail: String
  var errorDescription: String? { "Could not read backup path \(path): \(detail)" }
}
