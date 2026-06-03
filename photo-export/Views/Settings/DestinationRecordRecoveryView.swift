import SwiftUI

/// Recovery sheet that rebuilds a destination's local export records from the
/// files actually present on the drive, via Import Existing Backup. Serves two
/// blocked-destination states that share the same remedy:
///
/// - `.migrationConflict` — both a current-id and a legacy-id record set exist
///   for the same destination (Plan §"Safety Invariants"). Rebuilding adopts the
///   destination's contents as the current-id store, then the legacy state is
///   GC'd via the lifecycle coordinator.
/// - `.orphanedProgress` — the destination has files but *no* matching records
///   (issue #129). This happens when the per-destination record directory was
///   orphaned (its name derived from security-scoped bookmark bytes that macOS
///   later refreshed), so the app silently presented a fresh 0% store and a
///   re-export would collide with the existing files as ` (1)` duplicates.
///   `DestinationSafetyMonitor` already detects this state; rebuilding restores
///   progress from the drive so subsequent exports skip the already-present
///   files instead of duplicating them.
///
/// Both modes share the rebuild/progress/result machinery; only the explanatory
/// copy and the post-rebuild resolution differ. Resolution is injected as
/// `onRebuildComplete` so this view stays decoupled from whichever collaborator
/// owns the blocked state (the lifecycle coordinator for migration conflicts,
/// the safety monitor for orphaned progress).
///
/// The destination drive's files are never touched — recovery only rebuilds the
/// app's local record store.
struct DestinationRecordRecoveryView: View {
  /// The blocked-destination state this sheet is resolving. Drives copy and,
  /// via the injected closures, the resolution.
  enum Mode: Equatable {
    case migrationConflict
    case orphanedProgress
  }

  let mode: Mode
  /// Invoked once after a rebuild import completes successfully. Migration:
  /// GC the legacy state and clear the conflict. Orphaned progress: confirm the
  /// destination so the safety prompt clears.
  let onRebuildComplete: () -> Void
  /// Accept the destination's existing files as-is, without rebuilding. Only set
  /// for `.orphanedProgress` — the legitimate "these are genuinely new files I
  /// put here" path. `nil` for `.migrationConflict`, where adopting stale records
  /// is exactly what we're trying to avoid.
  let onUseAsIs: (() -> Void)?

  @EnvironmentObject private var lifecycleCoordinator: AppLifecycleCoordinator
  @EnvironmentObject private var exportManager: ExportManager
  @EnvironmentObject private var exportDestinationManager: ExportDestinationManager
  @Environment(\.dismiss) private var dismiss

  /// `idle` → user hasn't started reconciling; show the explainer.
  /// `reconciling` → import is in flight; show progress.
  /// `succeeded` → import completed and the blocked state has been resolved.
  /// `failed` → import surfaced an error; show retry / cancel.
  @State private var phase: Phase = .idle
  /// Tracks user-initiated cancel of an in-flight reconcile so the
  /// `isImporting → false` transition can distinguish "user cancelled"
  /// (silent dismiss) from "import failed" (red error chrome).
  @State private var didCancelReconcile = false

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
    .frame(width: 480, height: 400)
    .onChange(of: exportManager.isImporting) { _, isImporting in
      // Watch for the import-in-flight → done transition. The import was
      // launched by `startReconcile`; `phase == .reconciling` filters out
      // unrelated imports the user might have launched from the menu.
      guard phase == .reconciling, !isImporting else { return }
      if let report = exportManager.importResult {
        onRebuildComplete()
        phase = .succeeded(
          matched: report.matchedCount,
          unmatched: report.unmatchedCount,
          prunedRecords: report.prunedRecords
        )
      } else if didCancelReconcile {
        // User pressed Cancel while reconciling — silent dismiss, not an
        // error state. Just close the sheet.
        dismiss()
      } else {
        // isImporting flipped false without a report and the user did not
        // press Cancel — treat as failure.
        phase = .failed(message: "Import did not complete. Try again or cancel.")
      }
    }
  }

  // MARK: - Subviews

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: headerSymbol)
        .foregroundStyle(.orange)
        .font(.title2)
      VStack(alignment: .leading, spacing: 2) {
        Text(headerTitle)
          .font(.headline)
        Text(headerSubtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
        if mode == .migrationConflict, let conflict = lifecycleCoordinator.migrationConflict {
          DisclosureGroup("Show diagnostic details") {
            VStack(alignment: .leading, spacing: 2) {
              Text("Current id: \(conflict.newId.prefix(12))…")
              Text("Legacy id: \(conflict.legacyId.prefix(12))…")
            }
            .font(.caption.monospaced())
            .foregroundStyle(.tertiary)
          }
          .font(.caption)
          .padding(.top, 4)
        }
      }
    }
  }

  private var headerSymbol: String {
    switch mode {
    case .migrationConflict: return "exclamationmark.triangle.fill"
    case .orphanedProgress: return "exclamationmark.shield.fill"
    }
  }

  private var headerTitle: String {
    switch mode {
    case .migrationConflict: return "Destination Has Unresolved Issues"
    case .orphanedProgress: return "Confirm This Destination"
    }
  }

  private var headerSubtitle: String {
    switch mode {
    case .migrationConflict: return "Conflict: current vs legacy records for the same destination."
    case .orphanedProgress: return "This folder has files but no export records."
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

  @ViewBuilder
  private var idleContent: some View {
    switch mode {
    case .migrationConflict:
      migrationIdleContent
    case .orphanedProgress:
      orphanedProgressIdleContent
    }
  }

  private var migrationIdleContent: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(
        "This destination has two sets of local records — one from the current identity scheme and one from a legacy scheme. Auto Export is blocked because the app can't tell which is authoritative."
      )
      .font(.callout)

      Text("Recommended: **Rebuild Records from Destination**")
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

  private var orphanedProgressIdleContent: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(
        "This folder already contains files, but Photo Export has no record of exporting here."
      )
      .font(.callout)

      Text("If you've exported to this folder before — for example after updating the app or reconnecting the drive — **Rebuild Records from Destination** to restore your progress and avoid creating duplicate files.")
        .font(.callout)
      Text(
        "Rebuilding scans the drive's actual contents and rebuilds the record store from what's already there. Your exported files are not touched."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      Text("If these are genuinely new files you placed here yourself, choose **Use This Destination** instead.")
        .font(.caption)
        .foregroundStyle(.secondary)

      if !canReconcile {
        Label(
          "Rebuild isn't available right now — the destination drive may not be connected.",
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
    case .done: return "Finishing up…"
    case .none: return "Reconciling…"
    }
  }

  private func succeededContent(matched: Int, unmatched: Int, prunedRecords: Int) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(succeededTitle, systemImage: "checkmark.seal.fill")
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
        if mode == .migrationConflict {
          Text("Legacy state directory has been removed.")
            .foregroundStyle(.secondary)
        }
      }
      .font(.callout)
    }
  }

  private var succeededTitle: String {
    switch mode {
    case .migrationConflict: return "Conflict resolved"
    case .orphanedProgress: return "Progress restored"
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
        if let onUseAsIs {
          Button("Use This Destination") {
            onUseAsIs()
            dismiss()
          }
        }
        Button("Rebuild Records from Destination") { startReconcile() }
          .keyboardShortcut(.defaultAction)
          .disabled(!canReconcile)
      case .reconciling:
        Button("Cancel") {
          didCancelReconcile = true
          exportManager.cancelImport()
          // `onChange` observer reads `didCancelReconcile` and dismisses
          // silently rather than showing the failure chrome.
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
    didCancelReconcile = false
    phase = .reconciling
    exportManager.startImport()
    // `startImport()` flips `isImporting` to true synchronously when it actually
    // launches. It can also bail on an internal guard the `canReconcile` gate
    // doesn't mirror — most notably a timeline record store that isn't `.ready`
    // (a corrupt snapshot leaves it `.failed` while still presenting as empty,
    // which is exactly a state that fires this sheet). On those early returns
    // `isImporting` stays false, the `isImporting` change observer never fires,
    // and the sheet would otherwise sit in `.reconciling` forever with only a
    // Cancel button. Detect the no-op start and surface it as a failure the user
    // can retry or dismiss.
    if !exportManager.isImporting {
      phase = .failed(
        message:
          "Couldn't start the rebuild — the destination or its records aren't ready. "
          + "Reconnect the drive if it's disconnected, then try again.")
    }
  }

  /// Same gates `startImport` checks internally, surfaced for the button's
  /// enabled state and the inline explainer.
  private var canReconcile: Bool {
    exportDestinationManager.canImportNow
      && !exportManager.isImporting
      && !exportManager.hasActiveExportWork
  }
}
