import AppKit
import SwiftUI

@testable import Photo_Export

/// Shared owners for hosted library views; scenarios retain their own layout and teardown.
@MainActor
struct HostedViewHarness {
  let library: PhotoLibraryManager
  let export: ExportManagerHarness
  let destination: ExportDestinationManager
  let autoSync: AutoSyncManager
  let whatsNew: WhatsNewState

  func environment<Content: View>(_ root: Content) -> some View {
    root.environmentObject(library).environment(export.store)
      .environmentObject(export.collectionStore).environmentObject(export.manager)
      .environment(export.manager.progressState).environmentObject(destination)
      .environmentObject(autoSync).environment(whatsNew)
  }

  static func makeWindow(
    contentRect: NSRect,
    styleMask: NSWindow.StyleMask,
    toolbarStyle: NSWindow.ToolbarStyle? = nil
  ) -> NSWindow {
    let window = NSWindow(
      contentRect: contentRect, styleMask: styleMask, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    if let toolbarStyle { window.toolbarStyle = toolbarStyle }
    return window
  }
}
