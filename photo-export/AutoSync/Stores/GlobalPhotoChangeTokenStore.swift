import Foundation
import Photos
import os

/// File-backed store for the global Photos persistent-change token. Plan
/// §"Persistence Keys": `AutoSync/photo-library-change-token.data` — a single
/// file under App Support carrying the most recent `PHPersistentChangeToken` the
/// observer has seen. Per-destination snapshots are tracked separately by the
/// reducer's dirty state.
///
/// The token is `NSSecureCoding`-archived. A failed decode (corrupt file,
/// schema-incompatible token from a future macOS release) returns nil so the
/// adapter starts fresh — better than crashing the app on launch.
@MainActor
final class GlobalPhotoChangeTokenStore {
  private let fileURL: URL
  private let fileManager: FileManager
  private let logger: Logger

  init(
    fileURL: URL,
    fileManager: FileManager = .default,
    logger: Logger = Logger(
      subsystem: "com.valtteriluoma.photo-export", category: "PhotoChangeToken")
  ) {
    self.fileURL = fileURL
    self.fileManager = fileManager
    self.logger = logger
  }

  func load() -> PHPersistentChangeToken? {
    guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
    do {
      let data = try Data(contentsOf: fileURL)
      let token = try NSKeyedUnarchiver.unarchivedObject(
        ofClass: PHPersistentChangeToken.self, from: data)
      return token
    } catch {
      logger.error(
        "Failed to load persistent-change token at \(self.fileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public). Starting fresh."
      )
      return nil
    }
  }

  func save(_ token: PHPersistentChangeToken) {
    do {
      try ensureDirectoryExists()
      let data = try NSKeyedArchiver.archivedData(
        withRootObject: token, requiringSecureCoding: true)
      try data.write(to: fileURL, options: .atomic)
    } catch {
      logger.error(
        "Failed to save persistent-change token: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  private func ensureDirectoryExists() throws {
    let dir = fileURL.deletingLastPathComponent()
    if !fileManager.fileExists(atPath: dir.path) {
      try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    }
  }
}
