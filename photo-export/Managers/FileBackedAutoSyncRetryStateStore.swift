import Foundation
import os

/// Production `AutoSyncRetryStateStore` backed by JSON files under
/// `AutoSync/destinations/<destinationId>/retryState.json`. Mirrors
/// `FileBackedAutoSyncDirtyStateStore` in shape and contract.
///
/// Decode failures return `.empty` rather than throwing so a corrupt file does not
/// block AutoSync on launch — the next successful save replaces the bad file.
@MainActor
final class FileBackedAutoSyncRetryStateStore: AutoSyncRetryStateStore {
  private let baseDirectoryURL: URL
  private let fileManager: FileManager
  private let logger: Logger

  init(
    baseDirectoryURL: URL,
    fileManager: FileManager = .default,
    logger: Logger = Logger(
      subsystem: "com.valtteriluoma.photo-export", category: "AutoSyncRetryStore")
  ) {
    self.baseDirectoryURL = baseDirectoryURL
    self.fileManager = fileManager
    self.logger = logger
  }

  func load(destinationId: String) -> AutoSyncRetryState {
    let url = fileURL(for: destinationId)
    guard fileManager.fileExists(atPath: url.path) else { return .empty }
    do {
      let data = try Data(contentsOf: url)
      return try JSONDecoder().decode(AutoSyncRetryState.self, from: data)
    } catch {
      logger.error(
        "Failed to decode retry state at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public). Returning .empty; next save will overwrite."
      )
      return .empty
    }
  }

  func save(_ state: AutoSyncRetryState, destinationId: String) throws {
    let url = fileURL(for: destinationId)
    try ensureDirectoryExists(for: url)
    let data = try JSONEncoder().encode(state)
    try data.write(to: url, options: .atomic)
  }

  func deleteState(destinationId: String) throws {
    let url = fileURL(for: destinationId)
    guard fileManager.fileExists(atPath: url.path) else { return }
    try fileManager.removeItem(at: url)
  }

  private func fileURL(for destinationId: String) -> URL {
    baseDirectoryURL
      .appendingPathComponent(destinationId, isDirectory: true)
      .appendingPathComponent("retryState.json")
  }

  private func ensureDirectoryExists(for fileURL: URL) throws {
    let dir = fileURL.deletingLastPathComponent()
    if !fileManager.fileExists(atPath: dir.path) {
      try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    }
  }
}
