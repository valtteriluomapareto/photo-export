import Foundation
import os

/// Owns the lifecycle of the per-destination `ExportRecords/<destinationId>/` directory.
///
/// Phase 0 of the collections-export plan replaced the bookmark-hash-based `destinationId`
/// with a stable volume-UUID + canonical-path derivation. The auto-sync plan's Phase 0a then
/// changed the *low-confidence* fallback (drives without a volume UUID — exFAT, network
/// shares) from a `volumeIdentifier`-based digest to a `standardizedPath`-only digest, since
/// `volumeIdentifier` is a same-session-only token. On upgrade, existing users have records
/// under one of two possible legacy directory names; this coordinator renames the first
/// matching legacy directory to `ExportRecords/<newId>/` once before any record store calls
/// `configure(for: newId)`.
///
/// Centralizing the rename here is load-bearing for the two-store design: with two stores
/// both calling `configure(for: newId)`, whichever ran first would create `<newId>/` and
/// cause the other store's lazy-migration check to see `<newId>` already present, leaving
/// `<legacyId>/` orphaned. Running the migration once, before any store touches the
/// directory, prevents this.
struct ExportRecordsDirectoryCoordinator {
  enum DirectoryPrepareError: Error, Equatable {
    /// Both `<newId>/` and at least one `<legacyId>/` exist on disk. Should not happen in
    /// normal use; the coordinator does not merge or delete either, leaving the legacy
    /// directory for manual inspection. Callers should proceed with `<newId>/` as-is.
    case conflict(newId: String, legacyId: String)
    /// The legacy → new directory rename failed (filesystem error). The on-disk state is
    /// unchanged; the next launch will attempt the rename again.
    case migrationFailed(message: String)
  }

  let storeRootURL: URL
  let fileManager: FileManager
  private let logger: Logger

  init(
    storeRootURL: URL,
    fileManager: FileManager = .default,
    logger: Logger = Logger(
      subsystem: "com.valtteriluoma.photo-export", category: "ExportRecordsDirectory")
  ) {
    self.storeRootURL = storeRootURL
    self.fileManager = fileManager
    self.logger = logger
  }

  /// Ensures `ExportRecords/<newId>/` is the directory record stores should use.
  ///
  /// Algorithm:
  /// 1. If `<newId>/` already exists, use it. (Conflict logged if any `<legacyId>/` also
  ///    exists; the *first* matching legacy id is reported in the conflict.)
  /// 2. Otherwise, walk `legacyIds` in order and rename the first existing directory to
  ///    `<newId>/`. Subsequent legacy directories (if multiple migrations pile up) are
  ///    left in place; the rename is one-shot per launch by design — extra legacy dirs
  ///    surface as the conflict case on the next migration if they ever line up with a
  ///    future `<newId>`.
  /// 3. Otherwise, treat the destination as fresh — record stores will create `<newId>/`
  ///    on their first write.
  ///
  /// The coordinator does not create `<newId>/` itself; that's the record store's job.
  ///
  /// `legacyIds` is the list of pre-Phase-0a forms in priority order. Pass an empty array
  /// when no legacy migration applies. The list typically holds the bookmark-hash legacy id
  /// first and the pre-Phase-0a low-confidence (`volumeIdentifier`-based) id second; only
  /// non-nil values are passed in by callers.
  func prepareDirectory(
    for newId: String, legacyIds: [String]
  ) -> Result<Void, DirectoryPrepareError> {
    let newDir = storeRootURL.appendingPathComponent(newId, isDirectory: true)
    let newDirExists = fileManager.fileExists(atPath: newDir.path)

    // Filter legacy ids that resolve to a directory other than `<newId>` and that exist
    // on disk. Equality is by URL so that a legacy id that happens to equal `newId`
    // (would only happen if the derivation regressed) is skipped silently.
    let existingLegacy: [(id: String, url: URL)] = legacyIds.compactMap { id in
      let dir = storeRootURL.appendingPathComponent(id, isDirectory: true)
      guard dir != newDir, fileManager.fileExists(atPath: dir.path) else { return nil }
      return (id, dir)
    }

    if newDirExists {
      if let firstConflict = existingLegacy.first {
        logger.error(
          "Conflict: ExportRecords/\(newId, privacy: .public)/ and legacy ExportRecords/\(firstConflict.id, privacy: .public)/ both exist; using <newId>, legacy directory left untouched."
        )
        return .failure(.conflict(newId: newId, legacyId: firstConflict.id))
      }
      return .success(())
    }

    if let firstLegacy = existingLegacy.first {
      do {
        try fileManager.moveItem(at: firstLegacy.url, to: newDir)
        logger.info(
          "Migrated ExportRecords/\(firstLegacy.id, privacy: .public)/ → ExportRecords/\(newId, privacy: .public)/"
        )
        return .success(())
      } catch {
        logger.error(
          "Failed to migrate legacy ExportRecords directory: \(error.localizedDescription, privacy: .public)"
        )
        return .failure(.migrationFailed(message: error.localizedDescription))
      }
    }

    return .success(())
  }
}
