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
      // Issue #106 / HIG: consumer language, not developer verbs.
      return "Saving import results\u{2026}"
    case .reconcilingDiskState:
      return "Cleaning up records for deleted files\u{2026}"
    case .done:
      return "Done"
    case .none:
      return "Preparing\u{2026}"
    }
  }

  // MARK: - Result View

  @ViewBuilder
  private func resultView(_ report: ImportReport) -> some View {
    if let failureReason = report.failureReason {
      failureView(reason: failureReason)
    } else {
      successView(report)
    }
  }

  /// Failure result sheet. Issue #106: shown when the coordinator refused
  /// the import for a recoverable reason (e.g. corrupt collection-store
  /// snapshot). HIG: actionable error copy + a single Close button so the
  /// user is never stuck on the progress view.
  private func failureView(reason: String) -> some View {
    VStack(spacing: 16) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 36))
        .foregroundColor(.orange)

      Text("Import Couldn't Run")
        .font(.headline)

      Text(reason)
        .font(.subheadline)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 360)

      Button("Close") {
        dismiss()
      }
      .buttonStyle(.borderedProminent)
      .keyboardShortcut(.cancelAction)
    }
  }

  private func successView(_ report: ImportReport) -> some View {
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
        // Issue #106 / HIG progressive disclosure: only surface the album
        // sub-line when the user has any collection-side matches, so the
        // timeline-only path keeps its original layout.
        if report.collectionMatchedCount > 0 {
          HStack {
            Image(systemName: "rectangle.stack")
              .foregroundColor(.secondary)
              .frame(width: 20)
            Text("including \(report.collectionMatchedCount) in albums")
              .font(.caption)
              .foregroundColor(.secondary)
            Spacer()
          }
          .padding(.leading, 4)
        }
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
        // Issue #106 / HIG actionable errors: name the situation when
        // unmatched files came from orphan folders, so the user knows it's
        // not corruption.
        if report.orphanCollectionFolders > 0 {
          HStack {
            Image(systemName: "folder.badge.questionmark")
              .foregroundColor(.secondary)
              .frame(width: 20)
            Text("Some folders no longer match an album in Photos. They were skipped.")
              .font(.caption)
              .italic()
              .foregroundColor(.secondary)
          }
          .padding(.leading, 4)
        }
        if report.prunedRecords > 0 || report.prunedVariants > 0 {
          reportRow(
            label: "Cleaned up for deleted files",
            value: pruneSummary(report),
            icon: "trash"
          )
        }
      }
      .padding()
      .background(Color(.controlBackgroundColor))
      .cornerRadius(8)

      if report.matchedCount > 0 {
        Text(captionText(report))
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

  /// Final caption under the result rows. Issue #106 weaves the collection
  /// matched count into the same sentence when nonzero so the user sees
  /// "including N in albums" without an extra paragraph.
  private func captionText(_ report: ImportReport) -> String {
    if report.collectionMatchedCount > 0 {
      return
        "The app now recognizes \(report.matchedCount) previously exported files, including \(report.collectionMatchedCount) in albums. Future exports will skip these assets."
    }
    return
      "The app now recognizes \(report.matchedCount) previously exported files. Future exports will skip these assets."
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
