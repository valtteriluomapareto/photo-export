import SwiftUI

extension View {
  /// Pins a first-run window state (authorization + onboarding) to a usable
  /// minimum size.
  ///
  /// The main `WindowGroup` uses `.windowResizability(.contentMinSize)`, so the
  /// window's minimum tracks the root content's minimum. These states center
  /// their content with `Spacer()`s and have no intrinsic minimum, so without
  /// this they collapse to a near-zero minimum — letting a stale small window
  /// frame (which can survive an App Store reinstall via saved window state)
  /// render as an unusable, non-resizable sliver (issue #125). The library
  /// state sets its own, larger minimum in `LibraryRootView`.
  ///
  /// `maxWidth/maxHeight: .infinity` keeps the window freely resizable larger;
  /// the ideal sizes give a comfortable first-run window.
  func firstRunWindowMinSize() -> some View {
    frame(
      minWidth: 600, idealWidth: 720, maxWidth: .infinity,
      minHeight: 640, idealHeight: 760, maxHeight: .infinity)
  }
}
