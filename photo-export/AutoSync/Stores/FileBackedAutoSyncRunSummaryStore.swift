import Foundation
import os

/// Production `AutoSyncRunSummaryStore` backed by JSON files at
/// `AutoSync/destinations/<destinationId>/lastRunSummary.json`. Mirrors
/// `FileBackedAutoSyncDirtyStateStore` in shape and contract.
///
/// Decode failures return `nil` (treated as "no prior summary") so a corrupt
/// or schema-mismatched file does not block Auto Export status rendering on
/// launch. The next successful save replaces the bad file.
@MainActor
final class FileBackedAutoSyncRunSummaryStore: AutoSyncRunSummaryStore {
  private let baseDirectoryURL: URL
  private let fileManager: FileManager
  private let logger: Logger

  init(
    baseDirectoryURL: URL,
    fileManager: FileManager = .default,
    logger: Logger = Logger(
      subsystem: "com.valtteriluoma.photo-export", category: "AutoSyncRunSummaryStore")
  ) {
    self.baseDirectoryURL = baseDirectoryURL
    self.fileManager = fileManager
    self.logger = logger
  }

  func load(destinationId: String) -> ExportRunSummary? {
    let url = fileURL(for: destinationId)
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    do {
      let data = try Data(contentsOf: url)
      return try JSONDecoder().decode(ExportRunSummary.self, from: data)
    } catch {
      logger.error(
        "Failed to decode run summary at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public). Returning nil; next save will overwrite."
      )
      return nil
    }
  }

  func save(_ summary: ExportRunSummary, destinationId: String) throws {
    let url = fileURL(for: destinationId)
    try ensureDirectoryExists(for: url)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    let data = try encoder.encode(summary)
    try data.write(to: url, options: .atomic)
  }

  func deleteSummary(destinationId: String) throws {
    let url = fileURL(for: destinationId)
    guard fileManager.fileExists(atPath: url.path) else { return }
    try fileManager.removeItem(at: url)
  }

  private func fileURL(for destinationId: String) -> URL {
    baseDirectoryURL
      .appendingPathComponent(destinationId, isDirectory: true)
      .appendingPathComponent("lastRunSummary.json")
  }

  private func ensureDirectoryExists(for fileURL: URL) throws {
    let dir = fileURL.deletingLastPathComponent()
    if !fileManager.fileExists(atPath: dir.path) {
      try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    }
  }
}
