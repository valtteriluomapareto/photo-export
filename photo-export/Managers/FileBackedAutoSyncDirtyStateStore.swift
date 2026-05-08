import Foundation
import os

/// Production `AutoSyncDirtyStateStore` backed by JSON files under
/// `AutoSync/destinations/<destinationId>/dirtyState.json`. The file is rewritten
/// atomically on every save (write-temp + rename) so a crash mid-write either keeps the
/// previous version or has no file at all — never a half-written one.
///
/// Decoding errors are surfaced as `.empty` rather than thrown so a corrupt or
/// schema-mismatched file does not block the AutoSync state machine on launch. The
/// failure is logged via `os.Logger`; the next successful save replaces the bad file.
@MainActor
final class FileBackedAutoSyncDirtyStateStore: AutoSyncDirtyStateStore {
  private let baseDirectoryURL: URL
  private let fileManager: FileManager
  private let logger: Logger

  /// `baseDirectoryURL` is the root for AutoSync persistence — typically
  /// `<App Support>/<bundle-id>/AutoSync/destinations/`. The store appends
  /// `<destinationId>/dirtyState.json` inside that root.
  init(
    baseDirectoryURL: URL,
    fileManager: FileManager = .default,
    logger: Logger = Logger(
      subsystem: "com.valtteriluoma.photo-export", category: "AutoSyncDirtyStore")
  ) {
    self.baseDirectoryURL = baseDirectoryURL
    self.fileManager = fileManager
    self.logger = logger
  }

  func load(destinationId: String) -> AutoSyncDirtyState {
    let url = fileURL(for: destinationId)
    guard fileManager.fileExists(atPath: url.path) else { return .empty }
    do {
      let data = try Data(contentsOf: url)
      return try JSONDecoder().decode(AutoSyncDirtyState.self, from: data)
    } catch {
      logger.error(
        "Failed to decode dirty state at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public). Returning .empty; next save will overwrite."
      )
      return .empty
    }
  }

  func save(_ state: AutoSyncDirtyState, destinationId: String) throws {
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
      .appendingPathComponent("dirtyState.json")
  }

  private func ensureDirectoryExists(for fileURL: URL) throws {
    let dir = fileURL.deletingLastPathComponent()
    if !fileManager.fileExists(atPath: dir.path) {
      try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    }
  }
}
