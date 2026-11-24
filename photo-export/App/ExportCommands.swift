/// Dispatches a manual export or asks its caller to obtain consent to supersede Auto Export.
@MainActor
enum ExportCommands {
  @discardableResult
  static func startManual(
    _ manager: ExportManager, confirm: Bool = false, perform: () -> Void
  ) -> Bool {
    if confirm {
      manager.supersedeForManualRun()
    } else if manager.manualExportShouldConfirmSupersede {
      return false
    }
    perform()
    return true
  }

  static func cancel(_ manager: ExportManager, autoSync: AutoSyncManager) {
    autoSync.setEnabled(false)
    manager.cancelAndClear()
  }
}
