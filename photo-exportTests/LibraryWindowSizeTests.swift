import AppKit
import SwiftUI
import Testing

@testable import Photo_Export

/// The library window must fit the smallest display the app runs on: 1024×768, on small Macs and
/// CI's hosted runners, where a larger minimum left the window unshown.
///
/// This measures the minimum that the hosted `LibraryRootView` imposes on an AppKit window through
/// its layout. It does not run the app's scene, whose `.windowResizability(.contentMinSize)` turns
/// the same content minimum into the window's minimum.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct LibraryWindowSizeTests {
  /// The menu bar of a display without a notch, as at 1024×768. The bound leaves nothing for the
  /// Dock: it can be hidden or at the side and windows may overlap it, so only a window taller
  /// than the screen below the menu bar fails to fit.
  private static let menuBarHeight: CGFloat = 25
  private static let smallestDisplay = CGSize(width: 1024, height: 768)

  @Test func smallestWindowFitsTheSmallestSupportedDisplay() async throws {
    let root = TestScratch.directory("LibraryWindowSize")
    let suite = TestScratch.suiteName("LibraryWindowSize")
    let defaults = TestScratch.defaults(suiteName: suite)
    defaults.set(true, forKey: "hasCompletedOnboarding")
    let destination = ExportDestinationManager(
      skipRestore: true, userDefaults: defaults,
      sameFolderEvidenceProvider: { _ in .differentFromStored },
      bookmarkSaver: { _ in true }, volumeNotificationCenter: NotificationCenter(),
      validationScopeAcquirer: { _ in true }, validationScopeReleaser: { _ in })
    let service = FakePhotoLibraryService()
    service.yearCounts = [(2026, 2)]
    let library = PhotoLibraryManager(overrideService: service)
    let timeline = ExportRecordStore(baseDirectoryURL: root.appendingPathComponent("Records"))
    let collections = CollectionExportRecordStore(
      baseDirectoryURL: root.appendingPathComponent("Records"))
    timeline.configure(for: "A")
    collections.configure(for: "A")
    let fakeDestination = FakeExportDestination()
    let manager = ExportManager(
      photoLibraryService: service, exportDestination: fakeDestination,
      exportRecordStore: timeline, collectionExportRecordStore: collections,
      assetResourceWriter: FakeAssetResourceWriter(), fileSystem: FakeFileSystem(),
      userDefaults: defaults)
    let autoSync = AutoSyncManager()
    let whatsNew = WhatsNewState(userDefaults: defaults, currentVersion: "test", catalog: [])
    whatsNew.markAsSeen()

    // Styled like the app's library window, whose toolbar the hosted view installs.
    let window = NSWindow(
      contentRect: NSRect(x: -10000, y: -10000, width: 1280, height: 800),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.toolbarStyle = .unified
    window.contentView = NSHostingView(
      rootView: LibraryRootView(screenshotSurfaceKey: nil)
        .environmentObject(library).environmentObject(timeline).environmentObject(collections)
        .environmentObject(manager).environmentObject(manager.progressState)
        .environmentObject(destination).environmentObject(autoSync).environmentObject(whatsNew)
        .defaultAppStorage(defaults))
    try await withCleanup {
      window.orderFront(nil)
      window.layoutIfNeeded()
      try #require(window.toolbar != nil, "The measured frame must include the toolbar")
      // Layout grows the window back to the smallest frame its content allows. The requested
      // size stays taller than the title bar and toolbar: below that, SwiftUI lays out against a
      // negative safe area and the window settles shorter than its content needs.
      window.setContentSize(NSSize(width: 200, height: 200))
      window.layoutIfNeeded()
      let smallest = window.frame.size
      try #require(
        smallest.width > 200 && smallest.height > 200,
        "The window did not grow to its content's minimum: \(smallest)")
      #expect(smallest.width <= Self.smallestDisplay.width, "Smallest frame: \(smallest)")
      #expect(
        smallest.height <= Self.smallestDisplay.height - Self.menuBarHeight,
        "Smallest frame: \(smallest)")
    } cleanup: {
      window.orderOut(nil)
      window.contentView = nil
      window.close()
      manager.cancelAndClear()
      try? await timeline.flush()
      try? await collections.flush()
      fakeDestination.cleanup()
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
  }
}
