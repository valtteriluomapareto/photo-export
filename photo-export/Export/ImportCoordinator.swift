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
    // Symmetric gate on the collection store (issue #106). A `.failed` collection
    // store means we cannot persist any collection-side records this session;
    // refusing the whole import is more honest than completing with "0 album
    // exports recognized" — the user has no signal that something album-shaped
    // was lost otherwise. `.unconfigured` is not reachable through the normal
    // flow (destination select configures both stores together) but the strict
    // `== .ready` check guards a future code path that might invoke import from
    // another surface.
    guard host.collectionExportRecordStore.state == .ready else {
      logger.error(
        "Cannot import: collection record store state=\(String(describing: host.collectionExportRecordStore.state), privacy: .public) (need .ready)"
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
        let scanned = await Task.detached {
          (
            timeline: BackupScanner.scanBackupFolder(at: rootURL),
            collections: BackupCollectionScanner.scanCollections(at: rootURL)
          )
        }.value
        let scannedFiles = scanned.timeline
        let collectionGroups = scanned.collections

        try Task.checkCancellation()
        guard self.queueCoordinator?.isCurrent(importGen) == true else {
          self.isImporting = false
          self.importStage = nil
          return
        }

        // No early return on `scannedFiles.isEmpty` — an empty destination still needs
        // reconcile so existing records get pruned to match disk truth. The bulk-import
        // calls below are no-ops for an empty matched list.

        // Resolve every collection scan group to a placement via the matcher.
        // Orphan groups contribute their files to the import-report's `unmatched`
        // bucket; existing/fresh placements feed the per-placement matcher.
        // Issue #106 — pre-built before the match pass so the timeline + collection
        // counters can share a single user-visible "Matching assets…" stage
        // (HIG: progressive disclosure).
        let photoCollections = (try? host.photoLibraryService.fetchCollectionTree()) ?? []
        let existingPlacements = Array(host.collectionExportRecordStore.placements.values)
        let placementMatcher = BackupCollectionPlacementMatcher()
        var collectionResolutions: [BackupScanner.CollectionPlacementResolution] = []
        var orphanFiles: [BackupScanner.ScannedFile] = []
        var orphanFolderCount = 0
        for group in collectionGroups {
          let outcome = placementMatcher.match(
            group: group,
            photoCollections: photoCollections,
            existingPlacements: existingPlacements)
          switch outcome {
          case .existing(let placement), .fresh(let placement):
            collectionResolutions.append(
              BackupScanner.CollectionPlacementResolution(
                placement: placement, files: group.files))
          case .orphan(let reason):
            self.logger.info(
              "Skipping orphan collection folder at \(group.folderURL.path, privacy: .public): \(String(describing: reason), privacy: .public)"
            )
            orphanFiles.append(contentsOf: group.files)
            orphanFolderCount += 1
          }
        }

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

        // Collection-side match pass. Reuses `matchSingleFile` unchanged; the
        // candidate-asset set is scoped per placement instead of per year-month.
        // Progress is reported through the same `.matchingAssets` stage so the
        // UI shows a single combined counter across both passes.
        let collectionMatchResult = try await BackupScanner.matchCollectionFiles(
          collectionResolutions,
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

        // Collection-side bulk-import. Placements first (orphan-record guard inside
        // the store requires placement before record); then entries. The store's
        // `accept(_:)` gate refuses any `.timeline` placement that snuck through.
        // Issue #106.
        var collectionEntries: [CollectionExportRecordStore.BulkImportEntry] = []
        collectionEntries.reserveCapacity(collectionMatchResult.matched.count)
        for matched in collectionMatchResult.matched {
          collectionEntries.append(
            CollectionExportRecordStore.BulkImportEntry(
              placement: matched.placement,
              assetId: matched.asset.id,
              variant: matched.variant,
              filename: matched.file.filename,
              exportedAt: now,
              // Issue #38: preserve on-disk location for reuse-source and reconcile.
              subfolder: matched.file.subfolder))
        }
        // Existing placements re-upserted alongside new ones — the merge is idempotent
        // in the store and keeps the orphan-record guard happy if a placement's
        // metadata was somehow dropped between launches.
        let placementsToBulkImport: [ExportPlacement] = {
          var seen = Set<String>()
          var result: [ExportPlacement] = []
          for resolution in collectionResolutions
          where seen.insert(resolution.placement.id).inserted {
            result.append(resolution.placement)
          }
          return result
        }()
        host.collectionExportRecordStore.bulkImportRecords(
          placements: placementsToBulkImport, entries: collectionEntries)

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

        let totalCollectionFiles = collectionGroups.reduce(0) { $0 + $1.files.count }
        let totalScanned = scannedFiles.count + totalCollectionFiles
        let totalMatched =
          matchResult.matched.count + collectionMatchResult.matched.count
        let totalAmbiguous =
          matchResult.ambiguous.count + collectionMatchResult.ambiguous.count
        // Orphan-folder files count as `unmatched` in the report so the user sees
        // them in the existing "No matching asset found" row. The
        // `orphanCollectionFolders` field on the report drives the italic
        // disclosure underneath. Issue #106 / HIG: be honest about errors.
        let totalUnmatched =
          matchResult.unmatched.count + collectionMatchResult.unmatched.count
          + orphanFiles.count

        host.setImportResult(
          ImportReport(
            matchedCount: totalMatched,
            ambiguousCount: totalAmbiguous,
            unmatchedCount: totalUnmatched,
            totalScanned: totalScanned,
            prunedVariants: totalPrunedVariants,
            prunedRecords: totalPrunedRecords,
            collectionMatchedCount: collectionMatchResult.matched.count,
            orphanCollectionFolders: orphanFolderCount
          ))

        self.importStage = .done
        self.isImporting = false

        self.logger.info(
          "Import complete: \(totalMatched) matched (timeline=\(matchResult.matched.count), collection=\(collectionMatchResult.matched.count)), \(totalAmbiguous) ambiguous, \(totalUnmatched) unmatched (orphan-folder=\(orphanFiles.count)) out of \(totalScanned) scanned; pruned \(totalPrunedVariants) variants and \(totalPrunedRecords) records"
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
