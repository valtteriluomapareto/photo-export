import SwiftUI

/// Sheet view that shows import progress and results for "Import Existing Backup…".
struct ImportView: View {
  @Environment(ExportManager.self) private var exportManager
  @Environment(ExportRecordStore.self) private var exportRecordStore
  @Environment(CollectionExportRecordStore.self) private var collectionExportRecordStore
  @EnvironmentObject private var exportDestinationManager: ExportDestinationManager
  @Environment(\.dismiss) private var dismiss

  /// Called for "Choose Another Folder…" after a "previous backup missing" result. The presenter
  /// closes the sheet and opens the folder panel once it has closed.
  var onChooseAnotherFolder: (() -> Void)?

  @State private var newFolderError: String?

  var body: some View {
    VStack(spacing: 20) {
      if exportManager.previousBackupMissing {
        previousBackupMissingView
      } else if let report = exportManager.importResult {
        resultView(report)
      } else if let error = exportManager.importError {
        terminalView(error: error)
      } else if exportManager.isImporting {
        progressView
      } else {
        terminalView(error: nil)
      }
    }
    .padding(24)
    .frame(width: 420)
    // Size to the content's full height so error and recovery text is never cut off. If the
    // height followed truncated text, a fitted sheet or window would shrink a line at a time until
    // AppKit aborts the layout pass.
    .fixedSize(horizontal: false, vertical: true)
    // The user must decide what to do with a folder that isn't their previous backup; exports
    // wait until then.
    .interactiveDismissDisabled(exportManager.previousBackupMissing)
  }

  // MARK: - Progress View

  private var progressView: some View {
    let cancel = {
      exportManager.cancelImport()
      dismiss()
    }
    return VStack(spacing: 16) {
      Image(systemName: "arrow.triangle.2.circlepath")
        .font(.system(size: 36))
        .foregroundColor(.accentColor)

      Text("Importing Existing Backup")
        .font(.headline)

      Text(stageLabel)
        .font(.subheadline)
        .foregroundColor(.secondary)

      ProgressView()
        .progressViewStyle(.linear)
        .frame(maxWidth: 300)

      Button("Cancel", action: cancel)
        .buttonStyle(.bordered)
    }
  }

  private var stageLabel: String {
    switch exportManager.importStage {
    case .scanningBackupFolder: return "Scanning backup folder…"
    case .readingPhotosLibrary: return "Reading Photos library…"
    case .matchingAssets(let matched, let total):
      return "Matching assets… \(matched) found of \(total) files"
    case .rebuildingLocalState: return "Rebuilding local state…"
    case .reconcilingDiskState: return "Pruning records for missing files…"
    case .done: return "Done"
    case .none: return "Preparing…"
    }
  }

  private var timelineExportAvailability: ManualExportAvailability {
    ManualExportAvailability(
      destinationCanExport: exportDestinationManager.canExportNow,
      history: exportRecordStore.state)
  }

  private var canRetryImport: Bool {
    ImportPresentation.canRetry(
      destinationCanImport: exportDestinationManager.canImportNow,
      timeline: exportRecordStore.state, collections: collectionExportRecordStore.state,
      importing: exportManager.isImporting, activeExport: exportManager.hasActiveExportWork)
  }

  private var recoveryGuidance: String {
    if exportRecordStore.state.needsRecovery || collectionExportRecordStore.state.needsRecovery {
      return
        "Close this sheet and resolve the export history alert before retrying. Keep the app open to preserve unsaved progress."
    }
    return
      "Check that your backup drive is connected. Close this sheet to reselect the export folder if access needs renewing, then try again."
  }

  private func terminalView(error: String?) -> some View {
    let retry = {
      guard canRetryImport else { return }
      exportManager.startImport()
    }
    let close = { dismiss() }
    return VStack(spacing: 16) {
      Image(systemName: error == nil ? "info.circle" : "exclamationmark.triangle")
        .font(.system(size: 36))
        .foregroundStyle(error == nil ? Color.secondary : Color.orange)
      Text(error == nil ? "Import Stopped" : "Import Failed")
        .font(.headline)
      Text(error ?? "No import is running.")
        .multilineTextAlignment(.center)
      Text(recoveryGuidance)
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      HStack(spacing: 12) {
        Button("Close", action: close)
          .keyboardShortcut(.cancelAction)
        Button("Retry", action: retry)
          .disabled(!canRetryImport)
      }
      .buttonStyle(.bordered)
    }
  }

  // MARK: - Previous Backup Missing

  /// The user said this is their previous backup folder, but none of the history's files are in
  /// it. The history was kept; offer the two ways forward.
  private var previousBackupMissingView: some View {
    let folderName = exportDestinationManager.selectedFolderURL?.lastPathComponent ?? "this folder"
    let chooseAnother: () -> Void = { onChooseAnotherFolder?() }
    let useAsNew: () -> Void = {
      Task { @MainActor in
        let outcome = await exportDestinationManager.useSelectedFolderAsNewDestination()
        newFolderError = exportManager.continueAfterUsingFolderAsNew(outcome)
        if outcome == .newHistory { dismiss() }
      }
    }
    return VStack(spacing: 16) {
      Image(systemName: "questionmark.folder")
        .font(.system(size: 36))
        .foregroundStyle(.orange)
      Text("This Folder Doesn\u{2019}t Contain Your Previous Backup")
        .font(.headline)
        .multilineTextAlignment(.center)
      Text(
        "None of the files in your export history were found in \u{201C}\(folderName)\u{201D}, "
          + "so your history was kept as it was. Choose the folder that has your earlier "
          + "exports, or use this one as a new backup folder."
      )
      .multilineTextAlignment(.center)
      if let newFolderError {
        Text(newFolderError)
          .font(.caption)
          .foregroundStyle(.orange)
          .multilineTextAlignment(.center)
      }
      HStack(spacing: 12) {
        Button("Use as New Folder", action: useAsNew)
        if onChooseAnotherFolder != nil {
          Button("Choose Another Folder\u{2026}", action: chooseAnother)
            .keyboardShortcut(.defaultAction)
        }
      }
      .buttonStyle(.bordered)
    }
  }

  // MARK: - Result View

  private func resultView(_ report: ImportReport) -> some View {
    let recognized = report.matchedCount + report.collectionMatchedCount
    return VStack(spacing: 16) {
      Image(systemName: recognized > 0 ? "checkmark.circle.fill" : "info.circle.fill")
        .font(.system(size: 36))
        .foregroundColor(recognized > 0 ? .green : .blue)

      Text("Import Complete")
        .font(.headline)

      VStack(alignment: .leading, spacing: 8) {
        ForEach(ImportPresentation.rows(report)) { row in
          VStack(alignment: .leading, spacing: 2) {
            reportRow(label: row.label, value: row.value, icon: row.icon)
            if let caption = row.caption {
              Text(caption).font(.caption).foregroundStyle(.secondary).padding(.leading, 28)
            }
          }
        }
      }
      .padding()
      .background(Color(.controlBackgroundColor))
      .cornerRadius(8)

      if recognized > 0 {
        Text(
          "The app now recognizes \(recognized) previously exported files. Future exports will skip these files."
        )
        .font(.caption)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
      }

      if report.collectionsSkipped {
        Text(
          ImportPresentation.collectionsSkippedGuidance
        )
        .font(.caption)
        .foregroundStyle(.orange)
        .multilineTextAlignment(.center)
      }

      HStack(spacing: 12) {
        Button("Close") {
          dismiss()
        }
        .buttonStyle(.bordered)
        .keyboardShortcut(.cancelAction)

        Button("Export Remaining") {
          dismiss()
          // Brief delay to let the sheet dismiss before starting export
          Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            exportManager.startExportAll()
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!timelineExportAvailability.canStart)
        .help(
          timelineExportAvailability.unavailableHelp(
            destinationHelp: exportDestinationManager.exportUnavailableHelp) ?? "")
      }
    }
  }

  private func reportRow(label: String, value: String, icon: String) -> some View {
    HStack {
      Image(systemName: icon)
        .foregroundColor(.secondary)
        .frame(width: 20)
      Text(label)
      Spacer()
      Text(value)
        .fontWeight(.medium)
        .monospacedDigit()
    }
  }
}
