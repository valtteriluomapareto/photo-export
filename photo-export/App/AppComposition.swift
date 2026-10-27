import Foundation

/// What the app's object graph is built from: the preferences suite, the folder app state
/// lives under, and the services that reach Photos, the file system, the clock and login
/// items. `AppCore` takes all of these from here, so nothing it builds names
/// `UserDefaults.standard`, a system folder or the launch arguments itself.
@MainActor
struct AppComposition {
  /// Preferences for every manager and store, and each scene's default `@AppStorage` suite.
  var defaults: UserDefaults
  /// `<Application Support>/<bundle id>/` in the shipping app. The record stores, AutoSync's
  /// stores, the current-run journal, destination-safety confirmations and the photo-change
  /// token all live under it.
  var appStateRoot: URL
  /// Replaces PhotoKit behind `PhotoLibraryManager` when set; `nil` uses PhotoKit.
  var photoLibraryServiceOverride: (any PhotoLibraryService)?
  /// What AutoSync observes for persistent Photos changes, and starts at launch. `nil` uses
  /// the PhotoKit-backed `PhotoLibraryPersistentChangeAdapter`.
  var persistentChangeSource: (any StartablePhotoLibraryChangeProviding)?
  var assetResourceWriter: any AssetResourceWriter
  /// Export-only metadata reader; UI queries remain on the library service.
  var photoKitReader: any PhotoKitReading
  /// What `ExportManager` calls to drop cached PHAssets during bulk exports, given the
  /// library manager the core built.
  var phAssetCacheControl: @MainActor (PhotoLibraryManager) -> any PHAssetCacheControlling
  var fileSystem: any FileSystemService
  /// Shared by the photo-change adapter and AutoSync.
  var clock: any AutoSyncClock
  var loginItemService: any LoginItemService
  /// Whether `AppCore.start()` attaches AutoSync and starts the persistent change source.
  var wiresAutoSync: Bool
  /// `--screenshot-mode`: no bookmark restore, a placeholder folder name, onboarding marked
  /// complete, saved split-view widths cleared, no What's New sheet, and the window sized
  /// for capture.
  var isScreenshotMode: Bool
  /// `--screenshot-width=` / `--screenshot-height=`: the main window's size in screenshot
  /// mode. `nil` leaves the size to the system.
  var screenshotWindowSize: CGSize?
  /// `--screenshot-surface=<key>`: where the library window first lands, resolved by
  /// `ScreenshotSurfaceResolver` when the view is built. Read in every mode, as it always
  /// has been; `nil` lands on the default Timeline month.
  var screenshotSurfaceKey: String?

  var localHEICStorage: LocalHEICStorage?

  /// The shipping app.
  static func production() -> AppComposition {
    AppComposition(
      defaults: .standard,
      appStateRoot: defaultAppStateRoot(),
      photoLibraryServiceOverride: nil,
      persistentChangeSource: nil,
      assetResourceWriter: ProductionAssetResourceWriter(),
      photoKitReader: ProductionPhotoKitReader(),
      phAssetCacheControl: { $0 },
      fileSystem: FileIOService(),
      clock: SystemAutoSyncClock(),
      loginItemService: SystemLoginItemService(),
      wiresAutoSync: true,
      isScreenshotMode: false,
      screenshotWindowSize: nil,
      screenshotSurfaceKey: nil, localHEICStorage: .production())
  }

  /// `--screenshot-mode`: the shipping app with a curated synthetic library, so marketing
  /// captures don't show the maintainer's photos, and without AutoSync, whose change adapter
  /// would raise the Photos permission prompt.
  static func screenshot(windowSize: CGSize?) -> AppComposition {
    var composition = production()
    let service = ScreenshotPhotoLibraryService()
    composition.photoLibraryServiceOverride = service
    composition.photoKitReader = ScreenshotPhotoKitReader(service: service)
    composition.wiresAutoSync = false
    composition.isScreenshotMode = true
    composition.screenshotWindowSize = windowSize
    return composition
  }

  /// The composition a launch with `arguments` runs.
  static func forLaunch(arguments: [String]) -> AppComposition {
    var composition = launchComposition(arguments: arguments)
    composition.screenshotSurfaceKey = ScreenshotSurfaceResolver.surfaceKey(from: arguments)
    return composition
  }

  private static func launchComposition(arguments: [String]) -> AppComposition {
    guard arguments.contains("--screenshot-mode") else { return production() }
    func value(for prefix: String) -> CGFloat? {
      guard
        let arg = arguments.first(where: { $0.hasPrefix(prefix) }),
        let raw = arg.split(separator: "=").last.map(String.init),
        let n = Double(raw)
      else { return nil }
      return CGFloat(n)
    }
    guard
      let width = value(for: "--screenshot-width="),
      let height = value(for: "--screenshot-height=")
    else { return screenshot(windowSize: nil) }
    return screenshot(windowSize: CGSize(width: width, height: height))
  }

  /// `<Application Support>/<bundle id>/`. Not created here: the record stores create the
  /// path to `recordsRoot` when they are built, and the AutoSync stores their own folders.
  static func defaultAppStateRoot() -> URL {
    let appSupport = try! FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: false
    )
    let bundleId = Bundle.main.bundleIdentifier ?? "com.valtteriluoma.photo-export"
    return appSupport.appendingPathComponent(bundleId, isDirectory: true)
  }

  /// Parent of both record stores' per-destination folders.
  var recordsRoot: URL {
    appStateRoot.appendingPathComponent(
      ExportRecordStore.Constants.directoryName, isDirectory: true)
  }

  /// Root of AutoSync persistence. The stores create their folders lazily.
  var autoSyncRoot: URL {
    appStateRoot.appendingPathComponent("AutoSync", isDirectory: true)
  }

  /// Parent of the per-destination AutoSync stores, the current-run journal and the
  /// destination-safety confirmations.
  var autoSyncDestinationsRoot: URL {
    autoSyncRoot.appendingPathComponent("destinations", isDirectory: true)
  }

  var photoChangeTokenFileURL: URL {
    autoSyncRoot.appendingPathComponent("photo-library-change-token.data")
  }

  /// The app-internal folders a legacy destination id owns. Files on the destination
  /// drive are never among them.
  func legacyStateDirectories(for legacyId: String) -> [URL] {
    [
      recordsRoot.appendingPathComponent(legacyId, isDirectory: true),
      autoSyncDestinationsRoot.appendingPathComponent(legacyId, isDirectory: true),
    ]
  }

  func removeLegacyState(for legacyId: String) {
    for url in legacyStateDirectories(for: legacyId) {
      try? FileManager.default.removeItem(at: url)
    }
  }
}
