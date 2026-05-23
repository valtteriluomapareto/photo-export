import Foundation
import os

/// Production `AutoSyncCurrentRunStore` backed by JSON files at
/// `AutoSync/destinations/<destinationId>/currentRun.json`. Mirrors
/// `FileBackedAutoSyncRunSummaryStore` in shape and contract; the new store is
/// a separate type because its semantics differ (deleted on clean finish, not
/// the latest-version-wins pattern of the run summary).
///
/// Decode failures return `nil` (treated as "no journal in flight"). A corrupt
/// or schema-mismatched file does not block AutoSync on launch; the next
/// successful `save` replaces the bad file.
///
/// **Parent-directory fsync.** This is the load-bearing detail vs. the run
/// summary store. The journal exists to survive SIGKILL — power-loss not
/// being a concern, but kernel-initiated process termination is. After the
/// atomic rename `Data.write(to:options:.atomic)` performs, the directory
/// entry pointing at the new file is in the FS page cache but may not be on
/// disk yet. A SIGKILL won't flush it; a panic would lose it. For the OS-kill
/// case the page cache survives (process death doesn't dirty the page cache),
/// so technically `fsync` of the parent dir isn't strictly required for the
/// stated symptom. We do it anyway because (a) `JSONLRecordFile` already pays
/// this cost for the same reason in its own atomic writes, (b) it's one
/// `fsync` per fan-out boundary (≤5 per run), and (c) the marginal latency
/// is well under the latency of the AutoSync run itself.
///
/// The fsync call is routed through a `DirectoryFsyncing` protocol seam so
/// tests can record invocations and prove the call happens — a future
/// refactor that drops the fsync would otherwise compile and pass every
/// behavioral test, silently re-introducing the durability gap this store
/// was specifically architected to close.
@MainActor
final class FileBackedAutoSyncCurrentRunStore: AutoSyncCurrentRunStore {
  private let baseDirectoryURL: URL
  private let fileManager: FileManager
  private let directoryFsync: any DirectoryFsyncing
  private let logger: Logger

  init(
    baseDirectoryURL: URL,
    fileManager: FileManager = .default,
    directoryFsync: any DirectoryFsyncing = ProductionDirectoryFsync(),
    logger: Logger = Logger(
      subsystem: "com.valtteriluoma.photo-export", category: "AutoSyncCurrentRunStore")
  ) {
    self.baseDirectoryURL = baseDirectoryURL
    self.fileManager = fileManager
    self.directoryFsync = directoryFsync
    self.logger = logger
  }

  func load(destinationId: String) -> AutoSyncRunJournal? {
    let url = fileURL(for: destinationId)
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    do {
      let data = try Data(contentsOf: url)
      return try JSONDecoder().decode(AutoSyncRunJournal.self, from: data)
    } catch {
      logger.error(
        "Failed to decode current-run journal at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public). Returning nil; next save will overwrite."
      )
      return nil
    }
  }

  func save(_ journal: AutoSyncRunJournal, destinationId: String) throws {
    let url = fileURL(for: destinationId)
    try ensureDirectoryExists(for: url)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    let data = try encoder.encode(journal)
    try data.write(to: url, options: .atomic)
    directoryFsync.fsyncDirectory(url.deletingLastPathComponent())
  }

  func clear(destinationId: String) throws {
    let url = fileURL(for: destinationId)
    guard fileManager.fileExists(atPath: url.path) else { return }
    try fileManager.removeItem(at: url)
    directoryFsync.fsyncDirectory(url.deletingLastPathComponent())
  }

  private func fileURL(for destinationId: String) -> URL {
    baseDirectoryURL
      .appendingPathComponent(destinationId, isDirectory: true)
      .appendingPathComponent("currentRun.json")
  }

  private func ensureDirectoryExists(for fileURL: URL) throws {
    let dir = fileURL.deletingLastPathComponent()
    if !fileManager.fileExists(atPath: dir.path) {
      try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    }
  }
}
