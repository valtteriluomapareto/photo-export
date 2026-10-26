import Combine
import Foundation
import OSLog

/// Owns Import Existing Backup: timeline and collection scanning, library matching,
/// record insertion, reconciliation, and stage progress.
///
/// Synchronous sinks mirror `isImporting`, `importStage`, and `importError` onto
/// `ExportManager` so AutoSync and views keep a consistent observation surface.
/// Cancellation uses the injected `ExportQueueCoordinator` directly. The narrow Host
/// provides store/destination dependencies and writes `importResult`, whose manager
/// property remains writable by callers.
/// See docs/reference/architecture-conventions.md#import-outcome-ownership.
@MainActor
final class ImportCoordinator: ObservableObject {

  // MARK: - Host

  /// Hooks back to ExportManager for state the coordinator does not own: the writable
  /// `importResult` mirror and the destination/store dependencies required by
  /// scanner + reconcile. Cancellation is separate from this protocol;
  /// the coordinator reaches it through its injected
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

  private let logger = Logger.app(.importCoordinator)
  private weak var host: Host?
  /// Cancellation seam. A weak reference keeps collaborator lifetimes bounded by
  /// their shared owner, `ExportManager`.
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
  /// active export work) log and return the reason. While either history is still loading,
  /// the import starts at once, holding exports, and waits for it; if the timeline history
  /// then isn't ready, the import ends without running and says why, through the same outcome
  /// as other failures.
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
    } else if host.exportRecordStore.state.isSettled, !isTimelineHistoryReady(host) {
      // A history that is still loading is waited for below; any other state refuses now.
      refusal = .historyNotReady
    } else {
      refusal = nil
    }
    if let refusal {
      if requiringPreviousBackup {
        previousBackupMissing = false
        importStage = nil
        host.setImportResult(nil)
        importError = Self.previousBackupCheckMessage(for: refusal)
      }
      return refusal
    }
    guard let rootURL = host.exportDestination.selectedFolderURL else { return .noDestination }
    // A destination change while the import waits for the history abandons it.
    let timelineDestination = host.exportRecordStore.destinationId
    let collectionDestination = host.collectionExportRecordStore.destinationId

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

      // Right after a destination change its history is still loading. The import holds
      // exports while it waits, then checks it still owns the same destination.
      await host.exportRecordStore.waitUntilSettled()
      await host.collectionExportRecordStore.waitUntilSettled()
      guard self.isCurrentImport(operationID, generation: importGen) else { return }
      guard host.exportRecordStore.destinationId == timelineDestination,
        host.collectionExportRecordStore.destinationId == collectionDestination
      else {
        self.logger.info("Import abandoned: the destination changed while its history loaded")
        return
      }
      guard self.isTimelineHistoryReady(host) else {
        self.finishOwnedImport(
          operationID,
          error: requiringPreviousBackup
            ? Self.previousBackupCheckMessage(for: .historyNotReady)
            : Self.historyUnavailableMessage)
        return
      }

      do {
        guard let scopedURL = host.exportDestination.beginScopedAccess() else {
          self.logger.error("Failed to acquire security-scoped access for import")
          self.finishOwnedImport(operationID, error: "Could not access the export folder.")
          return
        }
        defer { host.exportDestination.endScopedAccess(for: scopedURL) }

        if requiringPreviousBackup {
          let isCurrent: @MainActor @Sendable () -> Bool = { [weak self] in
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
        let progress: @MainActor @Sendable (BackupScanner.ImportStage) -> Void = {
          [weak self] stage in
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
            let tree = try await host.photoLibraryService.loadCollectionTree()
            try Task.checkCancellation()
            guard self.isCurrentImport(operationID, generation: importGen) else { return }
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
                // Preserve the on-disk location captured by the scanner so
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

        // Recheck both histories before each bounded, synchronous pair of writes.
        guard self.isCurrentImport(operationID, generation: importGen) else { return }
        guard host.exportRecordStore.state == .ready else { throw RecordPersistenceUnavailable() }
        let collectionsReady = collectionStore.state == .ready
        if !collectionsReady && !collectionBatches.isEmpty { collectionsSkipped = true }
        let boundedCollections = collectionBatches.flatMap { batch in
          let assets = Array(batch.records)
          return stride(from: 0, to: assets.count, by: 64).map { offset in
            CollectionExportRecordStore.ImportBatch(
              placement: batch.placement,
              records: Dictionary(
                uniqueKeysWithValues: assets[offset..<min(offset + 64, assets.count)].map {
                  ($0.key, $0.value)
                }))
          }
        }
        let turns = max((records.count + 63) / 64, boundedCollections.count)
        for turn in 0..<turns {
          try await RecordStoreRouter.withImportMutationAdmission(
            timeline: host.exportRecordStore, collections: collectionsReady ? collectionStore : nil
          ) {
            guard self.isCurrentImport(operationID, generation: importGen),
              host.exportRecordStore.destinationId == timelineDestination,
              collectionStore.destinationId == collectionDestination
            else { throw CancellationError() }
            let offset = min(turn * 64, records.count)
            host.exportRecordStore.bulkImportRecords(
              Array(records[offset..<min(offset + 64, records.count)]))
            if collectionsReady, turn < boundedCollections.count {
              collectionStore.bulkImportRecords([boundedCollections[turn]])
            }
          }
          await Task.yield()
        }

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

        host.exportRecordStore.requestHistoryCheckpoint()
        host.collectionExportRecordStore.requestHistoryCheckpoint()
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

  /// Imports need a `.ready` timeline store. Otherwise the scanner would happily run, the
  /// bulkImportRecords call would silently drop every record (its `.ready` guard
  /// short-circuits on `.unconfigured`/`.failed`), and the user would see a success report with
  /// the matched counts despite nothing being persisted. This is the same hazard
  /// `canExportTimeline` guards on the export-start side.
  private func isTimelineHistoryReady(_ host: Host) -> Bool {
    let state = host.exportRecordStore.state
    guard state == .ready else {
      logger.error(
        "Cannot import: timeline record store state=\(String(describing: state), privacy: .public) (need .ready)"
      )
      return false
    }
    return true
  }

  /// Why an import that waited for the history ended without running, when the history it
  /// loaded isn't ready.
  static let historyUnavailableMessage =
    "Export history isn\u{2019}t available. Resolve the export history alert, then import again."

  /// What a "Same Folder" check that could not run tells the user.
  private static func previousBackupCheckMessage(for refusal: StartRefusal) -> String {
    refusal == .exportActive
      ? "Photo Export couldn\u{2019}t check this folder against your export history while an export is running. Your export history was kept. Choose File \u{2192} Import Existing Backup\u{2026} when the export finishes."
      : "Photo Export couldn\u{2019}t check this folder against your export history. Your export history was kept."
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
