import SwiftUI

/// Settings → Auto Export tab. The user-visible surface for AutoSync. Plan
/// §"Phase 4 / Settings UX": enable toggle, scope checkboxes, current status,
/// Export Now action, last run summary.
///
/// Scope: this is Slice 1 of Phase 4 — minimal but functional. Limited-library
/// notice, Export Issues link, and notification preferences land in subsequent
/// slices.
struct AutoExportSettingsView: View {
  @EnvironmentObject private var autoSyncManager: AutoSyncManager
  @EnvironmentObject private var scopeStore: UserDefaultsAutoExportScopeStore
  @EnvironmentObject private var exportDestinationManager: ExportDestinationManager
  @EnvironmentObject private var lifecycleCoordinator: AppLifecycleCoordinator
  @EnvironmentObject private var loginItemController: LoginItemController
  @EnvironmentObject private var safetyMonitor: DestinationSafetyMonitor
  @EnvironmentObject private var photoChangeAdapter: PhotoLibraryPersistentChangeAdapter

  @State private var isShowingMigrationRecoverySheet = false
  @State private var isShowingSafetyConfirm = false

  var body: some View {
    Form {
      if lifecycleCoordinator.migrationConflict != nil {
        Section {
          MigrationConflictBanner {
            isShowingMigrationRecoverySheet = true
          }
          .listRowInsets(EdgeInsets())
        }
      } else if safetyMonitor.needsSafetyConfirmation {
        Section {
          SafetyConfirmationBanner {
            isShowingSafetyConfirm = true
          }
          .listRowInsets(EdgeInsets())
        }
      }

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

      Section("Status") {
        StatusSummaryRow(state: autoSyncManager.state)
        if let summary = autoSyncManager.lastRunSummary {
          LastRunRow(summary: summary)
        }
        LastReconciledRow(timestamp: photoChangeAdapter.lastSuccessfulReconciliation)
      }

      Section {
        HStack {
          Spacer()
          Button("Export Now") {
            autoSyncManager.runNow()
          }
          .disabled(!canRunNow)
        }
      } footer: {
        Text(exportNowFooter)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Startup") {
        Toggle(
          isOn: Binding(
            get: { loginItemController.status == .enabled },
            set: { newValue in
              if newValue {
                loginItemController.register()
              } else {
                loginItemController.unregister()
              }
            }
          )
        ) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Open Photo Export at login")
            Text(loginItemFooter)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        if loginItemController.status == .requiresApproval {
          Button("Open System Settings\u{2026}") {
            loginItemController.openSystemLoginItems()
          }
        }
      }
    }
    .onAppear { loginItemController.refresh() }
    .formStyle(.grouped)
    .frame(minWidth: 460, minHeight: 460)
    .sheet(isPresented: $isShowingMigrationRecoverySheet) {
      MigrationConflictRecoveryView()
        .environmentObject(lifecycleCoordinator)
        .environmentObject(exportManagerFromEnvironment)
        .environmentObject(exportDestinationManager)
    }
    .confirmationDialog(
      "Confirm Destination",
      isPresented: $isShowingSafetyConfirm,
      titleVisibility: .visible
    ) {
      Button("Use This Destination") {
        safetyMonitor.confirmCurrentDestination()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "The selected destination already contains files, but this app has no record of exporting to it. If those files belong to you and you want Auto Export to add to this folder, confirm. Auto Export will never delete or overwrite existing files."
      )
    }
  }

  // SwiftUI environment objects don't get auto-propagated across sheet
  // boundaries on macOS in all configurations, so re-pass them explicitly.
  // The sheet's view re-declares the same @EnvironmentObjects.
  @EnvironmentObject private var exportManagerFromEnvironment: ExportManager

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

  // MARK: - Run Now eligibility

  private var canRunNow: Bool {
    switch autoSyncManager.state {
    case .disabled, .blocked, .running:
      return false
    case .idle, .scheduled, .waiting:
      return true
    }
  }

  private var loginItemFooter: String {
    switch loginItemController.status {
    case .enabled:
      return "Photo Export will start automatically when you log in."
    case .requiresApproval:
      return
        "macOS is waiting for you to confirm in System Settings → Login Items."
    case .notRegistered:
      return "Photo Export won't auto-start at login."
    case .notFound:
      return
        "Move Photo Export into your Applications folder to enable launch at login."
    case .unknown:
      return "Status unknown — check System Settings → Login Items."
    }
  }

  private var exportNowFooter: String {
    switch autoSyncManager.state {
    case .disabled:
      return "Enable Auto Export above to use Export Now."
    case .blocked(.noScopesSelected):
      return "Pick at least one scope above first."
    case .blocked(.destinationMissing):
      return "Select an export destination first."
    case .blocked(.destinationUnsafe):
      return "The destination has unresolved issues. Open the destination indicator to review."
    case .blocked:
      return "Auto Export is blocked. Resolve the issue above to run now."
    case .running:
      return "A run is already in progress."
    case .waiting(.destinationUnavailable):
      return
        "The destination drive isn't connected. Export Now will queue the run for when it's reachable."
    case .waiting:
      return "Auto Export will run shortly."
    case .scheduled, .idle:
      return "Bypass the debounce and start a run right now."
    }
  }
}

// MARK: - Subviews

private struct MigrationConflictBanner: View {
  let onTap: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .font(.title3)
      VStack(alignment: .leading, spacing: 4) {
        Text("Destination Has Unresolved Issues")
          .font(.headline)
        Text(
          "This destination has both current and legacy record sets. Auto Export is blocked until you resolve which to use."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        HStack {
          Spacer()
          Button("Resolve\u{2026}") { onTap() }
            .controlSize(.regular)
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.orange.opacity(0.1))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color.orange.opacity(0.4), lineWidth: 1)
    )
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
  }
}

private struct SafetyConfirmationBanner: View {
  let onTap: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "exclamationmark.shield.fill")
        .foregroundStyle(.orange)
        .font(.title3)
      VStack(alignment: .leading, spacing: 4) {
        Text("Confirm This Destination")
          .font(.headline)
        Text(
          "The destination folder already contains files. Auto Export needs you to confirm it's your backup before it starts writing."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        HStack {
          Spacer()
          Button("Review\u{2026}") { onTap() }
            .controlSize(.regular)
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.orange.opacity(0.1))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color.orange.opacity(0.4), lineWidth: 1)
    )
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
  }
}

private struct StatusSummaryRow: View {
  let state: AutoSyncState

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: iconName)
        .foregroundStyle(iconTint)
      VStack(alignment: .leading, spacing: 2) {
        Text(headline)
        // TimelineView ticks once a second so the .scheduled countdown
        // ("fires in 9s", "fires in 8s", …) updates without depending on
        // an external state change to force a re-render.
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
          if let detail = detail(now: ctx.date) {
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

  private var headline: String {
    switch state {
    case .disabled: return "Auto Export is off"
    case .idle: return "Up to date"
    case .scheduled: return "Run scheduled"
    case .running: return "Exporting\u{2026}"
    case .waiting(let reason): return "Waiting — \(reason.userFacingLabel)"
    case .blocked(let reason): return "Blocked — \(reason.userFacingLabel)"
    }
  }

  private func detail(now: Date) -> String? {
    switch state {
    case .scheduled(let reason, let fireAt):
      let secs = max(0, Int(fireAt.timeIntervalSince(now).rounded()))
      return "\(reason.userFacingLabel) — fires in \(secs)s"
    case .running(let reason):
      return reason.userFacingLabel
    default:
      return nil
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
        Text(detail)
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

  private var detail: String {
    let counts = "\(summary.completedCount) exported"
    let failedSuffix = summary.failedCount > 0 ? ", \(summary.failedCount) failed" : ""
    let resultSuffix = summary.result == .completed ? "" : " (\(summary.result.rawValue))"
    return counts + failedSuffix + resultSuffix
  }
}

/// Shows when the safety-net reconcile last consulted PhotoKit. Trust signal for
/// the issue #69 fix: if the user opens Settings hours into a long iCloud-sync
/// session and the line still reads "a few minutes ago," they know the
/// background-check loop is alive. `nil` (the very-first-launch case, before any
/// reconcile has completed) renders as a dim "Never" — meaningful enough that we
/// don't hide the row entirely, since hiding it makes a freshly-launched user
/// think the feature doesn't exist.
private struct LastReconciledRow: View {
  let timestamp: Date?

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "icloud")
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text(label)
        Text("Photo Export checks for new iCloud photos automatically.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var label: String {
    guard let timestamp else { return "Last checked iCloud: never" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return "Last checked iCloud \(formatter.localizedString(for: timestamp, relativeTo: Date()))"
  }
}

// MARK: - Description helpers

// Per-view label extensions removed — surface uses
// `AutoSyncReason.userFacingLabel` / `AutoSyncBlockedReason.userFacingLabel`
// directly. See `AutoSyncReason.swift`.
