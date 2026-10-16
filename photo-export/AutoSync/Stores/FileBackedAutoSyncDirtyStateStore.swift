import Foundation
import os

/// Main-actor DirtyState persistence. Missing files are empty; failures throw.
/// Corrupt bytes are preserved before replacement; unreadable sources cannot be replaced.
@MainActor
final class FileBackedAutoSyncDirtyStateStore: AutoSyncDirtyStateStore {
  private let baseDirectoryURL: URL
  private let fileManager: FileManager
  private let logger: Logger
  private let io: any AutoSyncMetadataFileIO

  /// `baseDirectoryURL` is the root for AutoSync persistence — typically
  /// `<App Support>/<bundle-id>/AutoSync/destinations/`. The store appends
  /// `<destinationId>/dirtyState.json` inside that root.
  init(
    baseDirectoryURL: URL,
    fileManager: FileManager = .default,
    io: any AutoSyncMetadataFileIO = ProductionAutoSyncMetadataFileIO(),
    logger: Logger = Logger(
      subsystem: "com.valtteriluoma.photo-export", category: "AutoSyncDirtyStore")
  ) {
    self.baseDirectoryURL = baseDirectoryURL
    self.fileManager = fileManager
    self.logger = logger
    self.io = io
  }

  func load(destinationId: String) throws -> AutoSyncDirtyState {
    do {
      return try file(for: destinationId).load() ?? .empty
    } catch {
      logger.error("Failed to load Auto Export metadata: \(error.localizedDescription, privacy: .public). Original preserved.")
      throw error
    }
  }

  func save(_ state: AutoSyncDirtyState, destinationId: String) throws {
    try file(for: destinationId).save(state)
  }

  private func file(for destinationId: String) -> AutoSyncJSONFile<AutoSyncDirtyState> {
    AutoSyncJSONFile(url: fileURL(for: destinationId), fileManager: fileManager, io: io)
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

}
