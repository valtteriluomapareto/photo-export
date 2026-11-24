#if DEBUG
  import Foundation

  @MainActor
  struct ControlActions {
    let core: AppCore

    func perform(_ action: ControlAction) -> ControlOutcome {
      let manager = core.exportManager
      switch action {
      case .export(let selection, let confirm):
        return export(selection, confirm: confirm)
      case .pause:
        guard manager.canTogglePause, !manager.isPaused else { return .noop }
        manager.pause()
      case .resume:
        guard manager.isPaused else { return .noop }
        manager.resume()
      case .cancel:
        guard !manager.controlExportIdle else { return .noop }
        ExportCommands.cancel(manager, autoSync: core.autoSyncManager)
      case .startImport:
        guard core.exportDestinationManager.canImportNow, manager.controlExportIdle
        else { return .refused(.unavailable) }
        manager.startImport()
        guard manager.isImporting else { return .refused(.unavailable) }
      case .cancelImport:
        guard manager.isImporting else { return .noop }
        manager.cancelImport()
      case .setAutoSync(let enabled):
        guard core.autoSyncManager.isEnabled != enabled else { return .noop }
        core.autoSyncManager.setEnabled(enabled)
      case .advanceClock(let seconds):
        guard let clock = core.composition.clock as? FixtureClock else {
          return .refused(.unavailable)
        }
        clock.advance(by: TimeInterval(seconds))
      }
      return .accepted
    }

    private func export(_ selection: LibrarySelection, confirm: Bool) -> ControlOutcome {
      let manager = core.exportManager
      let destination = core.exportDestinationManager
      let history =
        selection.isTimeline
        ? core.exportRecordStore.state : core.collectionExportRecordStore.state
      let availability = ManualExportAvailability(
        destinationCanExport: destination.canExportNow, history: history)
      guard availability.canStart, !manager.isImporting, !manager.previousBackupMissing,
        manager.controlExportIdle || manager.isPaused || manager.manualExportShouldConfirmSupersede
      else { return .refused(.unavailable) }
      if case .album(let id) = selection {
        let fixture = core.composition.photoLibraryServiceOverride as? FixturePhotoLibraryService
        guard fixture?.containsAlbum(id) == true
        else { return .refused(.unknownSelection) }
      }
      let accepted = ExportCommands.startManual(
        manager, confirm: confirm && manager.manualExportShouldConfirmSupersede
      ) {
        manager.startExport(selection: selection)
      }
      return accepted ? .accepted : .refused(.needsConfirmation)
    }
  }
#endif
