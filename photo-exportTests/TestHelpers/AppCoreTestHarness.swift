import AppKit
import Foundation
import SwiftUI

@testable import Photo_Export

/// Scratch-only app composition shared by scene and Settings hosts.
@MainActor
enum AppCoreTestHarness {
  private final class FakeLoginItemService: LoginItemService {
    var status: LoginItemController.Status = .notRegistered
    func register() throws {}
    func unregister() throws {}
    func openSystemLoginItems() {}
  }

  static func makeTestComposition(label: String) -> AppComposition {
    AppComposition(
      defaults: TestScratch.defaults(label),
      appStateRoot: TestScratch.directory(label),
      photoLibraryServiceOverride: FakePhotoLibraryService(),
      persistentChangeSource: FakePersistentChangeSource(),
      assetResourceWriter: FakeAssetResourceWriter(),
      photoKitReader: FakePhotoKitReader(),
      phAssetCacheControl: { $0 },
      fileSystem: FakeFileSystem(),
      clock: TestClock(),
      loginItemService: FakeLoginItemService(),
      wiresAutoSync: false,
      isScreenshotMode: false,
      screenshotWindowSize: nil,
      screenshotSurfaceKey: nil,
      localHEICStorage: LocalHEICStorage(root: TestScratch.directory(label + "HEIC")))
  }

  /// The one place these tests build a core. Uses only the supplied scratch composition.
  static func makeCore(_ composition: AppComposition) -> AppCore {
    AppCore(composition: composition)
  }

  #if DEBUG
    static func settingsWindow(
      core: AppCore, counter: BodyInvalidationCounter,
      lifecycle: AppLifecycleCoordinator? = nil, safety: DestinationSafetyMonitor? = nil
    ) -> NSWindow {
      let window = HostedViewHarness.makeWindow(
        contentRect: NSRect(x: -10_000, y: -10_000, width: 600, height: 900),
        styleMask: [.titled, .closable])
      window.contentView = NSHostingView(
        rootView: AutoExportSettingsView()
          .environmentObject(lifecycle ?? core.lifecycleCoordinator)
          .environmentObject(safety ?? core.destinationSafetyMonitor)
          .photoExportEnvironment(core)
          .environment(\.bodyInvalidationCounter, counter))
      return window
    }
  #endif
}
