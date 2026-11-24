#if DEBUG
  import Combine
  import Darwin
  import Foundation
  import Photos

  @MainActor
  struct ControlFixture {
    static let prefix = "photo-export-control-"
    let root: URL
    let run = UUID().uuidString.lowercased()

    var destination: URL { root.appending(path: "Destination", directoryHint: .isDirectory) }
    var stateRoot: URL { root.appending(path: "AppState", directoryHint: .isDirectory) }
    var defaultsDomain: String { root.appending(path: "photo-export.control.\(run)").path }
    var defaultsFile: URL { URL(fileURLWithPath: defaultsDomain + ".plist") }

    static func prepare(
      runDirectory: URL?, temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> Self {
      let manager = FileManager.default
      let temporary = temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
      let root: URL
      if let requested = runDirectory {
        root = requested.resolvingSymlinksInPath().standardizedFileURL
        var metadata = stat()
        guard lstat(requested.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
          metadata.st_uid == getuid(), metadata.st_mode & 0o7777 == 0o700,
          root.deletingLastPathComponent().path == temporary.path,
          root.lastPathComponent.hasPrefix(prefix),
          try manager.contentsOfDirectory(atPath: root.path).allSatisfy({ $0 == "app.log" })
        else {
          throw ControlLaunch.Invalid(
            "Use a fresh private control directory in app temporary storage.")
        }
      } else {
        root = temporary.appending(path: prefix + UUID().uuidString, directoryHint: .isDirectory)
        try manager.createDirectory(
          at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      }
      // An exclusive claim prevents two launches from configuring the same run.
      let claim = root.appending(path: ".control-run")
      try Data().write(to: claim, options: .withoutOverwriting)
      let fixture = Self(root: root)
      for directory in [fixture.destination, fixture.stateRoot] {
        try manager.createDirectory(
          at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      }
      return fixture
    }

    func contains(_ url: URL) -> Bool {
      url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root.path + "/")
    }

    func permitsDestination(_ url: URL) -> Bool {
      contains(url) && url.resolvingSymlinksInPath().standardizedFileURL.path == destination.path
    }

    func validate(_ composition: AppComposition) throws {
      guard composition.photoLibraryServiceOverride is FixturePhotoLibraryService,
        composition.persistentChangeSource is FixtureChangeSource,
        composition.assetResourceWriter is FixtureResourceWriter,
        composition.mediaRenderer is FixtureMediaRenderer,
        composition.appStateRoot == stateRoot,
        [
          stateRoot, destination, composition.recordsRoot, composition.autoSyncRoot,
          composition.autoSyncDestinationsRoot, composition.photoChangeTokenFileURL, defaultsFile,
        ].allSatisfy(contains),
        composition.defaults.persistentDomain(forName: defaultsDomain)?[
          "hasCompletedOnboarding"] as? Bool == true
      else { throw ControlLaunch.Invalid("Control composition failed isolation checks.") }
    }

    func start(_ core: AppCore) async throws {
      try validate(core.composition)
      guard core.autoSyncPhotoChangeAdapter == nil else {
        throw ControlLaunch.Invalid("Control composition requires a fixture change source.")
      }
      let manager = core.exportDestinationManager
      guard manager.applyFolderSelection(destination, decision: .newDestination) else {
        throw ControlLaunch.Invalid("Could not select the fixture destination.")
      }
      await manager.waitForValidation()
      guard manager.canExportNow, manager.destinationId != nil else {
        throw ControlLaunch.Invalid("Fixture destination validation failed.")
      }
      core.start()
      await core.exportRecordStore.waitUntilSettled()
      await core.collectionExportRecordStore.waitUntilSettled()
      guard core.exportRecordStore.state == .ready, core.collectionExportRecordStore.state == .ready
      else { throw ControlLaunch.Invalid("Fixture history failed to load.") }
    }
  }

  extension AppComposition {
    static func fixture(_ fixture: ControlFixture, surface: ControlLaunch.Surface) throws -> Self {
      guard fixture.contains(fixture.defaultsFile),
        let defaults = UserDefaults(suiteName: fixture.defaultsDomain)
      else {
        throw ControlLaunch.Invalid("Could not open the run preferences.")
      }
      let service = try FixturePhotoLibraryService()
      defaults.set(true, forKey: "hasCompletedOnboarding")
      defaults.set(
        ExportVersionSelection.edited.rawValue, forKey: ExportManager.versionSelectionDefaultsKey)
      defaults.set(surface.settingsTab?.rawValue, forKey: SettingsTab.storageKey)
      WhatsNewState(userDefaults: defaults).markAsSeen()
      UserDefaultsAutoExportScopeStore(userDefaults: defaults).setSelection(.init(timeline: true))
      guard defaults.synchronize(),
        FileManager.default.fileExists(atPath: fixture.defaultsFile.path)
      else { throw ControlLaunch.Invalid("Run preferences could not be persisted inside the run.") }

      var composition = Self(
        defaults: defaults, appStateRoot: fixture.stateRoot,
        photoLibraryServiceOverride: service, persistentChangeSource: FixtureChangeSource(),
        assetResourceWriter: FixtureResourceWriter(images: service.images),
        mediaRenderer: FixtureMediaRenderer(),
        photoKitReader: PhotoLibraryServiceReader(service: service),
        phAssetCacheControl: { $0 }, fileSystem: FileIOService(),
        clock: FixtureClock(), loginItemService: FixtureLoginItemService(),
        wiresAutoSync: true, isScreenshotMode: false, screenshotWindowSize: nil,
        screenshotSurfaceKey: surface == .favorites ? "collections-favorites" : nil)
      composition.controlLibrarySurface =
        surface == .favorites
        ? nil : .init(section: .timeline, selection: .timelineMonth(year: 2025, month: 6))
      composition.makeControlDestination = {
        ExportDestinationManager(
          skipRestore: true, userDefaults: defaults,
          sameFolderEvidenceProvider: { _ in .noStoredBookmark },
          bookmarkSaver: { fixture.permitsDestination($0) },
          volumeNotificationCenter: NotificationCenter(),
          validationScopeAcquirer: { fixture.permitsDestination($0) },
          validationScopeReleaser: { _ in }, localAccess: { fixture.permitsDestination($0) })
      }
      try fixture.validate(composition)
      return composition
    }
  }

  @MainActor
  final class FixtureChangeSource: StartablePhotoLibraryChangeProviding {
    let authorizationStatus: PHAuthorizationStatus = .authorized
    let changes = Empty<PhotoLibraryChangeOutcome, Never>(completeImmediately: false)
      .eraseToAnyPublisher()
    func start() {}
  }

  @MainActor
  final class FixtureLoginItemService: LoginItemService {
    private(set) var status: LoginItemController.Status = .notRegistered
    func register() throws { status = .enabled }
    func unregister() throws { status = .notRegistered }
    func openSystemLoginItems() {}
  }

  @MainActor
  final class FixtureClock: AutoSyncClock {
    @MainActor
    private final class Entry: AutoSyncCancellable {
      let time: Date
      var work: (() -> Void)?
      init(time: Date, work: @escaping () -> Void) {
        self.time = time
        self.work = work
      }
      func cancel() { work = nil }
    }

    private var time = Date(timeIntervalSince1970: 1_749_988_800)  // 2025-06-15 12:00 UTC
    private var entries: [Entry] = []
    func now() -> Date { time }

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> AutoSyncCancellable {
      entries.removeAll { $0.work == nil }
      let entry = Entry(time: time.addingTimeInterval(max(0, delay)), work: work)
      // Equal fire times preserve insertion order.
      let index = entries.firstIndex { $0.time > entry.time } ?? entries.endIndex
      entries.insert(entry, at: index)
      return entry
    }

    func advance(by seconds: TimeInterval) {
      let target = time.addingTimeInterval(seconds)
      while let entry = entries.first, entry.time <= target {
        entries.removeFirst()
        time = entry.time
        let work = entry.work
        entry.cancel()
        work?()
      }
      time = target
    }
  }
#endif
