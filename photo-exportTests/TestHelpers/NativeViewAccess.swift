import AppKit

/// Reads the host's real accessibility objects, including SwiftUI's virtual nodes.
@MainActor
enum NativeViewAccess {
  static func elements(in root: AnyObject) -> [AnyObject] {
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
      if let contents = object.accessibilityContents?() {
        for child in contents { visit(child as AnyObject) }
      }
      if let children = object.accessibilityVisibleChildren?() {
        for child in children { visit(child as AnyObject) }
      }
      if let scroll = object as? NSScrollView, let document = scroll.documentView {
        visit(document)
      }
      if let clip = object as? NSClipView, let document = clip.documentView { visit(document) }
      if let collection = object as? NSCollectionView {
        for item in collection.visibleItems() { visit(item.view) }
      }
      if let view = object as? NSView {
        for child in view.subviews { visit(child) }
      }
    }
    visit(root)
    if let window = root as? NSWindow {
      if let content = window.contentView { visit(content) }
      for item in window.toolbar?.items ?? [] {
        if let view = item.view { visit(view) }
      }
    }
    return result
  }

  static func texts(in root: AnyObject) -> [String] {
    elements(in: root).flatMap { element -> [String] in
      var result = [element.accessibilityLabel?(), element.accessibilityTitle?()].compactMap { $0 }
      if element.accessibilityRole?() == .staticText {
        let value: (() -> String?)? = element.accessibilityValue
        if let text = value?() { result.append(text) }
      }
      return result
    }
  }

  static func containsText(_ text: String, in root: AnyObject) -> Bool {
    texts(in: root).contains(text)
  }

  static func selectedTab(_ title: String, in window: NSWindow) -> Bool {
    let candidates = elements(in: window)
    let selectedRadio = candidates.contains { element in
      guard element.accessibilityRole?() == .radioButton,
        element.accessibilityTitle?() == title || element.accessibilityLabel?() == title
      else { return false }
      let value: (() -> NSNumber?)? = element.accessibilityValue
      return value?()?.boolValue == true
    }
    return selectedRadio
      || candidates.contains {
        ($0 as? NSTabView)?.selectedTabViewItem?.label == title
      }
  }

  static func tabDescriptions(in window: NSWindow) -> String {
    elements(in: window).compactMap { $0 as? NSTabView }.map {
      "selected=\($0.selectedTabViewItem?.label ?? "none"); items=\($0.tabViewItems.map(\.label))"
    }.joined(separator: " | ")
  }

  static func element(_ identifier: String, in window: NSWindow) -> AnyObject? {
    identifiedElements(identifier, in: window).first
  }

  static func identifiedElements(_ identifier: String, in window: NSWindow) -> [AnyObject] {
    elements(in: window).filter {
      guard let actual = $0.accessibilityIdentifier?() else { return false }
      // SwiftUI combines a DisclosureGroup's repeated child identifier on its heading.
      return actual == identifier || actual.hasPrefix(identifier + "-" + identifier)
    }
  }

  static func texts(identifiedBy identifier: String, in window: NSWindow) -> [String] {
    identifiedElements(identifier, in: window).flatMap { texts(in: $0) }
  }

  static func button(_ title: String, in window: NSWindow) -> AnyObject? {
    elements(in: window).first {
      $0.accessibilityRole?() == .button
        && ($0.accessibilityTitle?() == title || $0.accessibilityLabel?() == title)
    }
  }
}
