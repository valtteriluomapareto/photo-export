import SwiftUI

/// Menu shown when the user clicks the AutoSync menu bar item. Plan §"Phase 4":
/// "Add an `NSStatusItem` (menu bar item) **in MVP** with: Enable/Disable Auto
/// Export, Export Now, current status, Open Issues, Open Settings. Required
/// because launch-at-login starts the app without showing the main window."
///
/// Uses SwiftUI `MenuBarExtra`'s default menu rendering — native, keyboard-
/// navigable, free hit-testing. Custom-window MenuBarExtra (`.window` style)
/// would let us match the Settings tab's layout, but the basic menu is the
/// right MVP surface.
struct AutoSyncMenuBarContent: View {
  @EnvironmentObject private var autoSyncManager: AutoSyncManager
  @EnvironmentObject private var exportDestinationManager: ExportDestinationManager

  @Environment(\.openSettings) private var openSettings

  var body: some View {
    // Read-only status line at the top so the user can see what's happening
    // at a glance before deciding to act.
    Text(statusLabel)

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

  private var statusLabel: String {
    switch autoSyncManager.state {
    case .disabled: return "Auto Export is off"
    case .idle: return "Auto Export: up to date"
    case .scheduled(let reason, _): return "Auto Export: scheduled (\(reason.userFacingLabel))"
    case .running: return "Auto Export: running\u{2026}"
    case .waiting(let reason): return "Auto Export: waiting (\(reason.userFacingLabel))"
    case .blocked(let reason): return "Auto Export: blocked (\(reason.userFacingLabel))"
    }
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

// Per-view label extensions removed — surface uses
// `AutoSyncReason.userFacingLabel` / `AutoSyncBlockedReason.userFacingLabel`
// directly. See `AutoSyncReason.swift`.
