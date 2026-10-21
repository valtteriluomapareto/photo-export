import SwiftUI

/// Auto Export status and actions in the menu bar, accessible while the main window
/// is closed. SwiftUI `MenuBarExtra` supplies native menu rendering, keyboard
/// navigation and hit testing. Quitting the app stops Auto Export.
/// See docs/reference/auto-export-behavior.md#run-ownership-and-presentation.
struct AutoSyncMenuBarContent: View {
  @EnvironmentObject private var autoSyncManager: AutoSyncManager
  @EnvironmentObject private var exportDestinationManager: ExportDestinationManager

  @Environment(\.openSettings) private var openSettings

  var body: some View {
    // Read-only status line at the top so the user can see what's happening
    // at a glance before deciding to act.
    Text(autoSyncManager.state.menuBarStatusLabel)

    Divider()

    // Enable/Disable toggle. SwiftUI renders Toggle inside a Menu as a
    // checkmark item.
    Toggle(
      "Enable Auto Export",
      isOn: Binding(
        get: { autoSyncManager.isEnabled },
        set: { autoSyncManager.setEnabled($0) }
      )
    )

    Button("Export Now") {
      autoSyncManager.runNow()
    }
    .disabled(!canRunNow)
    .keyboardShortcut("e", modifiers: [.command, .shift])

    Divider()

    Button("Open Settings\u{2026}") {
      openSettings()
    }
    .keyboardShortcut(",", modifiers: [.command])

    Divider()

    Button("Quit Photo Export") {
      NSApplication.shared.terminate(nil)
    }
    .keyboardShortcut("q", modifiers: [.command])
  }

  /// Menu bar is the click-and-forget surface. Disable Export Now whenever
  /// the click won't result in a visible run within a few seconds — the
  /// user has no inline feedback from a menu item that silently queued for
  /// later. Settings has informative footer copy and can permit Export Now
  /// in transient `.waiting` states; the menu bar can't, so we restrict.
  private var canRunNow: Bool {
    switch autoSyncManager.state {
    case .idle, .scheduled: return true
    case .disabled, .blocked, .running, .waiting: return false
    }
  }
}

/// Icon + (optionally) tinted overlay for the menu bar. Visible in both light
/// and dark menu bar appearances via SF Symbols' adaptive rendering.
struct AutoSyncMenuBarLabel: View {
  let state: AutoSyncState

  var body: some View {
    Image(systemName: iconName)
      .accessibilityLabel(state.menuBarStatusLabel)
      .help(state.menuBarStatusLabel)
  }

  private var iconName: String {
    // Avoid the spinning-arrows family for `.disabled` — it reads as
    // "currently syncing" in the menu bar, which is the opposite of off.
    // Match the toolbar pill's `circle.slash` for consistency.
    switch state {
    case .disabled: return "circle.slash"
    case .idle: return "checkmark.icloud"
    case .scheduled: return "clock.arrow.2.circlepath"
    case .running: return "arrow.triangle.2.circlepath.icloud"
    case .waiting: return "pause.circle"
    case .blocked: return "exclamationmark.icloud"
    }
  }
}

// Share wording between the menu status text and its icon-only menu bar item.
private extension AutoSyncState {
  var menuBarStatusLabel: String {
    switch self {
    case .disabled: return "Auto Export is off"
    case .idle: return "Auto Export: up to date"
    case .scheduled(let reason, _): return "Auto Export: scheduled (\(reason.userFacingLabel))"
    case .running: return "Auto Export: running\u{2026}"
    case .waiting(let reason): return "Auto Export: waiting (\(reason.userFacingLabel))"
    case .blocked(let reason): return "Auto Export: blocked (\(reason.userFacingLabel))"
    }
  }
}
