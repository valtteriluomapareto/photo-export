import SwiftUI

/// Compact AutoSync status indicator for the main-window toolbar. Plan
/// §"Phase 4 / Settings UX": "Show concise main-window status: waiting,
/// scheduled, blocked, running, last run." Slice 1c is just the state pill;
/// last-run summary and failure-summary link land later.
///
/// Hidden when AutoSync is disabled — the toolbar isn't the place to advertise
/// a feature the user hasn't opted into. Tapping the pill opens Settings →
/// Auto Export so the user can act on whatever the pill is showing.
struct AutoSyncStatusPill: View {
  let state: AutoSyncState

  @Environment(\.openSettings) private var openSettings

  var body: some View {
    if case .disabled = state {
      EmptyView()
    } else {
      Button {
        openSettings()
      } label: {
        HStack(spacing: 6) {
          Image(systemName: iconName)
            .foregroundStyle(iconTint)
          Text(label)
            .font(.callout)
            .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(.quaternary)
        )
      }
      .buttonStyle(.plain)
      .help(helpText)
      .accessibilityLabel(accessibilityLabel)
    }
  }

  private var iconName: String {
    switch state {
    case .disabled: return "circle.slash"
    case .idle: return "checkmark.circle.fill"
    case .scheduled: return "clock.fill"
    case .running: return "arrow.triangle.2.circlepath"
    case .waiting: return "pause.circle.fill"
    case .blocked: return "exclamationmark.triangle.fill"
    }
  }

  private var iconTint: Color {
    switch state {
    case .blocked: return .orange
    case .running, .scheduled: return .blue
    case .waiting: return .secondary
    case .idle: return .green
    case .disabled: return .secondary
    }
  }

  private var label: String {
    switch state {
    case .disabled: return "Auto Export off"
    case .idle: return "Auto Export"
    case .scheduled: return "Scheduled"
    case .running: return "Exporting"
    case .waiting: return "Waiting"
    case .blocked: return "Action needed"
    }
  }

  private var helpText: String {
    switch state {
    case .disabled: return "Auto Export is off"
    case .idle: return "Auto Export is up to date. Click to open settings."
    case .scheduled(let reason, let fireAt):
      let secs = max(0, Int(fireAt.timeIntervalSinceNow.rounded()))
      return "Run scheduled (\(reason.shortHelpText)) — fires in \(secs)s"
    case .running(let reason):
      return "Run in progress (\(reason.shortHelpText))"
    case .waiting(let reason):
      return "Waiting: \(reason.shortHelpText)"
    case .blocked(let reason):
      return "Blocked: \(reason.shortHelpText). Click to open settings."
    }
  }

  private var accessibilityLabel: String {
    "Auto Export status: \(label)"
  }
}

extension AutoSyncReason {
  fileprivate var shortHelpText: String {
    switch self {
    case .appLaunch: return "app launch"
    case .destinationSelected: return "destination selected"
    case .destinationBecameAvailable: return "drive reconnected"
    case .scopeSelectionChanged: return "scope changed"
    case .versionSelectionChanged: return "version changed"
    case .photosChanged: return "library changed"
    case .photosChangeFallback: return "library catch-up"
    case .userExportNow: return "Export Now"
    }
  }
}

extension AutoSyncBlockedReason {
  fileprivate var shortHelpText: String {
    switch self {
    case .photosAccessMissing: return "Photos access needed"
    case .limitedPhotosAccess: return "limited Photos access"
    case .destinationMissing: return "no destination selected"
    case .destinationUnavailable: return "drive disconnected"
    case .destinationUnsafe: return "destination needs review"
    case .noScopesSelected: return "pick what to export"
    case .manualExportActive: return "manual export running"
    case .importActive: return "import running"
    case .retryBackoff: return "retrying soon"
    }
  }
}
