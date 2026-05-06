import SwiftUI

/// Sheet view that shows import progress and results for "Import Existing Backup…".
struct ImportView: View {
  @EnvironmentObject private var exportManager: ExportManager
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 20) {
      if let report = exportManager.importResult {
        resultView(report)
      } else {
        progressView
      }
    }
    .padding(24)
    .frame(width: 420)
  }

  // MARK: - Progress View

  private var progressView: some View {
    VStack(spacing: 16) {
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

      Button("Cancel") {
        exportManager.cancelImport()
        dismiss()
      }
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

  // MARK: - Result View

  private func resultView(_ report: ImportReport) -> some View {
    VStack(spacing: 16) {
      Image(systemName: report.matchedCount > 0 ? "checkmark.circle.fill" : "info.circle.fill")
        .font(.system(size: 36))
        .foregroundColor(report.matchedCount > 0 ? .green : .blue)

      Text("Import Complete")
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
