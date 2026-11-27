import AppKit
import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Menu-bar mode: the launch decision, the windowless core start, activation-policy
/// switching through the injected seam, freeing the window caches, authorization refresh
/// without activation and quitting. Cores come from scratch compositions with fake services;
/// the policy seam keeps its own current policy and records each change instead of changing
/// the test host's policy.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct MenuBarModeTests {
  @MainActor
  private final class Launch {
    let composition: AppComposition
    let core: AppCore
    let source = FakePersistentChangeSource()
    let photos: FakePhotoLibraryService
    let controller: MenuBarModeController
    /// Every policy the controller set, in order; a new process starts `.regular`.
    private(set) var appliedPolicies: [NSApplication.ActivationPolicy] = []
    private var currentPolicy = NSApplication.ActivationPolicy.regular

    init(
      label: String, runsInMenuBar: Bool, opensWithoutWindow: Bool,
      authorization: PHAuthorizationStatus = .authorized,
      configure: (inout AppComposition) -> Void = { _ in }
    ) throws {
      var composition = AppCoreTestHarness.makeTestComposition(label: label)
      composition.persistentChangeSource = source
      composition.wiresAutoSync = true
      photos = try #require(composition.photoLibraryServiceOverride as? FakePhotoLibraryService)
      photos.authorizationStatus = authorization
      photos.isAuthorized = PhotoLibraryManager.isAuthorizationSufficient(authorization)
      composition.defaults.set(runsInMenuBar, forKey: MenuBarMode.defaultsKey)
      configure(&composition)
      self.composition = composition
      let core = AppCoreTestHarness.makeCore(composition)
      self.core = core
      weak var launch: Launch?
      controller = MenuBarModeController(
        core: core, opensWithoutWindow: opensWithoutWindow,
        activationPolicy: { launch?.currentPolicy ?? .regular },
        setActivationPolicy: {
          launch?.currentPolicy = $0
          launch?.appliedPolicies.append($0)
        })
      launch = self
    }

    var clock: TestClock { composition.clock as! TestClock }

    /// The app's policy changing outside the controller.
    func changePolicyElsewhere() { currentPolicy = .regular }

    func windowsChanged(_ windows: [MenuBarMode.WindowState], appIsHidden: Bool = false) {
      controller.windowsChanged(windows, appIsHidden: appIsHidden)
    }

    func cleanUp() {
      try? FileManager.default.removeItem(at: composition.appStateRoot)
    }
  }

  private static let statusItem = MenuBarMode.WindowState(isTitled: false, isVisible: true)
  private static let mainWindow = MenuBarMode.WindowState(isTitled: true, isVisible: true)

  /// One turn of the main queue: work the controller queued with `DispatchQueue.main.async`
  /// before this call has run when it returns.
  private func drainMainQueue() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
  }

  // MARK: - Launch decision

  @Test func onlyACompletedSetupWithTheSettingOnOpensWithoutAWindow() {
    let defaults = TestScratch.defaults("menu-bar-launch")
    // Off by default: a window opens.
    #expect(!MenuBarMode.opensWithoutWindow(defaults: defaults, isScreenshotMode: false))
    defaults.set(true, forKey: MenuBarMode.defaultsKey)
    // First run still opens a window for onboarding.
    #expect(!MenuBarMode.opensWithoutWindow(defaults: defaults, isScreenshotMode: false))
    defaults.set(true, forKey: ContentView.onboardingCompletedDefaultsKey)
    #expect(MenuBarMode.opensWithoutWindow(defaults: defaults, isScreenshotMode: false))
    #expect(!MenuBarMode.opensWithoutWindow(defaults: defaults, isScreenshotMode: true))
    defaults.set(false, forKey: MenuBarMode.defaultsKey)
    #expect(!MenuBarMode.opensWithoutWindow(defaults: defaults, isScreenshotMode: false))
  }

  @Test func activationPolicyRule() {
    typealias Row = (enabled: Bool, window: Bool, auth: PHAuthorizationStatus?)
    let accessory: [Row] = [
      (true, false, nil), (true, false, .authorized), (true, false, .denied),
      (true, false, .limited),
    ]
    let regular: [Row] = [
      (false, false, .authorized), (false, true, .authorized), (true, true, .authorized),
      (true, false, .notDetermined),
    ]
    for row in accessory {
      #expect(
        MenuBarMode.activationPolicy(
          isEnabled: row.enabled, hasWindow: row.window, authorization: row.auth) == .accessory)
    }
    for row in regular {
      #expect(
        MenuBarMode.activationPolicy(
          isEnabled: row.enabled, hasWindow: row.window, authorization: row.auth) == .regular)
    }
  }

  @Test func userWindowsAreTitledAndShownOrMinimized() {
    typealias Win = MenuBarMode.WindowState
    let statusItem = Self.statusItem
    let main = Self.mainWindow
    #expect(MenuBarMode.hasUserWindow([statusItem, main]))
    #expect(!MenuBarMode.hasUserWindow([statusItem]))
    #expect(!MenuBarMode.hasUserWindow([]))
    // Settings stays open after the main window closed.
    let closing = Win(isTitled: true, isVisible: true, isClosing: true)
    #expect(MenuBarMode.hasUserWindow([closing, main]))
    #expect(!MenuBarMode.hasUserWindow([statusItem, closing]))
    let minimized = Win(isTitled: true, isVisible: false, isMiniaturized: true)
    #expect(MenuBarMode.hasUserWindow([minimized]))
    #expect(!MenuBarMode.hasUserWindow([Win(isTitled: true, isVisible: false)]))
  }

  // MARK: - Startup

  /// A launch with no window starts the core one main-queue turn after launch finishes, in
  /// the same order as a window's start; nothing reads Photos before then. A `.notDetermined`
  /// read after the start shows the Dock icon. (The fake library reads access eagerly, so
  /// this can't show that access read before the start is ignored; that is a smoke row.)
  @Test func windowlessLaunchStartsTheCoreAfterTheFirstRunLoopTurn() async throws {
    let launch = try Launch(
      label: "menu-bar-windowless", runsInMenuBar: true, opensWithoutWindow: true,
      authorization: .notDetermined)
    defer { launch.cleanUp() }
    var subscribed = false
    launch.source.onSubscribe = { subscribed = true }
    defer { launch.source.onSubscribe = nil }
    let reads = launch.photos.authorizationStatusReads

    launch.controller.launchWillFinish()
    #expect(launch.appliedPolicies == [.accessory])
    launch.controller.launchDidFinish()

    #expect(!subscribed)
    #expect(launch.source.startCount == 0)
    #expect(!launch.core.destinationSafetyMonitor.isAttached)
    #expect(launch.photos.authorizationStatusReads == reads)
    #expect(launch.photos.fetchAssetsCalls.isEmpty)
    #expect(launch.photos.thumbnailResolveCalls.isEmpty)
    #expect(launch.appliedPolicies == [.accessory])

    await drainMainQueue()

    #expect(subscribed)
    #expect(launch.source.startCount == 1)
    #expect(launch.core.destinationSafetyMonitor.isAttached)
    #expect(launch.appliedPolicies == [.accessory, .regular])
    // A window opened later starts nothing again.
    launch.core.start()
    #expect(launch.source.startCount == 1)
  }

  /// With the setting off, launch opens a window: the controller starts nothing (the
  /// window's `.task` does) and never changes the activation policy, even after the window
  /// closes.
  @Test func withTheSettingOffAWindowedLaunchKeepsTheDockIcon() async throws {
    var opensWithoutWindow = true
    let launch = try Launch(
      label: "menu-bar-off", runsInMenuBar: false, opensWithoutWindow: false
    ) { composition in
      composition.defaults.set(true, forKey: ContentView.onboardingCompletedDefaultsKey)
      opensWithoutWindow = MenuBarMode.opensWithoutWindow(
        defaults: composition.defaults, isScreenshotMode: false)
    }
    defer { launch.cleanUp() }
    #expect(!opensWithoutWindow)

    launch.controller.launchWillFinish()
    launch.controller.launchDidFinish()
    await drainMainQueue()
    #expect(launch.source.startCount == 0)

    launch.core.start()
    launch.windowsChanged([Self.statusItem])
    launch.controller.willShowWindow()
    launch.windowsChanged([Self.mainWindow])
    launch.windowsChanged([Self.statusItem])
    launch.windowsChanged([Self.statusItem], appIsHidden: true)
    #expect(launch.appliedPolicies.isEmpty)
  }

  // MARK: - Windows

  /// The Dock icon goes when the last window closes and comes back before a window opens.
  /// Only that last close frees the decoded thumbnails, which a window then decodes again;
  /// the library revision is unchanged. Window events while no window is open free nothing
  /// more. Closing the last window frees them with the setting off too.
  @Test func onlyTheLastWindowClosingFreesTheThumbnailCaches() async throws {
    let asset = TestAssetFactory.makeAsset(id: "menu-bar-thumbnail")
    let backend = FakeThumbnailBackend(assets: [asset])
    let launch = try Launch(
      label: "menu-bar-caches", runsInMenuBar: true, opensWithoutWindow: false
    ) { composition in
      (composition.photoLibraryServiceOverride as? FakePhotoLibraryService)?
        .thumbnailReaderOverride = ProductionThumbnailReader(backend: backend)
    }
    defer { launch.cleanUp() }
    let library = launch.core.photoLibraryManager
    let handle = try #require(await library.resolveThumbnailAssets(ids: [asset.id]).first)
    func decode() async -> Bool {
      await library.decodedThumbnail(
        for: handle, quantizedSize: ThumbnailRequestSpec.gridSize, deliveryMode: .highQuality)
        != nil
    }
    func isCached() -> Bool {
      library.cachedDecodedThumbnail(
        for: asset.id, quantizedSize: ThumbnailRequestSpec.gridSize, deliveryMode: .highQuality)
        != nil
    }
    func requests() -> Int { backend.calls.value.filter { $0.action == "request" }.count }
    launch.controller.launchWillFinish()
    launch.controller.launchDidFinish()
    #expect(await decode())
    #expect(isCached())
    let revision = library.libraryRevision
    let requestsBefore = requests()

    // Window changes that leave a window open (which windows count is
    // `userWindowsAreTitledAndShownOrMinimized`).
    launch.windowsChanged([Self.statusItem, Self.mainWindow])
    launch.windowsChanged([Self.mainWindow])
    #expect(isCached())
    #expect(launch.appliedPolicies.isEmpty)

    launch.windowsChanged([Self.statusItem])
    #expect(!isCached())
    #expect(library.libraryRevision == revision)
    #expect(launch.appliedPolicies == [.accessory])

    // The freed image is requested again. Something decoded while no window is open stays
    // cached through more window events.
    #expect(await decode())
    #expect(requests() > requestsBefore)
    launch.windowsChanged([Self.statusItem])
    launch.windowsChanged([])
    #expect(isCached())
    launch.windowsChanged([Self.statusItem])
    #expect(isCached())

    // Opening a window frees nothing; the window decodes what it lacks.
    launch.controller.willShowWindow()
    launch.windowsChanged([Self.statusItem, Self.mainWindow])
    #expect(launch.appliedPolicies == [.accessory, .regular])
    #expect(isCached())

    launch.composition.defaults.set(false, forKey: MenuBarMode.defaultsKey)
    launch.windowsChanged([Self.statusItem])
    #expect(!isCached())
    #expect(launch.appliedPolicies == [.accessory, .regular])
  }

  /// A hidden app's windows all report not visible. Cmd-H keeps the Dock icon; Hide Others
  /// doesn't give a windowless app one.
  @Test func hidingKeepsWhetherAWindowWasOpen() async throws {
    let launch = try Launch(
      label: "menu-bar-hide", runsInMenuBar: true, opensWithoutWindow: true)
    defer { launch.cleanUp() }
    launch.controller.launchWillFinish()
    launch.controller.launchDidFinish()
    await drainMainQueue()
    #expect(launch.appliedPolicies == [.accessory])

    launch.windowsChanged([Self.statusItem], appIsHidden: true)
    launch.windowsChanged([Self.statusItem], appIsHidden: false)
    #expect(launch.appliedPolicies == [.accessory])

    launch.controller.willShowWindow()
    launch.windowsChanged([Self.statusItem, Self.mainWindow])
    #expect(launch.appliedPolicies == [.accessory, .regular])
    let hiddenMain = MenuBarMode.WindowState(isTitled: true, isVisible: false)
    launch.windowsChanged([Self.statusItem, hiddenMain], appIsHidden: true)
    #expect(launch.appliedPolicies == [.accessory, .regular])
    launch.windowsChanged([Self.statusItem, Self.mainWindow], appIsHidden: false)
    #expect(launch.appliedPolicies == [.accessory, .regular])
  }

  /// A window requested from the menu bar counts as open until it appears: a window event
  /// from before it appears (the menu closing, an occlusion change) keeps the Dock icon. With
  /// no window after `showWindowTimeout` from the latest request, the Dock icon goes again.
  @Test func aWindowRequestedFromTheMenuBarCountsUntilItAppears() async throws {
    let launch = try Launch(
      label: "menu-bar-show", runsInMenuBar: true, opensWithoutWindow: true)
    defer { launch.cleanUp() }
    launch.controller.launchWillFinish()
    launch.controller.launchDidFinish()
    await drainMainQueue()

    launch.controller.willShowWindow()
    launch.windowsChanged([Self.statusItem])
    #expect(launch.appliedPolicies == [.accessory, .regular])
    launch.windowsChanged([Self.statusItem, Self.mainWindow])
    launch.windowsChanged([Self.statusItem])
    #expect(launch.appliedPolicies == [.accessory, .regular, .accessory])

    // A second request restarts the wait.
    let timeout = MenuBarModeController.showWindowTimeout
    launch.controller.willShowWindow()
    launch.windowsChanged([Self.statusItem])
    launch.clock.advance(by: timeout - 1)
    launch.controller.willShowWindow()
    launch.clock.advance(by: timeout - 1)
    #expect(launch.appliedPolicies == [.accessory, .regular, .accessory, .regular])
    launch.clock.advance(by: 1)
    #expect(launch.appliedPolicies == [.accessory, .regular, .accessory, .regular, .accessory])
  }

  /// The controller compares with the app's real policy, so it puts `.accessory` back after
  /// the policy changed outside it.
  @Test func aPolicyChangedOutsideTheControllerIsPutBack() async throws {
    let launch = try Launch(
      label: "menu-bar-promoted", runsInMenuBar: true, opensWithoutWindow: true)
    defer { launch.cleanUp() }
    launch.controller.launchWillFinish()
    launch.controller.launchDidFinish()
    await drainMainQueue()
    #expect(launch.appliedPolicies == [.accessory])
    launch.changePolicyElsewhere()
    launch.windowsChanged([Self.statusItem])
    #expect(launch.appliedPolicies == [.accessory, .accessory])
  }

  // MARK: - Authorization

  /// With no window the app is rarely activated; the started core re-reads Photos access on
  /// its clock, and a reset access brings the Dock icon back for the prompt.
  @Test func startedCoreRefreshesAuthorizationWithoutActivation() async throws {
    let launch = try Launch(
      label: "menu-bar-auth", runsInMenuBar: true, opensWithoutWindow: true)
    defer { launch.cleanUp() }
    launch.controller.launchWillFinish()
    launch.controller.launchDidFinish()
    await drainMainQueue()
    #expect(launch.appliedPolicies == [.accessory])

    launch.photos.authorizationStatus = .notDetermined
    launch.clock.advance(by: PhotoLibraryManager.authorizationRefreshInterval - 1)
    #expect(launch.core.photoLibraryManager.authorizationStatus == .authorized)
    launch.clock.advance(by: 1)
    #expect(launch.core.photoLibraryManager.authorizationStatus == .notDetermined)
    #expect(launch.appliedPolicies == [.accessory, .regular])

    launch.photos.authorizationStatus = .authorized
    launch.clock.advance(by: PhotoLibraryManager.authorizationRefreshInterval)
    #expect(launch.appliedPolicies == [.accessory, .regular, .accessory])
  }

  // MARK: - Quit

  /// Quitting stops Auto Export through the core: with a safe destination and Auto Export
  /// on, Export Now and an hour of triggers start no run and record no summary afterwards.
  @Test func quitStopsAutoExport() async throws {
    let launch = try Launch(
      label: "menu-bar-quit", runsInMenuBar: true, opensWithoutWindow: false)
    defer { launch.cleanUp() }
    let environment = FakeAutoSyncEnvironmentBuilder()
    environment.userDefaults.set(true, forKey: AutoSyncManager.enabledDefaultsKey)
    environment.destination.subject.send(
      DestinationSnapshot(
        fingerprint: .makeHigh(
          volumeUUIDString: "uuid-menu-bar", volumeRootPath: nil,
          relativePathFromVolumeRoot: "/dest", standardizedPath: "/Volumes/A/dest"),
        isAvailable: true, safety: .safe))
    environment.scopes.subject.send(AutoExportScopeSelection(timeline: true))
    let autoSync = launch.core.autoSyncManager
    autoSync.attach(to: environment.environment)
    // The launch run, so Export Now below would otherwise start a second one.
    environment.clock.advance(by: 10)
    #expect(await observe { environment.exportRunner.receivedContexts.count == 1 })
    #expect(await observe { autoSync.activeRunFanOutTask == nil })
    let summaries = environment.runSummaryStore.saveCount

    // Auto Export is stopped before the quit waits for exports, not when it replies.
    var replied = false
    launch.core.stopForQuit { replied = true }
    autoSync.runNow()
    environment.clock.advance(by: 3600)
    #expect(autoSync.activeRunFanOutTask == nil)
    #expect(await eventually("quit replied") { replied })

    autoSync.runNow()
    environment.clock.advance(by: 3600)
    for _ in 0..<20 { await Task.yield() }
    #expect(environment.exportRunner.receivedContexts.count == 1)
    #expect(autoSync.activeRunFanOutTask == nil)
    #expect(environment.runSummaryStore.saveCount == summaries)
  }
}
