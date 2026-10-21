import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Photo_Export

/// The app's object graph and startup sequence. Every core here is built from a `TestScratch`
/// root and suite with fake Photos, change-source, writer, file-system, clock and login-item
/// services, through `makeCore`, while the app's own preferences domain is watched. The suite
/// is serialized so each domain snapshot sees only its own test. The shipping compositions
/// are only inspected, never built into a core.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1))) struct AppCoreTests {
  private final class FakeLoginItemService: LoginItemService {
    var status: LoginItemController.Status = .notRegistered
    func register() throws {}
    func unregister() throws {}
    func openSystemLoginItems() {}
  }

  private func makeTestComposition(label: String) -> AppComposition {
    AppComposition(
      defaults: TestScratch.defaults(label),
      appStateRoot: TestScratch.directory(label),
      photoLibraryServiceOverride: FakePhotoLibraryService(),
      persistentChangeSource: FakePersistentChangeSource(),
      assetResourceWriter: FakeAssetResourceWriter(),
      phAssetCacheControl: { $0 },
      fileSystem: FakeFileSystem(),
      clock: TestClock(),
      loginItemService: FakeLoginItemService(),
      wiresAutoSync: false,
      isScreenshotMode: false,
      screenshotWindowSize: nil,
      screenshotSurfaceKey: nil)
  }

  /// The one place these tests build a core. Call it inside `withAppDomainUntouched`.
  private func makeCore(_ composition: AppComposition) -> AppCore {
    AppCore(composition: composition)
  }

  private func makeDestinationFolder(_ label: String) throws -> URL {
    let folder = TestScratch.directory(label)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  /// Runs `body`, then requires the app's own preferences domain to be unchanged. A leaked
  /// write is undone so it can't outlive the failing run.
  private func withAppDomainUntouched(_ body: () async throws -> Void) async throws {
    let domain = try #require(Bundle.main.bundleIdentifier)
    // test-scratch: allow snapshots the app's own domain to prove the core never writes it
    let standard = UserDefaults.standard
    let before = standard.persistentDomain(forName: domain)
    defer {
      let after = standard.persistentDomain(forName: domain)
      let unchanged =
        (before == nil && after == nil)
        || (before.map { NSDictionary(dictionary: $0) }
          == after.map { NSDictionary(dictionary: $0) })
      #expect(unchanged, "the core wrote to the app's own preferences domain")
      if !unchanged {
        if let before {
          standard.setPersistentDomain(before, forName: domain)
        } else {
          standard.removePersistentDomain(forName: domain)
        }
      }
    }
    try await body()
  }

  // MARK: - Startup

  @Test func startAttachesEachServiceOnceInLaunchOrder() async throws {
    try await withAppDomainUntouched {
      let source = FakePersistentChangeSource()
      var composition = makeTestComposition(label: "app-core-start")
      composition.persistentChangeSource = source
      composition.wiresAutoSync = true
      let core = makeCore(composition)
      let destination = core.exportDestinationManager
      destination.persistSelectedFolderForTesting(try makeDestinationFolder("app-core-first"))
      let firstId = try #require(destination.destinationId)

      struct Probe: Equatable {
        let event: String
        let storesConfigured: Bool
        let safetyAttached: Bool
        let launchInProgress: Bool
      }
      var probes: [Probe] = []
      @MainActor func probe(_ event: String) {
        probes.append(
          Probe(
            event: event,
            storesConfigured: core.lifecycleCoordinator.lastConfiguredDestinationId == firstId,
            safetyAttached: core.destinationSafetyMonitor.isAttached,
            launchInProgress: AppDiagnostics.isLaunchInProgress))
      }
      source.onSubscribe = { probe("AutoSync subscribed") }
      source.onStart = { probe("change source started") }
      // The core holds the source through its composition; the probes hold the core.
      defer {
        source.onSubscribe = nil
        source.onStart = nil
      }

      AppDiagnostics.beginLaunch()
      #expect(core.lifecycleCoordinator.lastConfiguredDestinationId == nil)
      #expect(!core.destinationSafetyMonitor.isAttached)

      core.start()

      // The lifecycle coordinator configures the stores before AutoSync attaches; AutoSync
      // subscribes before the change source starts; the safety monitor attaches after both.
      #expect(
        probes == [
          Probe(
            event: "AutoSync subscribed", storesConfigured: true, safetyAttached: false,
            launchInProgress: true),
          Probe(
            event: "change source started", storesConfigured: true, safetyAttached: false,
            launchInProgress: true),
        ])
      #expect(core.destinationSafetyMonitor.isAttached)
      #expect(!AppDiagnostics.isLaunchInProgress)
      #expect(
        FileManager.default.fileExists(
          atPath: composition.recordsRoot.appendingPathComponent(firstId).path))

      // A second window's `.task` starts the core again: nothing re-attaches or re-starts.
      core.start()
      #expect(probes.count == 2)
      #expect(source.startCount == 1)

      // The coordinator stays subscribed: a new destination reaches the record stores.
      destination.persistSelectedFolderForTesting(try makeDestinationFolder("app-core-second"))
      let secondId = try #require(destination.destinationId)
      #expect(secondId != firstId)
      #expect(core.lifecycleCoordinator.lastConfiguredDestinationId == secondId)
      #expect(!PhotoExportApp.wasComposed, "an AppCore alone must not compose the app")
    }
  }

  @Test func withoutAutoSyncTheChangeSourceIsNeverStarted() async throws {
    try await withAppDomainUntouched {
      let source = FakePersistentChangeSource()
      var subscribed = false
      source.onSubscribe = { subscribed = true }
      var composition = makeTestComposition(label: "app-core-no-autosync")
      composition.persistentChangeSource = source
      let core = makeCore(composition)

      core.start()

      #expect(!subscribed)
      #expect(source.startCount == 0)
      #expect(core.destinationSafetyMonitor.isAttached)
    }
  }

  @Test func withoutAnOverrideAutoSyncWatchesThePhotoKitAdapter() async throws {
    try await withAppDomainUntouched {
      var composition = makeTestComposition(label: "app-core-adapter")
      composition.persistentChangeSource = nil
      // Never started: starting the PhotoKit adapter would reach the real library.
      let core = makeCore(composition)

      #expect(core.autoSyncEnvironment.photos === core.autoSyncPhotoChangeAdapter)
    }
  }

  // MARK: - Scene environment

  private final class EnvironmentReading {
    var isScreenshotMode: Bool?
    var surfaceKey: String?
    var storedValue: String?
  }

  private struct EnvironmentProbe: View {
    static let storageKey = "AppCoreTests.environmentProbe"
    let reading: EnvironmentReading
    @Environment(\.isScreenshotMode) private var isScreenshotMode
    @Environment(\.screenshotSurfaceKey) private var surfaceKey
    @AppStorage(Self.storageKey) private var storedValue = "default"

    var body: some View {
      // swiftlint:disable:next redundant_discardable_let
      let _ = record()
      Color.clear
    }

    private func record() {
      reading.isScreenshotMode = isScreenshotMode
      reading.surfaceKey = surfaceKey
      reading.storedValue = storedValue
    }
  }

  @Test func sceneEnvironmentComesFromTheComposition() async throws {
    try await withAppDomainUntouched {
      var composition = makeTestComposition(label: "app-core-environment")
      composition.isScreenshotMode = true
      composition.screenshotSurfaceKey = "collections-favorites"
      composition.defaults.set("from the suite", forKey: EnvironmentProbe.storageKey)
      let core = makeCore(composition)
      let reading = EnvironmentReading()

      let window = NSWindow(
        contentRect: NSRect(x: -10000, y: -10000, width: 200, height: 200),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(
        rootView: EnvironmentProbe(reading: reading).photoExportEnvironment(core))
      window.orderFront(nil)
      defer { window.close() }

      #expect(await eventually("probe rendered") { reading.isScreenshotMode != nil })
      #expect(reading.isScreenshotMode == true)
      #expect(reading.surfaceKey == "collections-favorites")
      #expect(reading.storedValue == "from the suite")
    }
  }

  // MARK: - Compositions

  @Test func productionUsesTheStandardDefaultsAndTheDefaultRoots() throws {
    // test-scratch: allow inspects the shipping composition's values without building a core
    let production = AppComposition.production()
    // test-scratch: allow compares the production composition with the app's own domain
    #expect(production.defaults === UserDefaults.standard)

    let appSupport = try FileManager.default.url(
      // test-scratch: allow computes the shipping root without creating anything
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
      create: false)
    let root = appSupport.appendingPathComponent(
      "com.valtteriluoma.photo-export", isDirectory: true)
    let autoSync = root.appendingPathComponent("AutoSync", isDirectory: true)
    let destinations = autoSync.appendingPathComponent("destinations", isDirectory: true)
    #expect(production.appStateRoot == root)
    #expect(
      production.recordsRoot == root.appendingPathComponent("ExportRecords", isDirectory: true))
    #expect(production.autoSyncRoot == autoSync)
    #expect(production.autoSyncDestinationsRoot == destinations)
    #expect(
      production.photoChangeTokenFileURL
        == autoSync.appendingPathComponent("photo-library-change-token.data"))
    #expect(
      production.legacyStateDirectories(for: "legacy-id") == [
        root.appendingPathComponent("ExportRecords", isDirectory: true)
          .appendingPathComponent("legacy-id", isDirectory: true),
        destinations.appendingPathComponent("legacy-id", isDirectory: true),
      ])

    #expect(production.photoLibraryServiceOverride == nil)
    #expect(production.persistentChangeSource == nil)
    #expect(production.assetResourceWriter is ProductionAssetResourceWriter)
    #expect(production.fileSystem is FileIOService)
    #expect(production.clock is SystemAutoSyncClock)
    #expect(production.loginItemService is SystemLoginItemService)
    let library = PhotoLibraryManager(overrideService: FakePhotoLibraryService())
    #expect(production.phAssetCacheControl(library) === library)
    #expect(production.wiresAutoSync)
    #expect(!production.isScreenshotMode)
    #expect(production.screenshotWindowSize == nil)
  }

  @Test func screenshotModeKeepsProductionStorageAndServices() {
    // test-scratch: allow inspects the shipping compositions' values without building a core
    let production = AppComposition.production()
    // test-scratch: allow inspects the shipping compositions' values without building a core
    let screenshot = AppComposition.screenshot(windowSize: nil)
    #expect(screenshot.defaults === production.defaults)
    #expect(screenshot.appStateRoot == production.appStateRoot)
    #expect(screenshot.photoLibraryServiceOverride is ScreenshotPhotoLibraryService)
    #expect(screenshot.persistentChangeSource == nil)
    #expect(screenshot.assetResourceWriter is ProductionAssetResourceWriter)
    #expect(screenshot.fileSystem is FileIOService)
    #expect(screenshot.clock is SystemAutoSyncClock)
    #expect(screenshot.loginItemService is SystemLoginItemService)
    let library = PhotoLibraryManager(overrideService: FakePhotoLibraryService())
    #expect(screenshot.phAssetCacheControl(library) === library)
    #expect(!screenshot.wiresAutoSync)
    #expect(screenshot.isScreenshotMode)
  }

  @Test func launchArgumentsSelectTheComposition() {
    // test-scratch: allow inspects the shipping compositions' values without building a core
    let plain = AppComposition.forLaunch(arguments: ["Photo Export"])
    #expect(!plain.isScreenshotMode && plain.wiresAutoSync)
    // test-scratch: allow inspects the shipping compositions' values without building a core
    let unsized = AppComposition.forLaunch(arguments: ["Photo Export", "--screenshot-mode"])
    #expect(unsized.isScreenshotMode && !unsized.wiresAutoSync)
    #expect(unsized.screenshotWindowSize == nil)
    // test-scratch: allow inspects the shipping compositions' values without building a core
    let sized = AppComposition.forLaunch(arguments: [
      "Photo Export", "--screenshot-mode", "--screenshot-width=1440", "--screenshot-height=900",
    ])
    #expect(sized.screenshotWindowSize == CGSize(width: 1440, height: 900))
    // test-scratch: allow inspects the shipping compositions' values without building a core
    let widthOnly = AppComposition.forLaunch(arguments: [
      "--screenshot-mode", "--screenshot-width=1440",
    ])
    #expect(widthOnly.screenshotWindowSize == nil)
  }

  @Test func screenshotSurfaceIsReadFromTheLaunchArgumentsInEveryMode() {
    // test-scratch: allow inspects the shipping compositions' values without building a core
    let plain = AppComposition.forLaunch(arguments: ["Photo Export"])
    #expect(plain.screenshotSurfaceKey == nil)
    // The surface has always been honoured without `--screenshot-mode` too.
    // test-scratch: allow inspects the shipping compositions' values without building a core
    let surfaceOnly = AppComposition.forLaunch(arguments: [
      "Photo Export", "--screenshot-surface=collections-favorites",
    ])
    #expect(surfaceOnly.screenshotSurfaceKey == "collections-favorites")
    #expect(!surfaceOnly.isScreenshotMode)
    // test-scratch: allow inspects the shipping compositions' values without building a core
    let screenshot = AppComposition.forLaunch(arguments: [
      "Photo Export", "--screenshot-mode", "--screenshot-surface=timeline-multi-select",
      "--screenshot-width=1440", "--screenshot-height=900",
    ])
    #expect(screenshot.screenshotSurfaceKey == "timeline-multi-select")
  }

  @Test func autoExportMissingAccessFooterNamesThePhotosPrivacyPath() async throws {
    try await withAppDomainUntouched {
      var composition = makeTestComposition(label: "photos-access-footer")
      let service = FakePhotoLibraryService()
      service.authorizationStatus = .denied
      service.isAuthorized = false
      composition.photoLibraryServiceOverride = service
      composition.wiresAutoSync = true
      composition.defaults.set(true, forKey: AutoSyncManager.enabledDefaultsKey)
      let core = makeCore(composition)
      core.start()
      #expect(core.autoSyncManager.state == .blocked(.photosAccessMissing))
      let counter = BodyInvalidationCounter()
      let window = NSWindow(
        contentRect: NSRect(x: -10_000, y: -10_000, width: 600, height: 900),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(
        rootView: AutoExportSettingsView().photoExportEnvironment(core)
          .environment(\.bodyInvalidationCounter, counter))
      defer {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        core.autoSyncManager.setEnabled(false)
        core.autoSyncPhotoChangeAdapter.stop()
        core.exportManager.cancelAndClear()
        counter.reset()
        try? FileManager.default.removeItem(at: composition.appStateRoot)
      }
      window.orderFront(nil)
      try #require(
        await eventually("Auto Export access footer rendered") {
          counter.renderedText["auto-export-now-footer"] != nil
        })
      #expect(
        counter.renderedText["auto-export-now-footer"] == [
          "Turn on Photos access for Photo Export in System Settings → Privacy & Security → Photos."
        ])
      #expect(AutoSyncBlockedReason.photosAccessMissing.userFacingLabel == "Photos access needed")
    }
  }

  // MARK: - Isolation

  @Test func testCompositionKeepsAllStateUnderItsRootAndSuite() async throws {
    try await withAppDomainUntouched {
      var composition = makeTestComposition(label: "app-core-isolation")
      composition.wiresAutoSync = true
      let core = makeCore(composition)
      core.exportDestinationManager.persistSelectedFolderForTesting(
        try makeDestinationFolder("app-core-isolation-destination"))
      core.start()
      core.exportManager.versionSelection = .editedWithOriginals
      core.whatsNewState.markAsSeen()

      #expect(
        composition.defaults.string(forKey: ExportManager.versionSelectionDefaultsKey)
          == ExportVersionSelection.editedWithOriginals.rawValue)
      #expect(composition.defaults.string(forKey: WhatsNewState.lastSeenVersionKey) != nil)
      #expect(composition.defaults.data(forKey: "ExportDestinationBookmark") != nil)

      #expect(core.exportRecordStore.storeRootURL == composition.recordsRoot)
      #expect(core.collectionExportRecordStore.storeRootURL == composition.recordsRoot)
      for url in [
        composition.recordsRoot, composition.autoSyncRoot,
        composition.autoSyncDestinationsRoot, composition.photoChangeTokenFileURL,
      ] + composition.legacyStateDirectories(for: "legacy-id") {
        #expect(url.path.hasPrefix(composition.appStateRoot.path + "/"))
      }
      #expect(FileManager.default.fileExists(atPath: composition.recordsRoot.path))
      #expect(composition.appStateRoot.path.hasPrefix(TestScratch.root.path + "/"))
    }
  }

  @Test func screenshotModeMarksOnboardingDoneOnlyInItsOwnSuite() async throws {
    try await withAppDomainUntouched {
      var composition = makeTestComposition(label: "app-core-screenshot")
      composition.isScreenshotMode = true
      composition.wiresAutoSync = false
      let splitViewKey = "NSSplitView Subview Frames main"
      composition.defaults.set(["0, 0, 240, 800"], forKey: splitViewKey)

      let core = makeCore(composition)

      #expect(composition.defaults.bool(forKey: "hasCompletedOnboarding"))
      #expect(composition.defaults.object(forKey: splitViewKey) == nil)
      #expect(core.exportDestinationManager.selectedFolderURL?.lastPathComponent == "Backup Folder")
    }
  }

  @Test func legacyStateRemovalDeletesOnlyThatIdsDirectories() throws {
    let composition = makeTestComposition(label: "app-core-legacy")
    let fm = FileManager.default
    let legacy = composition.legacyStateDirectories(for: "legacy-id")
    let kept = composition.legacyStateDirectories(for: "current-id")
    for url in legacy + kept {
      try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    composition.removeLegacyState(for: "legacy-id")

    for url in legacy { #expect(!fm.fileExists(atPath: url.path)) }
    for url in kept { #expect(fm.fileExists(atPath: url.path)) }
  }
}
