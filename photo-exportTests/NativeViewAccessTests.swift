import AppKit
import Testing

@MainActor
@Suite(.serialized)
struct NativeViewAccessTests {
  @Test func nativeTabSelectionWithoutTabButtonsReadsTheSelectedPage() {
    let tabs = NSTabView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
    tabs.tabViewType = .noTabsNoBorder
    for label in ["First", "Second"] {
      let item = NSTabViewItem(identifier: label)
      item.label = label
      item.view = NSTextField(labelWithString: "\(label) visible page")
      tabs.addTabViewItem(item)
    }
    let window = HostedViewHarness.makeWindow(
      contentRect: NSRect(x: -10000, y: -10000, width: 320, height: 180),
      styleMask: [.borderless])
    window.contentView = tabs
    window.orderFront(nil)
    defer {
      window.orderOut(nil)
      window.contentView = nil
      window.close()
    }
    tabs.selectTabViewItem(at: 0)
    tabs.layoutSubtreeIfNeeded()
    #expect(NativeViewAccess.containsText("First visible page", in: window))
    #expect(NativeViewAccess.selectedTab("First", in: window))
    #expect(!NativeViewAccess.selectedTab("Second", in: window))
    tabs.selectTabViewItem(at: 1)
    tabs.layoutSubtreeIfNeeded()
    #expect(NativeViewAccess.containsText("Second visible page", in: window))
    #expect(!NativeViewAccess.selectedTab("First", in: window))
    #expect(NativeViewAccess.selectedTab("Second", in: window))
  }
}
