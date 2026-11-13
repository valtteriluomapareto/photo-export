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
    root.environment(library).environment(export.store)
      .environment(export.collectionStore).environment(export.manager)
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

  /// The content's center pixel, for tests whose only signal is which solid image is on screen.
  static func centerColor(of window: NSWindow) -> NSColor? {
    guard let view = window.contentView else { return nil }
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    return bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?
      .usingColorSpace(.sRGB)
  }

  /// Whether a sampled color is a solid red or blue fixture. AppKit tone-maps HDR snapshots even
  /// for solid sRGB fixtures, so compare the clearly distinct channels rather than exact RGB.
  static func sample(_ actual: NSColor?, shows color: NSColor) -> Bool {
    guard let actual, let expected = color.usingColorSpace(.sRGB) else { return false }
    return expected.redComponent > expected.blueComponent
      ? actual.redComponent > actual.blueComponent + 0.4
      : actual.blueComponent > actual.redComponent + 0.4
  }
}
