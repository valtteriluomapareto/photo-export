import Foundation

/// What the app's object graph is built from: the preferences suite, the folder app state
/// lives under, and the services that reach Photos, the file system, the clock and login
/// items. `AppCore` takes all of these from here, so nothing it builds names
/// `UserDefaults.standard` or a system folder itself.
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
  var assetResourceWriter: any AssetResourceWriter
  /// What `ExportManager` calls to drop cached PHAssets during bulk exports, given the
  /// library manager the core built.
  var phAssetCacheControl: @MainActor (PhotoLibraryManager) -> any PHAssetCacheControlling
  var fileSystem: any FileSystemService
  /// Shared by the photo-change adapter and AutoSync.
  var clock: any AutoSyncClock
  var loginItemService: any LoginItemService
  /// Whether `AppCore.start()` attaches AutoSync and starts persistent change observation.
  var wiresAutoSync: Bool
  /// `--screenshot-mode`: no bookmark restore, a placeholder folder name, onboarding marked
  /// complete, saved split-view widths cleared, and the window sized for capture.
  var isScreenshotMode: Bool

  /// The shipping app.
  static var production: AppComposition {
    AppComposition(
      defaults: .standard,
      appStateRoot: defaultAppStateRoot(),
      photoLibraryServiceOverride: nil,
      assetResourceWriter: ProductionAssetResourceWriter(),
      phAssetCacheControl: { $0 },
      fileSystem: FileIOService(),
      clock: SystemAutoSyncClock(),
      loginItemService: SystemLoginItemService(),
      wiresAutoSync: true,
      isScreenshotMode: false)
  }

  /// `--screenshot-mode`: the shipping app with a curated synthetic library, so marketing
  /// captures don't show the maintainer's photos, and without AutoSync, whose change adapter
  /// would raise the Photos permission prompt.
  static var screenshot: AppComposition {
    var composition = production
    composition.photoLibraryServiceOverride = ScreenshotPhotoLibraryService()
    composition.wiresAutoSync = false
    composition.isScreenshotMode = true
    return composition
  }

  /// `<Application Support>/<bundle id>/`.
  static func defaultAppStateRoot() -> URL {
    let appSupport = try! FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
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
