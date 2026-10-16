import SwiftUI

/// Sheet view that shows import progress and results for "Import Existing Backup…".
struct ImportView: View {
  @EnvironmentObject private var exportManager: ExportManager
  @EnvironmentObject private var exportRecordStore: ExportRecordStore
  @EnvironmentObject private var collectionExportRecordStore: CollectionExportRecordStore
  @EnvironmentObject private var exportDestinationManager: ExportDestinationManager
  @Environment(\.dismiss) private var dismiss

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
      if let report = exportManager.importResult {
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

  // MARK: - Result View

  private func resultView(_ report: ImportReport) -> some View {
    #if DEBUG
      bodyCounter?.recordText(["false"], for: "import-progress")
    #endif
    return VStack(spacing: 16) {
      Image(systemName: report.matchedCount > 0 ? "checkmark.circle.fill" : "info.circle.fill")
        .font(.system(size: 36))
        .foregroundColor(report.matchedCount > 0 ? .green : .blue)

      Text(observed("Import Complete", key: "import-title"))
        .font(.headline)

      VStack(alignment: .leading, spacing: 8) {
        reportRow(
          label: "Files scanned",
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

      if report.matchedCount > 0 {
        Text(
          "The app now recognizes \(report.matchedCount) previously exported files. Future exports will skip these assets."
        )
        .font(.caption)
        .foregroundColor(.secondary)
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
