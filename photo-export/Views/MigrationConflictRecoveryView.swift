import SwiftUI

/// Recovery sheet for the migration-conflict blocked state. Plan §"Safety
/// Invariants": "When destination state blocks app functionality, the
/// resolution path is user action, not app cleanup" — this sheet is the
/// user-action surface.
///
/// MVP recovery offers a single action: **Reconcile from destination**. Runs
/// Import Existing Backup against the current destination so the
/// new-id record store is rebuilt from the destination's actual contents,
/// then GCs the legacy id's app-internal state directories via the lifecycle
/// coordinator. The destination drive's files are never touched.
///
/// Two other actions named in the plan ("Keep legacy records", "Start fresh")
/// are deferred — they have additional safety concerns ("Keep legacy" would
/// silently use stale records, "Start fresh" would cause collision-suffixed
/// duplicates on re-export) that need a richer confirmation flow.
struct MigrationConflictRecoveryView: View {
  @EnvironmentObject private var lifecycleCoordinator: AppLifecycleCoordinator
  @EnvironmentObject private var exportManager: ExportManager
  @EnvironmentObject private var exportDestinationManager: ExportDestinationManager
  @Environment(\.dismiss) private var dismiss

  /// `idle` → user hasn't started reconciling; show the explainer.
  /// `reconciling` → import is in flight; show progress.
  /// `succeeded` → import completed and the legacy state has been GC'd.
  /// `failed` → import surfaced an error; show retry / cancel.
  @State private var phase: Phase = .idle

  private enum Phase: Equatable {
    case idle
    case reconciling
    case succeeded(matched: Int, unmatched: Int, prunedRecords: Int)
    case failed(message: String)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      header
      Divider()
      content
      Spacer(minLength: 0)
      footer
    }
    .padding(24)
    .frame(width: 480, height: 380)
    .onChange(of: exportManager.isImporting) { _, isImporting in
      // Watch for the import-in-flight → done transition. The import was
      // launched by `startReconcile`; `phase == .reconciling` filters out
      // unrelated imports the user might have launched from the menu.
      guard phase == .reconciling, !isImporting else { return }
      if let report = exportManager.importResult {
        lifecycleCoordinator.clearMigrationConflictAfterReconcile()
        phase = .succeeded(
          matched: report.matchedCount,
          unmatched: report.unmatchedCount,
          prunedRecords: report.prunedRecords
        )
      } else {
        // isImporting flipped false without a report — cancelled or failed.
        phase = .failed(message: "Import did not complete. Try again or cancel.")
      }
    }
  }

  // MARK: - Subviews

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .font(.title2)
      VStack(alignment: .leading, spacing: 2) {
        Text("Destination Has Unresolved Issues")
          .font(.headline)
        if let conflict = lifecycleCoordinator.migrationConflict {
          Text("Conflict: current vs legacy records for the same destination.")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(
            "Current id: \(conflict.newId.prefix(12))…  Legacy id: \(conflict.legacyId.prefix(12))…"
          )
          .font(.caption.monospaced())
          .foregroundStyle(.tertiary)
        }
      }
    }
  }

  @ViewBuilder
  private var content: some View {
    switch phase {
    case .idle:
      idleContent
    case .reconciling:
      reconcilingContent
    case .succeeded(let matched, let unmatched, let prunedRecords):
      succeededContent(matched: matched, unmatched: unmatched, prunedRecords: prunedRecords)
    case .failed(let message):
      failedContent(message: message)
    }
  }

  private var idleContent: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(
        "This destination has two sets of local records — one from the current identity scheme and one from a legacy scheme. Auto Export is blocked because the app can't tell which is authoritative."
      )
      .font(.callout)

      Text("Recommended: **Reconcile from destination**")
        .font(.callout)
      Text(
        "Scans the destination drive's actual contents, rebuilds the current record store from what's there, then removes the legacy duplicate. Your exported files are not touched."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      if !canReconcile {
        Label(
          "Import isn't available right now — the destination drive may not be connected.",
          systemImage: "info.circle"
        )
        .font(.caption)
        .foregroundStyle(.orange)
      }
    }
  }

  private var reconcilingContent: some View {
    VStack(alignment: .leading, spacing: 8) {
      ProgressView()
        .progressViewStyle(.linear)
      Text(reconcileStageLabel)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var reconcileStageLabel: String {
    switch exportManager.importStage {
    case .scanningBackupFolder: return "Scanning destination folder…"
    case .readingPhotosLibrary: return "Reading Photos library…"
    case .matchingAssets(let matched, let total):
      return "Matching assets… \(matched) found of \(total) files"
    case .rebuildingLocalState: return "Rebuilding local state…"
    case .reconcilingDiskState: return "Pruning records for missing files…"
    case .done: return "Cleaning up legacy state…"
    case .none: return "Reconciling…"
    }
  }

  private func succeededContent(matched: Int, unmatched: Int, prunedRecords: Int) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Conflict resolved", systemImage: "checkmark.seal.fill")
        .foregroundStyle(.green)
        .font(.headline)
      VStack(alignment: .leading, spacing: 4) {
        Text("• \(matched) files matched to Photos library assets")
        if unmatched > 0 {
          Text("• \(unmatched) files at the destination had no matching asset (left in place)")
            .foregroundStyle(.secondary)
        }
        if prunedRecords > 0 {
          Text("• \(prunedRecords) stale records pruned")
            .foregroundStyle(.secondary)
        }
        Text("Legacy state directory has been removed.")
          .foregroundStyle(.secondary)
      }
      .font(.callout)
    }
  }

  private func failedContent(message: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Reconcile didn't finish", systemImage: "xmark.circle")
        .foregroundStyle(.red)
        .font(.headline)
      Text(message)
        .font(.callout)
    }
  }

  // MARK: - Footer

  private var footer: some View {
    HStack {
      Spacer()
      switch phase {
      case .idle:
        Button("Cancel") { dismiss() }
        Button("Reconcile from destination") { startReconcile() }
          .keyboardShortcut(.defaultAction)
          .disabled(!canReconcile)
      case .reconciling:
        Button("Cancel") {
          exportManager.cancelImport()
          // The `onChange` observer will flip us to `.failed` once
          // `isImporting` settles back to false.
        }
      case .succeeded:
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
      case .failed:
        Button("Cancel") { dismiss() }
        Button("Try Again") { phase = .idle }
          .keyboardShortcut(.defaultAction)
      }
    }
  }

  private func startReconcile() {
    guard canReconcile else { return }
    phase = .reconciling
    exportManager.startImport()
  }

  /// Same gates `startImport` checks internally, surfaced for the button's
  /// enabled state and the inline explainer.
  private var canReconcile: Bool {
    exportDestinationManager.canImportNow
      && !exportManager.isImporting
      && !exportManager.hasActiveExportWork
  }
}
