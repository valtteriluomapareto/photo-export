import Foundation
import Testing

@testable import Photo_Export

/// The app's object graph and startup sequence. Hosted cores here use a `TestScratch`
/// root and suite, a fake Photos service and AutoSync left unwired: starting the persistent
/// change adapter would reach PhotoKit, so the AutoSync steps are checked through the
/// startup plan the core runs.
@MainActor
@Suite struct AppCoreTests {
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
      assetResourceWriter: FakeAssetResourceWriter(),
      phAssetCacheControl: { $0 },
      fileSystem: FakeFileSystem(),
      clock: TestClock(),
      loginItemService: FakeLoginItemService(),
      wiresAutoSync: false,
      isScreenshotMode: false)
  }

  // MARK: - Startup order

  @Test func startupPlanKeepsTheLaunchOrder() {
    #expect(
      AppCore.startupSteps(wiresAutoSync: true) == [
        .photoLibrary, .destinationLifecycle, .autoSync, .photoChangeObservation,
        .destinationSafety, .screenshotWindow, .launchFinished,
      ])
    #expect(
      AppCore.startupSteps(wiresAutoSync: false) == [
        .photoLibrary, .destinationLifecycle, .destinationSafety, .screenshotWindow,
        .launchFinished,
      ])
  }

  @Test func startRunsThePlanInOrderOnlyOnce() {
    var trace: [AppCore.StartupStep] = []
    let composition = makeTestComposition(label: "app-core-start")
    let core = AppCore(composition: composition, startupObserver: { trace.append($0) })
    #expect(trace.isEmpty, "building the core must not start it")

    core.start()
    #expect(trace == AppCore.startupSteps(wiresAutoSync: false))

    // A second window's `.task` calls `start()` again.
    core.start()
    #expect(trace == AppCore.startupSteps(wiresAutoSync: false))
    #expect(!PhotoExportApp.wasComposed, "an AppCore alone must not compose the app")
  }

  // MARK: - Compositions

  @Test func productionUsesTheStandardDefaultsAndTheDefaultRoots() throws {
    let production = AppComposition.production
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
    #expect(production.assetResourceWriter is ProductionAssetResourceWriter)
    #expect(production.fileSystem is FileIOService)
    #expect(production.clock is SystemAutoSyncClock)
    #expect(production.loginItemService is SystemLoginItemService)
    #expect(production.wiresAutoSync)
    #expect(!production.isScreenshotMode)
  }

  @Test func screenshotModeDiffersFromProductionOnlyInPhotosAndAutoSync() {
    let production = AppComposition.production
    let screenshot = AppComposition.screenshot
    #expect(screenshot.defaults === production.defaults)
    #expect(screenshot.appStateRoot == production.appStateRoot)
    #expect(screenshot.photoLibraryServiceOverride is ScreenshotPhotoLibraryService)
    #expect(screenshot.assetResourceWriter is ProductionAssetResourceWriter)
    #expect(screenshot.loginItemService is SystemLoginItemService)
    #expect(!screenshot.wiresAutoSync)
    #expect(screenshot.isScreenshotMode)
  }

  // MARK: - Isolation

  @Test func testCompositionKeepsAllStateUnderItsRootAndSuite() throws {
    let keys = [
      "ExportDestinationBookmark", "ExportDestinationStableId", "hasCompletedOnboarding",
      ExportManager.versionSelectionDefaultsKey, UserDefaultsAutoExportScopeStore.defaultsKey,
      AutoSyncManager.enabledDefaultsKey, WhatsNewState.lastSeenVersionKey,
    ]
    // test-scratch: allow reads the app's own domain to prove the core never writes it
    let standard = UserDefaults.standard
    let original = keys.map { standard.object(forKey: $0) }
    let describe = { (values: [Any?]) in values.map { $0.map { "\($0)" } } }
    defer {
      // If the core leaked a write into the app's own domain, put the old values back.
      for (key, value) in zip(keys, original)
      where describe([standard.object(forKey: key)]) != describe([value]) {
        standard.set(value, forKey: key)
      }
    }

    let composition = makeTestComposition(label: "app-core-isolation")
    let core = AppCore(composition: composition)
    core.start()
    core.exportManager.versionSelection = .editedWithOriginals
    core.whatsNewState.markAsSeen()

    #expect(
      composition.defaults.string(forKey: ExportManager.versionSelectionDefaultsKey)
        == ExportVersionSelection.editedWithOriginals.rawValue)
    #expect(composition.defaults.string(forKey: WhatsNewState.lastSeenVersionKey) != nil)
    #expect(describe(keys.map { standard.object(forKey: $0) }) == describe(original))

    #expect(core.exportRecordStore.storeRootURL == composition.recordsRoot)
    #expect(core.collectionExportRecordStore.storeRootURL == composition.recordsRoot)
    for url in [
      composition.recordsRoot, composition.autoSyncRoot, composition.autoSyncDestinationsRoot,
      composition.photoChangeTokenFileURL,
    ] + composition.legacyStateDirectories(for: "legacy-id") {
      #expect(url.path.hasPrefix(composition.appStateRoot.path + "/"))
    }
    #expect(FileManager.default.fileExists(atPath: composition.recordsRoot.path))
    #expect(composition.appStateRoot.path.hasPrefix(TestScratch.root.path + "/"))
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
