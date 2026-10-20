import Combine
import Foundation
import OSLog

/// Owns the Import Existing Backup flow: scanner invocation (the timeline's `YYYY/MM` folders
/// and the album, shared-album and Favorites folders under `Collections/`), library matching,
/// bulk record insertion into both stores, both-store reconciliation, and the per-stage
/// progress publishing.
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
  /// Set when an import that required the previous backup found none of the export history's
  /// files in the folder. Nothing was imported or pruned, and exports wait until the user picks
  /// another folder or starts a new history (`clearPreviousBackupMissing()`).
  @Published private(set) var previousBackupMissing: Bool = false

  /// Why `startImport` didn't start.
  enum StartRefusal: Equatable {
    case alreadyImporting, exportActive, noDestination, historyNotReady
  }

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
  /// active export work) log and return the reason.
  ///
  /// `requiringPreviousBackup` is for a folder the user said is their previous backup: when the
  /// history has completed files and none of them are in the folder, nothing is imported or
  /// pruned and `previousBackupMissing` is set. A refusal also sets `importError`, so the user
  /// learns why the check didn't run.
  @discardableResult
  func startImport(requiringPreviousBackup: Bool = false) -> StartRefusal? {
    guard !isImporting else { return .alreadyImporting }
    guard let host else { return .noDestination }
    let refusal: StartRefusal?
    if host.hasActiveExportWork {
      logger.warning("Cannot import while export is active")
      refusal = .exportActive
    } else if host.exportDestination.selectedFolderURL == nil {
      logger.warning("Cannot import: no destination selected")
      refusal = .noDestination
    } else if host.exportRecordStore.state != .ready {
      // Gate the import on a `.ready` timeline store. Otherwise the scanner would happily
      // run, the bulkImportRecords call would silently drop every record (its `.ready`
      // guard short-circuits on `.unconfigured`/`.failed`), and the user would see a
      // success report with the matched counts despite nothing being persisted. This is
      // the same hazard `canExportTimeline` guards on the export-start side.
      logger.error(
        "Cannot import: timeline record store state=\(String(describing: host.exportRecordStore.state), privacy: .public) (need .ready)"
      )
      refusal = .historyNotReady
    } else {
      refusal = nil
    }
    if let refusal {
      if requiringPreviousBackup {
        previousBackupMissing = false
        importStage = nil
        host.setImportResult(nil)
        importError =
          refusal == .exportActive
          ? "Photo Export couldn\u{2019}t check this folder against your export history while an export is running. Your export history was kept. Choose File \u{2192} Import Existing Backup\u{2026} when the export finishes."
          : "Photo Export couldn\u{2019}t check this folder against your export history. Your export history was kept."
      }
      return refusal
    }
    guard let rootURL = host.exportDestination.selectedFolderURL else { return .noDestination }

    let importGen = queueCoordinator?.generation ?? 0
    let operationID = UUID()
    activeImportID = operationID
    importError = nil
    host.setImportResult(nil)
    importStage = .scanningBackupFolder
    isImporting = true
    // After `isImporting`, so exports stay held without a gap when a re-pick checks again.
    previousBackupMissing = false

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

        if requiringPreviousBackup {
          let isCurrent: @MainActor () -> Bool = { [weak self] in
            self?.queueCoordinator?.isCurrent(importGen) == true
          }
          let timelineHas = try await host.exportRecordStore.containsCompletedFile(
            at: rootURL, isCurrent: isCurrent)
          try Task.checkCancellation()
          guard self.isCurrentImport(operationID, generation: importGen) else { return }
          var hasHistory = timelineHas != nil
          var found = timelineHas == true
          if !found {
            let collectionsHave = try await host.collectionExportRecordStore
              .containsCompletedFile(at: rootURL, isCurrent: isCurrent)
            try Task.checkCancellation()
            guard self.isCurrentImport(operationID, generation: importGen) else { return }
            hasHistory = hasHistory || collectionsHave != nil
            found = collectionsHave == true
          }
          if hasHistory, !found {
            self.logger.info(
              "Import skipped: none of the export history's files are in \(rootURL.path, privacy: .public)"
            )
            self.previousBackupMissing = true
            self.finishOwnedImport(operationID)
            return
          }
        }

        // The throwing scanners verify recognized directories before any import or pruning.
        self.importStage = .scanningBackupFolder
        try Task.checkCancellation()
        let reader = self.backupDirectoryReader
        let scan = try await runDetached {
          let timeline = try BackupScanner.scanBackupFolder(at: rootURL, directoryReader: reader)
          let collections = try BackupScanner.scanCollectionsFolder(
            at: rootURL, directoryReader: reader)
          return (timeline: timeline, collections: collections)
        }
        let scannedFiles = scan.timeline

        try Task.checkCancellation()
        guard self.isCurrentImport(operationID, generation: importGen) else { return }

        // No early return on `scannedFiles.isEmpty` — an empty destination still needs
        // reconcile so existing records get pruned to match disk truth. The bulk-import
        // call below is a no-op for an empty matched list.

        self.importStage = .readingPhotosLibrary
        let progress: @MainActor (BackupScanner.ImportStage) -> Void = { [weak self] stage in
          guard let self, self.isCurrentImport(operationID, generation: importGen) else { return }
          self.importStage = stage
        }
        // One fingerprint per asset across the timeline and every album.
        let fingerprints = BackupScanner.FingerprintCache()
        let matchResult = try await BackupScanner.matchFiles(
          scannedFiles, photoLibraryService: host.photoLibraryService,
          fingerprintCache: fingerprints, progress: progress)

        try Task.checkCancellation()
        guard self.isCurrentImport(operationID, generation: importGen) else { return }

        // Album, shared-album and Favorites folders. Albums are matched against the current
        // Photos tree; a tree or album fetch failure fails the import before any change.
        let collectionStore = host.collectionExportRecordStore
        let collectionFilesScanned = scan.collections.directories.reduce(0) {
          $0 + $1.files.count
        }
        var collectionPlan = CollectionBackupPlanner.Plan()
        var collectionsSkipped = false
        if collectionFilesScanned > 0 {
          if collectionStore.state == .ready {
            let tree = try host.photoLibraryService.fetchCollectionTree()
            collectionPlan = try await BackupScanner.matchCollectionFolders(
              scan.collections, collections: tree,
              existingPlacements: Array(collectionStore.placements.values),
              photoLibraryService: host.photoLibraryService, fingerprintCache: fingerprints,
              isCurrent: { [weak self] in
                self?.isCurrentImport(operationID, generation: importGen) == true
              },
              progress: progress)
            try Task.checkCancellation()
            guard self.isCurrentImport(operationID, generation: importGen) else { return }
          } else {
            self.logger.warning(
              "Album history isn't ready (state=\(String(describing: collectionStore.state), privacy: .public)); importing the timeline only"
            )
            collectionsSkipped = true
          }
        }

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
        let collectionBatches = collectionPlan.adoptions.map {
          $0.importBatch(exportedAt: now)
        }

        // Commit both histories in one main-actor turn: nothing can change either store or
        // supersede this import between the checks and the writes.
        guard self.isCurrentImport(operationID, generation: importGen) else { return }
        guard host.exportRecordStore.state == .ready else { throw RecordPersistenceUnavailable() }
        let collectionsReady = collectionStore.state == .ready
        if !collectionsReady && !collectionBatches.isEmpty { collectionsSkipped = true }
        host.exportRecordStore.bulkImportRecords(records)
        if collectionsReady { collectionStore.bulkImportRecords(collectionBatches) }

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

        // Counted after the reconcile, so a file gone since the scan isn't reported as matched.
        let collectionMatchedCount =
          collectionsReady ? collectionStore.recordedVariantCount(of: collectionBatches) : 0
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
            prunedRecords: totalPrunedRecords,
            collectionFilesScanned: collectionFilesScanned,
            collectionMatchedCount: collectionMatchedCount,
            unrecognizedCollectionFolders: collectionsSkipped
              ? [] : collectionPlan.unrecognizedFolders,
            collectionsSkipped: collectionsSkipped
          ))

        self.finishOwnedImport(operationID, stage: .done)

        self.logger.info(
          "Import complete: \(matchResult.matched.count) matched, \(matchResult.ambiguous.count) ambiguous, \(matchResult.unmatched.count) unmatched out of \(scannedFiles.count) scanned; \(collectionMatchedCount) of \(collectionFilesScanned) collection files recorded, \(collectionPlan.unrecognizedFolders.count) unrecognized collection folders\(collectionsSkipped ? " (album history unavailable)" : ""); pruned \(totalPrunedVariants) variants and \(totalPrunedRecords) records"
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
    return nil
  }

  /// Ends the wait after a "previous backup missing" result: the user chose what to do, or the
  /// destination changed.
  func clearPreviousBackupMissing() {
    previousBackupMissing = false
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
    previousBackupMissing = false
    importStage = nil
    flushRecordNotifications()
    // A synchronous notification subscriber may cancel and start another import.
    guard activeImportID == nil else { return }
    isImporting = false
    logger.info("Import cancelled")
  }
}
