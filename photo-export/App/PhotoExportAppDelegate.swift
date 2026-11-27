import AppKit

/// AppKit events for `MenuBarModeController` and the quit rules: window changes and
/// termination. Created by `PhotoExportApp`'s delegate adaptor only (hosted tests run
/// `TestHostApp`).
@MainActor
final class PhotoExportAppDelegate: NSObject, NSApplicationDelegate {
  /// Set by `PhotoExportApp.init`, before AppKit starts launching. Static because `App.init`
  /// runs before SwiftUI hands out the adaptor's delegate instance.
  static var menuBarMode: MenuBarModeController?

  func applicationWillFinishLaunching(_ notification: Notification) {
    guard let menuBarMode = Self.menuBarMode else { return }
    menuBarMode.launchWillFinish()
    let center = NotificationCenter.default
    center.addObserver(
      self, selector: #selector(windowsDidChange(_:)),
      name: NSWindow.didBecomeKeyNotification, object: nil)
    center.addObserver(
      self, selector: #selector(windowWillClose(_:)),
      name: NSWindow.willCloseNotification, object: nil)
    // A window can appear without becoming key, and hiding changes every window at once.
    for name in [
      NSWindow.didChangeOcclusionStateNotification, NSApplication.didHideNotification,
      NSApplication.didUnhideNotification,
    ] {
      center.addObserver(
        self, selector: #selector(windowsDidChange(_:)), name: name, object: nil)
    }
  }

  @objc private func windowsDidChange(_ notification: Notification) {
    Self.windowsChanged(closing: nil)
  }

  @objc private func windowWillClose(_ notification: Notification) {
    Self.windowsChanged(closing: notification.object as? NSWindow)
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    Self.menuBarMode?.launchDidFinish()
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let menuBarMode = Self.menuBarMode else { return .terminateNow }
    let core = menuBarMode.core
    let isSystemQuit =
      NSAppleEventManager.shared().currentAppleEvent?
      .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
    return AppCore.terminateReply(
      exportManager: core.exportManager, isSystemQuit: isSystemQuit,
      confirm: {
        menuBarMode.showWindow {}
        let alert = NSAlert()
        alert.messageText = "Stop the export and quit?"
        alert.informativeText =
          "Files already exported stay in your folder. Export again later to finish the rest."
        alert.addButton(withTitle: "Stop and Quit")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        Self.windowsChanged(closing: nil)
        return response == .alertFirstButtonReturn
      },
      stop: { core.stopForQuit { NSApp.reply(toApplicationShouldTerminate: true) } })
  }

  private static func windowsChanged(closing: NSWindow?) {
    let windows = NSApp.windows.map {
      MenuBarMode.WindowState(
        isTitled: $0.styleMask.contains(.titled), isVisible: $0.isVisible,
        isMiniaturized: $0.isMiniaturized, isClosing: $0 === closing)
    }
    menuBarMode?.windowsChanged(windows, appIsHidden: NSApp.isHidden)
  }
}
