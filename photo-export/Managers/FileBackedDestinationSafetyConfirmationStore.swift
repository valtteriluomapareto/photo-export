import Foundation
import os

/// Production `DestinationSafetyConfirmationStore`. Marker file at
/// `AutoSync/destinations/<destinationId>/safetyRecord.json` carrying the
/// confirmation timestamp. Presence of the file = confirmed; absence =
/// not confirmed. The file's contents are diagnostic — the truth value is
/// `fileExists`.
@MainActor
final class FileBackedDestinationSafetyConfirmationStore:
  DestinationSafetyConfirmationStore
{
  private let baseDirectoryURL: URL
  private let fileManager: FileManager
  private let logger: Logger

  init(
    baseDirectoryURL: URL,
    fileManager: FileManager = .default,
    logger: Logger = Logger(
      subsystem: "com.valtteriluoma.photo-export", category: "DestinationSafety")
  ) {
    self.baseDirectoryURL = baseDirectoryURL
    self.fileManager = fileManager
    self.logger = logger
  }

  func isConfirmed(destinationId: String) -> Bool {
    fileManager.fileExists(atPath: fileURL(for: destinationId).path)
  }

  func confirm(destinationId: String) throws {
    let url = fileURL(for: destinationId)
    try ensureDirectoryExists(for: url)
    let body = SafetyRecord(confirmedAt: Date())
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    let data = try encoder.encode(body)
    try data.write(to: url, options: .atomic)
  }

  func unconfirm(destinationId: String) throws {
    let url = fileURL(for: destinationId)
    guard fileManager.fileExists(atPath: url.path) else { return }
    try fileManager.removeItem(at: url)
  }

  private struct SafetyRecord: Codable {
    let confirmedAt: Date
  }

  private func fileURL(for destinationId: String) -> URL {
    baseDirectoryURL
      .appendingPathComponent(destinationId, isDirectory: true)
      .appendingPathComponent("safetyRecord.json")
  }

  private func ensureDirectoryExists(for fileURL: URL) throws {
    let dir = fileURL.deletingLastPathComponent()
    if !fileManager.fileExists(atPath: dir.path) {
      try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    }
  }
}
