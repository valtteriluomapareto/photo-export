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

  var body: some View {
    Form {
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
      }

      Section("Status") {
        StatusSummaryRow(state: autoSyncManager.state)
        if let summary = autoSyncManager.lastRunSummary {
          LastRunRow(summary: summary)
        }
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
    }
    .formStyle(.grouped)
    .frame(minWidth: 460, minHeight: 460)
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

  private func scopeRow(title: String, description: String, isOn: Binding<Bool>) -> some View {
    Toggle(isOn: isOn) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
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

private struct StatusSummaryRow: View {
  let state: AutoSyncState

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: iconName)
        .foregroundStyle(iconTint)
      VStack(alignment: .leading, spacing: 2) {
        Text(headline)
        if let detail {
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
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
    case .running: return "Exporting…"
    case .waiting(let reason): return "Waiting (\(reason.shortDescription))"
    case .blocked(let reason): return "Blocked (\(reason.shortDescription))"
    }
  }

  private var detail: String? {
    switch state {
    case .scheduled(let reason, let fireAt):
      let secs = max(0, Int(fireAt.timeIntervalSinceNow.rounded()))
      return "\(reason.shortDescription) — fires in \(secs)s"
    case .running(let reason):
      return reason.shortDescription
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

// MARK: - Description helpers

extension AutoSyncBlockedReason {
  fileprivate var shortDescription: String {
    switch self {
    case .photosAccessMissing: return "Photos access needed"
    case .limitedPhotosAccess: return "limited Photos access"
    case .destinationMissing: return "no destination"
    case .destinationUnavailable: return "drive disconnected"
    case .destinationUnsafe: return "destination unsafe"
    case .noScopesSelected: return "pick what to export"
    case .manualExportActive: return "manual export running"
    case .importActive: return "import running"
    case .retryBackoff: return "retrying soon"
    }
  }
}

extension AutoSyncReason {
  fileprivate var shortDescription: String {
    switch self {
    case .appLaunch: return "app launch"
    case .destinationSelected: return "destination selected"
    case .destinationBecameAvailable: return "drive reconnected"
    case .scopeSelectionChanged: return "scope changed"
    case .versionSelectionChanged: return "version changed"
    case .photosChanged: return "photos changed"
    case .photosChangeFallback: return "library catch-up"
    case .userExportNow: return "Export Now"
    }
  }
}
