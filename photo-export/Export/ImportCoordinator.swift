import Combine
import Foundation
import OSLog

/// Owns the Import Existing Backup flow: scanner invocation, library matching, bulk
/// record insertion, both-store reconciliation, and the per-stage progress publishing.
///
/// Per `docs/project/archive/software-architecture-improvement-plan.md` Phase 5, this
/// extraction:
/// - Moves the ~190-line `startImport` body (and `cancelImport`) out of `ExportManager`.
/// - Owns the published mirrors `isImporting`, `importStage` + `importError` directly; ExportManager
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
  @Published private(set) var importError: String?

  /// Handle to the in-flight import Task. Same-module readers (the test target via
  /// `@testable import`) can `await importTask?.value` for deterministic completion.
  private(set) var importTask: Task<Void, Never>?
  // UI ownership is separate from queue validity: destination teardown can
  // invalidate generation without cancelling this Task or starting a replacement.
  private var activeImportID: UUID?

  private func isCurrentImport(_ id: UUID, generation: Int) -> Bool {
    activeImportID == id && queueCoordinator?.isCurrent(generation) == true && !Task.isCancelled
  }

  private func finishOwnedImport(
    _ id: UUID, error: String? = nil, stage: BackupScanner.ImportStage? = nil
  ) {
    guard activeImportID == id else { return }
    flushRecordNotifications()
    guard activeImportID == id else { return }
    activeImportID = nil
    importError = error
    importStage = stage
    // Publish activity last; synchronous subscribers may start replacement work.
    isImporting = false
  }

  private func flushRecordNotifications() {
    host?.exportRecordStore.flushPendingNotifications()
    host?.collectionExportRecordStore.flushPendingNotifications()
  }

  // MARK: - Dependencies

  private let logger = Logger(
    subsystem: "com.valtteriluoma.photo-export", category: "ImportCoordinator")
  private weak var host: Host?
  /// Cancellation seam (Phase 0). Held as a weak reference because both the queue
  /// coordinator and this coordinator have the same lifetime owner
  /// (`ExportManager`); a strong reference would create a retain cycle through
  /// `Host`.
  private weak var queueCoordinator: ExportQueueCoordinator?

  private let backupDirectoryReader: any BackupDirectoryReading

  init(
    host: Host, queueCoordinator: ExportQueueCoordinator,
    backupDirectoryReader: any BackupDirectoryReading = ProductionBackupDirectoryReader()
  ) {
    self.host = host
    self.backupDirectoryReader = backupDirectoryReader
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

    let importGen = queueCoordinator?.generation ?? 0
    let operationID = UUID()
    activeImportID = operationID
    importError = nil
    host.setImportResult(nil)
    importStage = .scanningBackupFolder
    isImporting = true

    importTask = Task { [weak self, weak host] in
      guard let self, let host else { return }
      // A generation-only interruption still settles its own UI, including
      // invalidation before Task entry. A replacement UUID remains untouched.
      defer { self.finishOwnedImport(operationID) }
      guard self.isCurrentImport(operationID, generation: importGen) else { return }

      do {
        guard let scopedURL = host.exportDestination.beginScopedAccess() else {
          self.logger.error("Failed to acquire security-scoped access for import")
          self.finishOwnedImport(operationID, error: "Could not access the export folder.")
          return
        }
        defer { host.exportDestination.endScopedAccess(for: scopedURL) }

        // The throwing scanner verifies recognized directories before any import or pruning.
        self.importStage = .scanningBackupFolder
        try Task.checkCancellation()
        let reader = self.backupDirectoryReader
        let scannedFiles = try await Task.detached {
          try BackupScanner.scanBackupFolder(at: rootURL, directoryReader: reader)
        }.value

        try Task.checkCancellation()
        guard self.isCurrentImport(operationID, generation: importGen) else { return }

        // No early return on `scannedFiles.isEmpty` — an empty destination still needs
        // reconcile so existing records get pruned to match disk truth. The bulk-import
        // call below is a no-op for an empty matched list.

        self.importStage = .readingPhotosLibrary
        let matchResult = try await BackupScanner.matchFiles(
          scannedFiles,
          photoLibraryService: host.photoLibraryService
        ) { [weak self] stage in
          guard let self, self.isCurrentImport(operationID, generation: importGen) else { return }
          self.importStage = stage
        }

        try Task.checkCancellation()
        guard self.isCurrentImport(operationID, generation: importGen) else { return }

        self.importStage = .rebuildingLocalState

        let now = Date()
        var records: [ExportRecord] = []
        records.reserveCapacity(matchResult.matched.count)

        for matched in matchResult.matched {
          let descriptor = matched.asset
          let file = matched.file
          // Matching includes adjacent months for timezone/date drift. The file's
          // scanned folder remains the source of truth for its physical location.
          let year = file.year
          let month = file.month
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
                lastError: nil,
                // Issue #38: preserve the on-disk location captured by the scanner so
                // reuse-source and reconcile can find the file. `nil` for the bare
                // month folder; `"videos"` for files discovered under
                // `YYYY/MM/videos/`. Without this, importing a backup written under
                // the subfolder layout would silently mis-locate every video.
                subfolder: file.subfolder
              )
            ]
          )
          records.append(record)
        }

        host.exportRecordStore.bulkImportRecords(records)

        guard self.isCurrentImport(operationID, generation: importGen) else { return }

        // Reconcile both stores after bulkImport so the final state reflects disk
        // truth at the latest possible moment. Closes the TOCTOU window where a file
        // present at scan time gets deleted before bulkImport applies it.
        self.importStage = .reconcilingDiskState
        try Task.checkCancellation()
        let timelineSummary = try await host.exportRecordStore.reconcileAgainstFilesystem(
          at: rootURL,
          isCurrent: { [weak self] in self?.queueCoordinator?.isCurrent(importGen) == true })
        try Task.checkCancellation()
        guard self.isCurrentImport(operationID, generation: importGen) else { return }
        let reconciledCollections = host.collectionExportRecordStore.state == .ready
        let collectionSummary = try await host.collectionExportRecordStore
          .reconcileAgainstFilesystem(
            at: rootURL,
            isCurrent: { [weak self] in self?.queueCoordinator?.isCurrent(importGen) == true })
        try Task.checkCancellation()
        guard self.isCurrentImport(operationID, generation: importGen) else { return }

        try await host.exportRecordStore.flush()
        guard self.isCurrentImport(operationID, generation: importGen) else { return }
        if reconciledCollections {
          try await host.collectionExportRecordStore.flush()
          guard self.isCurrentImport(operationID, generation: importGen) else { return }
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

        self.finishOwnedImport(operationID, stage: .done)

        self.logger.info(
          "Import complete: \(matchResult.matched.count) matched, \(matchResult.ambiguous.count) ambiguous, \(matchResult.unmatched.count) unmatched out of \(scannedFiles.count) scanned; pruned \(totalPrunedVariants) variants and \(totalPrunedRecords) records"
        )
      } catch is CancellationError {
        guard self.isCurrentImport(operationID, generation: importGen) else { return }
        self.logger.info("Import task cancelled")
        self.finishOwnedImport(operationID)
      } catch {
        guard self.isCurrentImport(operationID, generation: importGen) else { return }
        self.logger.error(
          "Import failed: \(error.localizedDescription, privacy: .public)")
        self.finishOwnedImport(operationID, error: "Import failed: \(error.localizedDescription)")
      }
    }
  }

  /// Cancels an in-progress import. Bumps the queue coordinator's generation so any
  /// late-completing import work gates out via `isCurrent` checks.
  func cancelImport() {
    guard isImporting else { return }
    activeImportID = nil
    importTask?.cancel()
    importTask = nil
    queueCoordinator?.bumpGeneration()
    host?.setImportResult(nil)
    importError = nil
    importStage = nil
    flushRecordNotifications()
    // A synchronous notification subscriber may cancel and start another import.
    guard activeImportID == nil else { return }
    isImporting = false
    logger.info("Import cancelled")
  }
}
