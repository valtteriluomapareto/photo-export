import SwiftUI

/// Settings → Auto Export: enablement, scope selection, current status, Export Now,
/// run summary, login-item status and destination recovery. These settings stay
/// separate from manual toolbar feedback.
/// See docs/reference/auto-export-behavior.md#run-ownership-and-presentation.
struct AutoExportSettingsView: View {
  @EnvironmentObject private var autoSyncManager: AutoSyncManager
  @EnvironmentObject private var scopeStore: UserDefaultsAutoExportScopeStore
  @Environment(LoginItemController.self) private var loginItemController
  @EnvironmentObject private var photoChangeAdapter: PhotoLibraryPersistentChangeAdapter
  @EnvironmentObject private var lifecycleCoordinator: AppLifecycleCoordinator
  @EnvironmentObject private var safetyMonitor: DestinationSafetyMonitor
  @EnvironmentObject private var exportDestinationManager: ExportDestinationManager
  @Environment(ExportManager.self) private var exportManagerFromEnvironment
  // The Form presents the recovery sheets because a completed rebuild clears the prompt
  // that opened them before the sheet shows its result and Done button.
  @State private var isShowingMigrationRecoverySheet = false
  @State private var isShowingSafetyConfirm = false

  var body: some View {
    Form {
      AutoExportRecoveryPrompt(
        hasMigrationConflict: lifecycleCoordinator.migrationConflict != nil,
        needsSafetyConfirmation: safetyMonitor.needsSafetyConfirmation,
        showMigrationRecovery: { isShowingMigrationRecoverySheet = true },
        showSafetyConfirmation: { isShowingSafetyConfirm = true })

      Section {
        Toggle(
          isOn: Binding(
            get: { autoSyncManager.isEnabled },
            set: { autoSyncManager.setEnabled($0) }
          )
        ) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Enable Auto Export")
            Text(
              "Automatically export new photos to your destination as they appear in Photos."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }
      }

      Section("What to Export") {
        scopeRow(
          title: "Timeline",
          description: "All photos and videos.",
          isOn: scopeBinding(\.timeline) { $0.timeline = $1 }
        )
        scopeRow(
          title: "Favorites",
          description: "Just photos you've marked as favorites.",
          isOn: scopeBinding(\.favorites) { $0.favorites = $1 }
        )
        scopeRow(
          title: "Albums",
          description: "All user-created albums.",
          isOn: scopeBinding(\.albums) { $0.albums = $1 }
        )
        // iCloud shared albums are opt-in via their own row. The reduced-quality
        // caveat sits as a tertiary warning line (yellow triangle + caption)
        // rather than inline with the description, so the visual weight matches
        // its function — a caution, not just another scope description. Mirrors
        // the in-pane shared-album banner in `CollectionContentView`.
        scopeRow(
          title: "Shared Albums",
          description: "Albums shared with you via iCloud.",
          warning: "Reduced quality — Apple only provides downscaled JPEGs.",
          isOn: scopeBinding(\.sharedAlbums) { $0.sharedAlbums = $1 }
        )
      }

      Section {
        StatusSummaryRow(state: autoSyncManager.state)
        LastReconciledRow(timestamp: photoChangeAdapter.lastSuccessfulReconciliation)
        if let catchUp = photoChangeAdapter.lastCatchUpSummary {
          LastCatchUpRow(summary: catchUp)
        }
        if let summary = autoSyncManager.lastRunSummary {
          LastRunRow(summary: summary)
        }
      } header: {
        Text("Status")
      } footer: {
        Text("Photo Export periodically checks for new photos and refreshes automatically.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section {
        HStack {
          Spacer()
          Button("Export Now") {
            autoSyncManager.runNow()
          }
          .disabled(!autoSyncManager.state.canRunNow)
        }
      } footer: {
        let message = AutoExportPresentation.exportNowFooter(autoSyncManager.state)
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Startup") {
        LoginItemSettingsControls()
      }
    }
    .onAppear { loginItemController.refresh() }
    .formStyle(.grouped)
    .frame(minWidth: 460, minHeight: 460)
    .sheet(isPresented: $isShowingMigrationRecoverySheet) {
      DestinationRecordRecoveryView(
        mode: .migrationConflict,
        onRebuildComplete: { lifecycleCoordinator.clearMigrationConflictAfterReconcile() },
        onUseAsIs: nil
      )
      .environmentObject(lifecycleCoordinator)
      .environment(exportManagerFromEnvironment)
      .environmentObject(exportDestinationManager)
    }
    .sheet(isPresented: $isShowingSafetyConfirm) {
      // The destination has files but no records. Offer to rebuild
      // progress from the drive (so re-exports skip the existing files instead
      // of creating ` (1)` duplicates) as well as the plain "these are my
      // pre-existing files" confirm. Both resolve the safety prompt by
      // confirming the destination; the rebuild path additionally restores the
      // record store from the drive's contents first.
      DestinationRecordRecoveryView(
        mode: .orphanedProgress,
        onRebuildComplete: { safetyMonitor.confirmCurrentDestination() },
        onUseAsIs: { safetyMonitor.confirmCurrentDestination() }
      )
      .environmentObject(lifecycleCoordinator)
      .environment(exportManagerFromEnvironment)
      .environmentObject(exportDestinationManager)
    }
  }

  // MARK: - Scope binding helper

  private func scopeBinding(
    _ keyPath: KeyPath<AutoExportScopeSelection, Bool>,
    _ apply: @escaping (inout AutoExportScopeSelection, Bool) -> Void
  ) -> Binding<Bool> {
    Binding(
      get: { scopeStore.selection[keyPath: keyPath] },
      set: { newValue in
        var next = scopeStore.selection
        apply(&next, newValue)
        scopeStore.setSelection(next)
      }
    )
  }

  /// Standard Auto-Export scope toggle row. `warning`, when set, renders a
  /// tertiary caution line below the description — yellow `exclamationmark.
  /// triangle.fill` glyph + caption text, matching the visual grammar of the
  /// in-pane shared-album banner in `CollectionContentView`. Use it for scopes
  /// where toggling on has a non-obvious quality or privacy cost; leave it
  /// `nil` for scopes whose row description is the whole story.
  private func scopeRow(
    title: String,
    description: String,
    warning: String? = nil,
    isOn: Binding<Bool>
  ) -> some View {
    Toggle(isOn: isOn) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
        if let warning {
          HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.yellow)
              .font(.caption2)
            Text(warning)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

}

// MARK: - Subviews

private struct StatusSummaryRow: View {
  let state: AutoSyncState

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: iconName)
        .foregroundStyle(iconTint)
      VStack(alignment: .leading, spacing: 2) {
        Text(AutoExportPresentation.statusHeadline(state))
        // TimelineView ticks once a second so the .scheduled countdown
        // ("fires in 9s", "fires in 8s", …) updates without depending on
        // an external state change to force a re-render.
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
          if let detail = AutoExportPresentation.statusDetail(state, now: ctx.date) {
            Text(detail)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private var iconName: String {
    switch state {
    case .disabled: return "circle.slash"
    case .idle: return "checkmark.circle"
    case .scheduled: return "clock"
    case .running: return "arrow.triangle.2.circlepath"
    case .waiting: return "pause.circle"
    case .blocked: return "exclamationmark.triangle"
    }
  }

  private var iconTint: Color {
    switch state {
    case .blocked: return .orange
    case .running: return .blue
    case .scheduled: return .blue
    case .waiting: return .secondary
    case .idle: return .green
    case .disabled: return .secondary
    }
  }

}

private struct LastRunRow: View {
  let summary: ExportRunSummary

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "clock.arrow.circlepath")
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text("Last run \(relativeTime)")
        Text(AutoExportPresentation.lastRunDetail(summary))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var relativeTime: String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: summary.endedAt, relativeTo: Date())
  }

}

/// Shows when the safety-net reconcile last consulted PhotoKit. Trust signal for
/// ongoing change observation: if the user opens Settings during a long iCloud-sync
/// session and the line still reads "a few minutes ago," they know the
/// background-check loop is alive.
///
/// Wrapped in `TimelineView(.periodic)` so the relative-time string updates on
/// its own between reconciles (otherwise the row would freeze at the time of
/// the most recent update and only refresh when something else re-rendered the
/// Form). The first reconcile fires within milliseconds of `start()` so the
/// `Checking…` state is essentially a startup placeholder.
private struct LastReconciledRow: View {
  let timestamp: Date?

  /// Single shared formatter — `RelativeDateTimeFormatter` is non-trivial to
  /// construct and the value is identical for every render of this row.
  private static let formatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f
  }()

  var body: some View {
    TimelineView(.periodic(from: .now, by: 30)) { context in
      HStack(spacing: 8) {
        Image(systemName: "arrow.clockwise")
          .foregroundStyle(.secondary)
        Text(label(now: context.date))
      }
    }
  }

  private func label(now: Date) -> String {
    guard let timestamp else { return "Checking\u{2026}" }
    return "Last updated \(Self.formatter.localizedString(for: timestamp, relativeTo: now))"
  }
}

/// Latest iCloud-Photos catch-up summary — duration + outcome — surfaced so a
/// reporter who hit a launch beachball can confirm the
/// off-main-actor catch-up actually completed once the fix shipped. Renders
/// quietly: only appears when there's a summary to show.
private struct LastCatchUpRow: View {
  let summary: PhotoLibraryPersistentChangeAdapter.CatchUpSummary

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "tray.and.arrow.down")
        .foregroundStyle(.secondary)
      Text(AutoExportPresentation.catchUpLabel(summary))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

}

// MARK: - Description helpers

// Per-view label extensions removed — surface uses
// `AutoSyncReason.userFacingLabel` / `AutoSyncBlockedReason.userFacingLabel`
// directly. See `AutoSyncReason.swift`.
