#if DEBUG
  import Foundation

  extension ExportManager {
    var controlExportIdle: Bool { !hasActiveExportWork && activeRunContext == nil }
  }

  /// Redacted snapshot of core-owned state. The mailbox adds only run and sequencing metadata.
  @MainActor
  enum ControlState {
    static func project(_ core: AppCore, fixture: ControlFixture) -> [String: Any] {
      let destination = core.exportDestinationManager
      let manager = core.exportManager
      let timeline = core.exportRecordStore
      let collections = core.collectionExportRecordStore
      let autoSync = core.autoSyncManager
      let exportIdle = manager.controlExportIdle
      let isImporting = manager.isImporting
      let timelineFlushing = timeline.controlIsFlushing
      let collectionsFlushing = collections.controlIsFlushing
      let autoSyncState = autoSync.state
      return [
        "destination": [
          "status": String(describing: destination.status),
          "available": destination.isAvailable,
          "hasIdentity": destination.identity.stableId != nil,
          "folder": destination.selectedFolderURL.flatMap {
            fixture.permitsDestination($0) ? "Destination" : nil
          } as Any? ?? NSNull(),
        ],
        "export": [
          "running": !exportIdle,
          "paused": manager.isPaused,
          "queueCount": manager.queueCount,
          "runSource": (manager.activeRunContext?.source.rawValue ?? (exportIdle ? nil : "manual"))
            as Any? ?? NSNull(),
          "enqueued": manager.totalJobsEnqueued,
          "completed": manager.totalJobsCompleted,
        ],
        "import": [
          "running": isImporting,
          "stage": importStage(manager.importStage),
          "result": manager.importResult.map(importCounts) as Any? ?? NSNull(),
          "previousBackupMissing": manager.previousBackupMissing,
        ],
        "autoSync": [
          "enabled": autoSync.isEnabled,
          "state": autoSyncPhase(autoSyncState),
          "waitingReason": waitingReason(autoSyncState) as Any? ?? NSNull(),
        ],
        "records": [
          "timeline": String(describing: timeline.state),
          "collections": String(describing: collections.state),
          "exportedByMonth": exportedByMonth(core),
        ],
        "prompts": [
          "migrationConflict": core.lifecycleCoordinator.migrationConflict != nil,
          "destinationSafetyConfirmation": core.destinationSafetyMonitor.needsSafetyConfirmation,
          "previousBackupMissing": manager.previousBackupMissing,
          "supersedeAutoSync": manager.manualExportShouldConfirmSupersede,
          "timelineHistoryRecovery": timeline.state.needsRecovery,
          "collectionHistoryRecovery": collections.state.needsRecovery,
        ],
        "idle": exportIdle && !isImporting && !timelineFlushing && !collectionsFlushing
          && timeline.state.isSettled && collections.state.isSettled
          && autoSyncPhase(autoSyncState) != "running",
      ]
    }

    private static func exportedByMonth(_ core: AppCore) -> [String: Int] {
      guard
        let library = core.composition.photoLibraryServiceOverride as? FixturePhotoLibraryService
      else { return [:] }
      let store = core.exportRecordStore
      let manager = core.exportManager
      return Dictionary(
        uniqueKeysWithValues: library.timelineMonths.map { key in
          let summary = store.monthSummary(
            assets: library.timelineAssets(in: key), selection: manager.versionSelection,
            livePhotosPaired: manager.livePhotosPairedExport)
          return (String(format: "%04d-%02d", key.year, key.month), summary.exportedCount)
        })
    }

    private static func importStage(_ stage: BackupScanner.ImportStage?) -> Any {
      switch stage {
      case nil: NSNull()
      case .scanningBackupFolder: "scanningBackupFolder"
      case .readingPhotosLibrary: "readingPhotosLibrary"
      case .matchingAssets: "matchingAssets"
      case .rebuildingLocalState: "rebuildingLocalState"
      case .reconcilingDiskState: "reconcilingDiskState"
      case .done: "done"
      }
    }

    private static func importCounts(_ report: ImportReport) -> [String: Int] {
      [
        "matched": report.matchedCount, "ambiguous": report.ambiguousCount,
        "unmatched": report.unmatchedCount, "scanned": report.totalScanned,
        "prunedVariants": report.prunedVariants, "prunedRecords": report.prunedRecords,
        "collectionScanned": report.collectionFilesScanned,
        "collectionMatched": report.collectionMatchedCount,
      ]
    }

    private static func autoSyncPhase(_ state: AutoSyncState) -> String {
      switch state {
      case .disabled: "disabled"
      case .waiting: "waiting"
      case .idle: "idle"
      case .scheduled: "scheduled"
      case .blocked: "blocked"
      case .running: "running"
      }
    }

    private static func waitingReason(_ state: AutoSyncState) -> String? {
      switch state {
      case .waiting(let reason), .blocked(let reason): reason.rawValue
      default: nil
      }
    }
  }
#endif
