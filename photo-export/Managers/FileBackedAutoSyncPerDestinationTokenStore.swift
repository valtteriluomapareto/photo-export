import Foundation
import os

/// Production `AutoSyncPerDestinationTokenStore` backed by raw `Data` files at
/// `AutoSync/destinations/<destinationId>/lastDurablyRecordedToken.data`. The
/// token is opaque to this store — it's the same NSKeyedArchiver-archived
/// `PHPersistentChangeToken` blob the global token store writes, just keyed
/// per destination so destinations resume from their own cursor after the
/// global observer has moved on.
@MainActor
final class FileBackedAutoSyncPerDestinationTokenStore: AutoSyncPerDestinationTokenStore {
  private let baseDirectoryURL: URL
  private let fileManager: FileManager
  private let logger: Logger

  init(
    baseDirectoryURL: URL,
    fileManager: FileManager = .default,
    logger: Logger = Logger(
      subsystem: "com.valtteriluoma.photo-export", category: "AutoSyncPerDestTokenStore")
  ) {
    self.baseDirectoryURL = baseDirectoryURL
    self.fileManager = fileManager
    self.logger = logger
  }

  func load(destinationId: String) -> Data? {
    let url = fileURL(for: destinationId)
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    do {
      return try Data(contentsOf: url)
    } catch {
      logger.error(
        "Failed to read per-destination token at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public). Returning nil; next save will overwrite."
      )
      return nil
    }
  }

  func save(_ token: Data, destinationId: String) throws {
    let url = fileURL(for: destinationId)
    try ensureDirectoryExists(for: url)
    try token.write(to: url, options: .atomic)
  }

  func deleteToken(destinationId: String) throws {
    let url = fileURL(for: destinationId)
    guard fileManager.fileExists(atPath: url.path) else { return }
    try fileManager.removeItem(at: url)
  }

  private func fileURL(for destinationId: String) -> URL {
    baseDirectoryURL
      .appendingPathComponent(destinationId, isDirectory: true)
      .appendingPathComponent("lastDurablyRecordedToken.data")
  }

  private func ensureDirectoryExists(for fileURL: URL) throws {
    let dir = fileURL.deletingLastPathComponent()
    if !fileManager.fileExists(atPath: dir.path) {
      try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    }
  }
}
