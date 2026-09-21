import AppKit
import Foundation

/// Closes the Settings window when the user presses ESC — the equivalent of
/// clicking its close button. SwiftUI's `onExitCommand` doesn't fire
/// reliably inside the settings TabView's grouped Forms, so this installs a
/// local `NSEvent` monitor instead. The interception is scoped tightly:
/// only the Escape key, only the SwiftUI Settings window (matched by the
/// framework's window identifier, or by the tab-title window titles it
/// takes), and never while a sheet is attached to it — the "Remove deleted
/// files" confirmation keeps its own ESC-cancel behavior.
enum EscapeToCloseSettingsMonitor {
  static func install() {
    _ = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      guard event.keyCode == 53,  // Escape
        let keyWindow = NSApp.keyWindow,
        keyWindow.attachedSheet == nil,
        isSettingsWindow(keyWindow)
      else { return event }
      keyWindow.performClose(nil)
      return nil  // consumed
    }
  }

  private static func isSettingsWindow(_ window: NSWindow) -> Bool {
    if window.identifier?.rawValue.hasPrefix("com_apple_SwiftUI_Settings_window") == true {
      return true
    }
    // SwiftUI's Settings scene titles the window after the selected tab.
    return ["Auto Export", "Export Issues", "Advanced"].contains(window.title)
  }
}
