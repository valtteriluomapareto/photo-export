import AppKit

/// Reads the host's real accessibility objects, including SwiftUI's virtual nodes.
@MainActor
enum NativeViewAccess {
  static func elements(in window: NSWindow) -> [AnyObject] {
    var seen: Set<ObjectIdentifier> = []
    var result: [AnyObject] = []
    func visit(_ object: AnyObject) {
      guard seen.insert(ObjectIdentifier(object)).inserted else { return }
      result.append(object)
      // Imported public Objective-C methods work for virtual nodes that do not
      // declare nominal conformance to the full NSAccessibilityProtocol.
      if let children = object.accessibilityChildren?() {
        for child in children { visit(child as AnyObject) }
      }
      if let view = object as? NSView {
        for child in view.subviews { visit(child) }
      }
    }
    visit(window)
    if let content = window.contentView { visit(content) }
    for item in window.toolbar?.items ?? [] {
      if let view = item.view { visit(view) }
    }
    return result
  }

  static func containsText(_ text: String, in window: NSWindow) -> Bool {
    elements(in: window).contains { element in
      if element.accessibilityLabel?() == text || element.accessibilityTitle?() == text {
        return true
      }
      guard element.accessibilityRole?() == .staticText else { return false }
      let value: (() -> String?)? = element.accessibilityValue
      return value?() == text
    }
  }

  static func button(_ title: String, in window: NSWindow) -> AnyObject? {
    elements(in: window).first {
      $0.accessibilityRole?() == .button
        && ($0.accessibilityTitle?() == title || $0.accessibilityLabel?() == title)
    }
  }
}
