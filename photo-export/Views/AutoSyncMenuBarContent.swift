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

    Button("Open Auto Export Settings\u{2026}") {
      openSettings()
      // Settings opens on the most recently visible tab. We can't deep-link
      // tabs from here without a custom tab selection state; Settings will
      // remember the last visited tab.
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
    case .scheduled(let reason, _): return "Auto Export: scheduled (\(reason.shortLabel))"
    case .running: return "Auto Export: running\u{2026}"
    case .waiting(let reason): return "Auto Export: waiting (\(reason.shortLabel))"
    case .blocked(let reason): return "Auto Export: blocked (\(reason.shortLabel))"
    }
  }

  private var canRunNow: Bool {
    switch autoSyncManager.state {
    case .disabled, .blocked, .running: return false
    case .idle, .scheduled, .waiting: return true
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
    switch state {
    case .disabled: return "arrow.triangle.2.circlepath"
    case .idle: return "checkmark.icloud"
    case .scheduled: return "clock.arrow.2.circlepath"
    case .running: return "arrow.triangle.2.circlepath.icloud"
    case .waiting: return "pause.circle"
    case .blocked: return "exclamationmark.icloud"
    }
  }
}

extension AutoSyncReason {
  fileprivate var shortLabel: String {
    switch self {
    case .appLaunch: return "launch"
    case .destinationSelected: return "destination"
    case .destinationBecameAvailable: return "reconnected"
    case .scopeSelectionChanged: return "scope"
    case .versionSelectionChanged: return "version"
    case .photosChanged: return "photos"
    case .photosChangeFallback: return "catch-up"
    case .userExportNow: return "Export Now"
    }
  }
}

extension AutoSyncBlockedReason {
  fileprivate var shortLabel: String {
    switch self {
    case .photosAccessMissing: return "Photos access"
    case .limitedPhotosAccess: return "limited access"
    case .destinationMissing: return "no destination"
    case .destinationUnavailable: return "drive disconnected"
    case .destinationUnsafe: return "destination unsafe"
    case .noScopesSelected: return "no scopes"
    case .manualExportActive: return "manual export"
    case .importActive: return "import"
    case .retryBackoff: return "retry backoff"
    }
  }
}
