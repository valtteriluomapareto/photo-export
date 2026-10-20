import SwiftUI

/// Sheet view that shows import progress and results for "Import Existing Backup…".
struct ImportView: View {
  @EnvironmentObject private var exportManager: ExportManager
  @EnvironmentObject private var exportRecordStore: ExportRecordStore
  @EnvironmentObject private var collectionExportRecordStore: CollectionExportRecordStore
  @EnvironmentObject private var exportDestinationManager: ExportDestinationManager
  @Environment(\.dismiss) private var dismiss

  /// Called for "Choose Another Folder…" after a "previous backup missing" result. The presenter
  /// closes the sheet and opens the folder panel once it has closed.
  var onChooseAnotherFolder: (() -> Void)?

  @State private var newFolderError: String?

  #if DEBUG
    @Environment(\.bodyInvalidationCounter) private var bodyCounter
  #endif

  private func observed(_ text: String, key: String) -> String {
    #if DEBUG
      bodyCounter?.recordText([text], for: key)
    #endif
    return text
  }

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
    // The user must decide what to do with a folder that isn't their previous backup; exports
    // wait until then.
    .interactiveDismissDisabled(exportManager.previousBackupMissing)
  }

  // MARK: - Progress View

  private var progressView: some View {
    #if DEBUG
      bodyCounter?.recordText(["true"], for: "import-progress")
    #endif
    let cancel = {
      exportManager.cancelImport()
      dismiss()
    }
    #if DEBUG
      bodyCounter?.recordAction("import-cancel", action: cancel)
    #endif
    return VStack(spacing: 16) {
      Image(systemName: "arrow.triangle.2.circlepath")
        .font(.system(size: 36))
        .foregroundColor(.accentColor)

      Text(observed("Importing Existing Backup", key: "import-title"))
        .font(.headline)

      Text(observed(stageLabel, key: "import-message"))
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
    case .scanningBackupFolder:
      return "Scanning backup folder\u{2026}"
    case .readingPhotosLibrary:
      return "Reading Photos library\u{2026}"
    case .matchingAssets(let matched, let total):
      return "Matching assets\u{2026} \(matched) found of \(total) files"
    case .rebuildingLocalState:
      return "Rebuilding local state\u{2026}"
    case .reconcilingDiskState:
      return "Pruning records for missing files\u{2026}"
    case .done:
      return "Done"
    case .none:
      return "Preparing\u{2026}"
    }
  }

  private var canRetryImport: Bool {
    exportDestinationManager.canImportNow && exportRecordStore.state == .ready
      && !collectionExportRecordStore.state.needsRecovery
      && !exportManager.isImporting && !exportManager.hasActiveExportWork
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
    #if DEBUG
      bodyCounter?.recordText(["false"], for: "import-progress")
      bodyCounter?.recordText([String(canRetryImport)], for: "import-can-retry")
      bodyCounter?.recordAction("import-retry", action: retry)
      bodyCounter?.recordAction("import-close", action: close)
    #endif
    return VStack(spacing: 16) {
      Image(systemName: error == nil ? "info.circle" : "exclamationmark.triangle")
        .font(.system(size: 36))
        .foregroundStyle(error == nil ? Color.secondary : Color.orange)
      Text(observed(error == nil ? "Import Stopped" : "Import Failed", key: "import-title"))
        .font(.headline)
      Text(observed(error ?? "No import is running.", key: "import-message"))
        .multilineTextAlignment(.center)
      Text(observed(recoveryGuidance, key: "import-recovery"))
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
    let useAsNew = {
      let outcome = exportDestinationManager.useSelectedFolderAsNewDestination()
      newFolderError = exportManager.continueAfterUsingFolderAsNew(outcome)
      if outcome == .newHistory { dismiss() }
    }
    #if DEBUG
      bodyCounter?.recordText(["false"], for: "import-progress")
      bodyCounter?.recordAction("import-choose-another-folder", action: chooseAnother)
      bodyCounter?.recordAction("import-use-as-new-folder", action: useAsNew)
    #endif
    return VStack(spacing: 16) {
      Image(systemName: "questionmark.folder")
        .font(.system(size: 36))
        .foregroundStyle(.orange)
      Text(observed("This Folder Doesn\u{2019}t Contain Your Previous Backup", key: "import-title"))
        .font(.headline)
        .multilineTextAlignment(.center)
      Text(
        observed(
          "None of the files in your export history were found in \u{201C}\(folderName)\u{201D}, "
            + "so your history was kept as it was. Choose the folder that has your earlier "
            + "exports, or use this one as a new backup folder.",
          key: "import-message")
      )
      .multilineTextAlignment(.center)
      if let newFolderError {
        Text(observed(newFolderError, key: "import-new-folder-error"))
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
    #if DEBUG
      bodyCounter?.recordText(["false"], for: "import-progress")
    #endif
    let recognized = report.matchedCount + report.collectionMatchedCount
    return VStack(spacing: 16) {
      Image(systemName: recognized > 0 ? "checkmark.circle.fill" : "info.circle.fill")
        .font(.system(size: 36))
        .foregroundColor(recognized > 0 ? .green : .blue)

      Text(observed("Import Complete", key: "import-title"))
        .font(.headline)

      VStack(alignment: .leading, spacing: 8) {
        reportRow(
          label: "Timeline files scanned",
          value: "\(report.totalScanned)",
          icon: "doc.on.doc"
        )
        reportRow(
          label: "Matched to Photos library",
          value: "\(report.matchedCount)",
          icon: "checkmark.circle"
        )
        if report.ambiguousCount > 0 {
          reportRow(
            label: "Ambiguous (skipped)",
            value: "\(report.ambiguousCount)",
            icon: "questionmark.circle"
          )
        }
        if report.unmatchedCount > 0 {
          reportRow(
            label: "No matching asset found",
            value: "\(report.unmatchedCount)",
            icon: "xmark.circle"
          )
        }
        if report.collectionFilesScanned > 0 {
          reportRow(
            label: "Album and Favorites files scanned",
            value: "\(report.collectionFilesScanned)",
            icon: "rectangle.stack"
          )
          reportRow(
            label: "Album and Favorites files matched",
            value: observed("\(report.collectionMatchedCount)", key: "import-collection-matched"),
            icon: "checkmark.rectangle.stack"
          )
        }
        if !report.unrecognizedCollectionFolders.isEmpty {
          VStack(alignment: .leading, spacing: 2) {
            reportRow(
              label: "Album folders not linked to an album",
              value: observed(
                "\(report.unrecognizedCollectionFolders.count)",
                key: "import-collection-unrecognized"),
              icon: "folder.badge.questionmark"
            )
            Text(
              observed(
                unlinkedFoldersCaption(report.unrecognizedCollectionFolders),
                key: "import-collection-unrecognized-caption")
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 28)
          }
        }
        if report.prunedRecords > 0 || report.prunedVariants > 0 {
          reportRow(
            label: "Records pruned (file missing)",
            value: pruneSummary(report),
            icon: "trash"
          )
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
          observed(
            "Album and Favorites history wasn\u{2019}t rebuilt because it isn\u{2019}t available. Resolve the export history alert, then import again.",
            key: "import-collections-skipped")
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
      }
    }
  }

  /// Names up to three unlinked folders by their path below `Collections/<root>/`, then the
  /// explanation.
  private func unlinkedFoldersCaption(_ folders: [String]) -> String {
    let names = folders.prefix(3).map { "\u{201C}\(collectionFolderName($0))\u{201D}" }
    let more = folders.count > 3 ? " and \(folders.count - 3) more" : ""
    return names.joined(separator: ", ") + more
      + ". These are usually albums renamed, moved or deleted in Photos since they were "
      + "exported. Their files are left as they are."
  }

  /// `Collections/Albums/Trips/Paris/` → `Trips/Paris`.
  private func collectionFolderName(_ path: String) -> String {
    let components = path.split(separator: "/").map(String.init)
    let below = components.count > 2 ? components.dropFirst(2) : components[...]
    return below.joined(separator: "/")
  }

  private func pruneSummary(_ report: ImportReport) -> String {
    if report.prunedVariants == report.prunedRecords {
      return "\(report.prunedRecords)"
    }
    return "\(report.prunedRecords) records, \(report.prunedVariants) variants"
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
