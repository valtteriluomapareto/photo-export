import CoreGraphics
import Testing

@testable import Photo_Export

/// The library window's minimum is the sum of its columns' minimums and must fit the smallest
/// display it runs on: 1024×768 (small Macs and CI's hosted runners, where a larger minimum left
/// the window unshown).
struct LibraryWindowSizeTests {
  @Test func minimumWidthIsTheSumOfTheColumnMinimums() {
    #expect(
      LibraryRootView.minimumWindowSize.width
        == LibraryRootView.sidebarMinWidth + LibraryRootView.contentMinWidth
        + LibraryRootView.detailMinWidth)
  }

  @Test func minimumFitsTheSmallestSupportedDisplay() {
    let display = CGSize(width: 1024, height: 768)
    let menuBarAndTitleBar: CGFloat = 60
    #expect(LibraryRootView.minimumWindowSize.width <= display.width)
    #expect(LibraryRootView.minimumWindowSize.height <= display.height - menuBarAndTitleBar)
  }
}
