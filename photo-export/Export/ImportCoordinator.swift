import Combine
import Foundation
import OSLog

/// Owns the Import Existing Backup flow: scanner invocation, library matching, bulk
/// record insertion, both-store reconciliation, and the per-stage progress publishing.
///
/// Per `docs/project/archive/software-architecture-improvement-plan.md` Phase 5, this
/// extraction:
/// - Moves the ~190-line `startImport` body (and `cancelImport`) out of `ExportManager`.
/// - Owns the published mirrors `isImporting` + `importStage` directly; ExportManager
///   sinks them onto its own `@Published` properties so `isImportingPublisher`
///   subscribers and SwiftUI view bindings keep emitting from the same source.
/// - Reaches the Phase-0 cancellation seam (`isCurrent` / `throwIfCancelledOrStale` /
///   `bumpGeneration`) directly through the injected `ExportQueueCoordinator`
///   reference, not via the host (issue #67 item 2). The host is now scoped to the
///   writable `importResult` publisher and the dependencies the scanner + reconcile
///   need.
///
/// `importResult` stays on `ExportManager` as a `@Published var` so its writability
/// contract is preserved; the coordinator updates it via `Host.setImportResult(_:)`.
@MainActor
final class ImportCoordinator: ObservableObject {

  // MARK: - Host

  /// Hooks back to ExportManager for state the coordinator does not own: the writable
  /// `importResult` mirror and the destination/store dependencies required by
  /// scanner + reconcile. The Phase-0 cancellation seam is no longer on this
  /// protocol — the coordinator reaches it through its injected
  /// `ExportQueueCoordinator` reference.
  @MainActor
  protocol Host: AnyObject {
    /// Writes the import report back to ExportManager so `manager.importResult`
    /// readers and the @Published mirror see the new value. Kept as a Host method
    /// (not a coordinator-owned @Published) because `manager.importResult` is a
    /// writable `@Published var` callers occasionally reset directly.
    func setImportResult(_ result: ImportReport?)

    var exportDestination: any ExportDestination { get }
    var photoLibraryService: any PhotoLibraryService { get }
    var exportRecordStore: ExportRecordStore { get }
    var collectionExportRecordStore: CollectionExportRecordStore { get }

    /// Returns true if there is any active export work that should block an import
    /// from starting. ExportManager's existing `hasActiveExportWork` already covers
    /// the full set (run loop, enqueueing-all bulk-album task, pending jobs).
    var hasActiveExportWork: Bool { get }
  }

  // MARK: - Published state

  @Published private(set) var isImporting: Bool = false
  @Published private(set) var importStage: BackupScanner.ImportStage?

  /// Handle to the in-flight import Task. Same-module readers (the test target via
  /// `@testable import`) can `await importTask?.value` for deterministic completion.
  private(set) var importTask: Task<Void, Never>?

  // MARK: - Dependencies

  private let logger = Logger(
    subsystem: "com.valtteriluoma.photo-export", category: "ImportCoordinator")
  private weak var host: Host?
  /// Cancellation seam (Phase 0). Held as a weak reference because both the queue
  /// coordinator and this coordinator have the same lifetime owner
  /// (`ExportManager`); a strong reference would create a retain cycle through
  /// `Host`.
  private weak var queueCoordinator: ExportQueueCoordinator?

  init(host: Host, queueCoordinator: ExportQueueCoordinator) {
    self.host = host
    self.queueCoordinator = queueCoordinator
  }

  // MARK: - Public API

  /// Starts the Import Existing Backup flow. Idempotent: re-entry while an import is
  /// already in flight is a no-op. Other guards (no destination, store not ready,
  /// active export work) silently log and return.
  func startImport() {
    guard !isImporting else { return }
    guard let host else { return }
    guard !host.hasActiveExportWork else {
      logger.warning("Cannot import while export is active")
      return
    }
    guard let rootURL = host.exportDestination.selectedFolderURL else {
      logger.warning("Cannot import: no destination selected")
      return
    }
    // Gate the import on a `.ready` timeline store. Otherwise the scanner would happily
    // run, the bulkImportRecords call would silently drop every record (its `.ready`
    // guard short-circuits on `.unconfigured`/`.failed`), and the user would see a
    // success report with the matched counts despite nothing being persisted. This is
    // the same hazard `canExportTimeline` guards on the export-start side.
    guard host.exportRecordStore.state == .ready else {
      logger.error(
        "Cannot import: timeline record store state=\(String(describing: host.exportRecordStore.state), privacy: .public) (need .ready)"
      )
      return
    }

    isImporting = true
    importStage = .scanningBackupFolder
    host.setImportResult(nil)

    let importGen = queueCoordinator?.generation ?? 0

    importTask = Task { [weak self, weak host] in
      guard let self, let host else { return }

      do {
        guard let scopedURL = host.exportDestination.beginScopedAccess() else {
          self.logger.error("Failed to acquire security-scoped access for import")
          self.isImporting = false
          self.importStage = nil
          return
        }
        defer { host.exportDestination.endScopedAccess(for: scopedURL) }

        // Probe the root before any destructive step. `BackupScanner.scanBackupFolder`
        // swallows root-enumeration failure as `[]`, which would make a transiently
        // unreadable drive look identical to "the user deleted everything." Reconcile
        // would then prune every record. Catch that case here and bail without touching
        // the stores.
        do {
          _ = try FileManager.default.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        } catch {
          self.logger.error(
            "Import root unreachable: \(error.localizedDescription, privacy: .public)")
          self.isImporting = false
          self.importStage = nil
          return
        }

        self.importStage = .scanningBackupFolder
        try Task.checkCancellation()
        let scannedFiles = await Task.detached {
          BackupScanner.scanBackupFolder(at: rootURL)
        }.value

        try Task.checkCancellation()
        guard self.queueCoordinator?.isCurrent(importGen) == true else {
          self.isImporting = false
          self.importStage = nil
          return
        }

        // No early return on `scannedFiles.isEmpty` — an empty destination still needs
        // reconcile so existing records get pruned to match disk truth. The bulk-import
        // call below is a no-op for an empty matched list.

        self.importStage = .readingPhotosLibrary
        let matchResult = try await BackupScanner.matchFiles(
          scannedFiles,
          photoLibraryService: host.photoLibraryService
        ) { [weak self] stage in
          self?.importStage = stage
        }

        try Task.checkCancellation()
        guard self.queueCoordinator?.isCurrent(importGen) == true else {
          self.isImporting = false
          self.importStage = nil
          return
        }

        self.importStage = .rebuildingLocalState

        let now = Date()
        var records: [ExportRecord] = []
        records.reserveCapacity(matchResult.matched.count)

        for matched in matchResult.matched {
          let descriptor = matched.asset
          let file = matched.file
          let year: Int
          let month: Int
          if let creationDate = descriptor.creationDate {
            let calendar = Calendar.current
            year = calendar.component(.year, from: creationDate)
            month = calendar.component(.month, from: creationDate)
          } else {
            year = file.year
            month = file.month
          }
          let relPath = "\(year)/" + String(format: "%02d", month) + "/"

          let record = ExportRecord(
            id: descriptor.id,
            year: year,
            month: month,
            relPath: relPath,
            variants: [
              matched.variant: ExportVariantRecord(
                filename: file.filename,
                status: .done,
                exportDate: now,
                lastError: nil
              )
            ]
          )
          records.append(record)
        }

        host.exportRecordStore.bulkImportRecords(records)

        guard self.queueCoordinator?.isCurrent(importGen) == true else {
          self.isImporting = false
          self.importStage = nil
          return
        }

        // Reconcile both stores after bulkImport so the final state reflects disk
        // truth at the latest possible moment. Closes the TOCTOU window where a file
        // present at scan time gets deleted before bulkImport applies it.
        self.importStage = .reconcilingDiskState
        try Task.checkCancellation()
        let timelineSummary = await host.exportRecordStore.reconcileAgainstFilesystem(
          at: rootURL)
        try Task.checkCancellation()
        guard self.queueCoordinator?.isCurrent(importGen) == true else {
          self.isImporting = false
          self.importStage = nil
          return
        }
        let collectionSummary = await host.collectionExportRecordStore
          .reconcileAgainstFilesystem(at: rootURL)
        try Task.checkCancellation()
        guard self.queueCoordinator?.isCurrent(importGen) == true else {
          self.isImporting = false
          self.importStage = nil
          return
        }

        let totalPrunedVariants =
          timelineSummary.prunedVariants + collectionSummary.prunedVariants
        let totalPrunedRecords =
          timelineSummary.prunedRecords + collectionSummary.prunedRecords

        host.setImportResult(
          ImportReport(
            matchedCount: matchResult.matched.count,
            ambiguousCount: matchResult.ambiguous.count,
            unmatchedCount: matchResult.unmatched.count,
            totalScanned: scannedFiles.count,
            prunedVariants: totalPrunedVariants,
            prunedRecords: totalPrunedRecords
          ))

        self.importStage = .done
        self.isImporting = false

        self.logger.info(
          "Import complete: \(matchResult.matched.count) matched, \(matchResult.ambiguous.count) ambiguous, \(matchResult.unmatched.count) unmatched out of \(scannedFiles.count) scanned; pruned \(totalPrunedVariants) variants and \(totalPrunedRecords) records"
        )
      } catch is CancellationError {
        self.logger.info("Import task cancelled")
        self.isImporting = false
        self.importStage = nil
      } catch {
        self.logger.error(
          "Import failed: \(error.localizedDescription, privacy: .public)")
        self.isImporting = false
        self.importStage = nil
      }
    }
  }

  /// Cancels an in-progress import. Bumps the queue coordinator's generation so any
  /// late-completing import work gates out via `isCurrent` checks.
  func cancelImport() {
    guard isImporting else { return }
    importTask?.cancel()
    importTask = nil
    queueCoordinator?.bumpGeneration()
    isImporting = false
    importStage = nil
    host?.setImportResult(nil)
    logger.info("Import cancelled")
  }
}
