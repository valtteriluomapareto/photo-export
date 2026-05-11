import SwiftUI

/// Compact AutoSync status indicator for the main-window toolbar. Plan
/// §"Phase 4 / Settings UX": "Show concise main-window status: waiting,
/// scheduled, blocked, running, last run." Slice 1c is just the state pill;
/// last-run summary and failure-summary link land later.
///
/// Always visible — when AutoSync is off, it renders in a subdued style as
/// "Auto Export off" so the user has a one-click path back to Settings →
/// Auto Export after disabling. (The pill was hidden in the initial Slice
/// 1c; manual testing showed the resulting discovery gap.) Clicking the
/// pill always opens Settings.
struct AutoSyncStatusPill: View {
  let state: AutoSyncState

  @Environment(\.openSettings) private var openSettings

  var body: some View {
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
      .opacity(isDisabled ? 0.6 : 1.0)
    }
    .buttonStyle(.plain)
    .help(helpText)
    .accessibilityLabel(accessibilityLabel)
  }

  private var isDisabled: Bool {
    if case .disabled = state { return true }
    return false
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
    case .idle: return "Up to date"
    case .scheduled: return "Scheduled"
    case .running: return "Exporting"
    case .waiting: return "Waiting"
    case .blocked(let reason):
      // Inline the reason so the pill is informative at-a-glance. The
      // pill's `.lineLimit(1)` truncates if the toolbar is narrow; for
      // most reasons the label fits comfortably.
      return "Action needed — \(reason.userFacingLabel)"
    }
  }

  private var helpText: String {
    switch state {
    case .disabled: return "Auto Export is off. Click to open settings."
    case .idle: return "Auto Export is up to date. Click to open settings."
    case .scheduled(let reason, let fireAt):
      let secs = max(0, Int(fireAt.timeIntervalSinceNow.rounded()))
      return "Run scheduled (\(reason.userFacingLabel)) — fires in \(secs)s"
    case .running(let reason):
      return "Run in progress (\(reason.userFacingLabel))"
    case .waiting(let reason):
      return "Waiting: \(reason.userFacingLabel)"
    case .blocked(let reason):
      return "Blocked: \(reason.userFacingLabel). Click to open settings."
    }
  }

  private var accessibilityLabel: String {
    // Include the "why" for blocked / waiting states so VoiceOver users
    // hear the reason inline, not just the generic "Action needed".
    switch state {
    case .blocked(let reason):
      return "Auto Export blocked: \(reason.userFacingLabel)"
    case .waiting(let reason):
      return "Auto Export waiting: \(reason.userFacingLabel)"
    case .running(let reason):
      return "Auto Export running, \(reason.userFacingLabel)"
    case .scheduled(let reason, _):
      return "Auto Export scheduled, \(reason.userFacingLabel)"
    case .disabled:
      return "Auto Export is off"
    case .idle:
      return "Auto Export idle"
    }
  }
}

// Per-view label extensions removed — surface uses
// `AutoSyncReason.userFacingLabel` / `AutoSyncBlockedReason.userFacingLabel`
// directly. See `AutoSyncReason.swift`.
