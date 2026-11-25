import AppKit
import Combine
import Foundation
import SwiftUI
import os

/// The app's object graph, built from an `AppComposition`, and its startup sequence.
///
/// `PhotoExportApp.init` builds one eagerly and hands its objects to the scenes through
/// `photoExportEnvironment(_:)`; the main window's `.task` calls `start()`. Building touches no PhotoKit API: the first PhotoKit
/// call is in `start()`, after the first window has rendered.
@MainActor
final class AppCore {
  let composition: AppComposition
  let exportDestinationManager: ExportDestinationManager
  let photoLibraryManager: PhotoLibraryManager
  let exportRecordStore: ExportRecordStore
  let collectionExportRecordStore: CollectionExportRecordStore
  let exportManager: ExportManager
  let lifecycleCoordinator: AppLifecycleCoordinator
  let autoSyncManager: AutoSyncManager
  let autoSyncScopeStore: UserDefaultsAutoExportScopeStore
  let loginItemController: LoginItemController
  let whatsNewState: WhatsNewState
  /// Observed by Settings and the diagnostic report even when AutoSync watches another
  /// change source.
  let autoSyncPhotoChangeAdapter: PhotoLibraryPersistentChangeAdapter?
  let destinationSafetyMonitor: DestinationSafetyMonitor
  /// What `start()` attaches AutoSync to.
  let autoSyncEnvironment: AutoSyncEnvironment

  private let persistentChangeSource: any StartablePhotoLibraryChangeProviding
  private var hasStarted = false

  init(composition: AppComposition) {
    self.composition = composition
    let defaults = composition.defaults

    // Screenshot mode skips bookmark restoration and overrides the displayed folder name, so
    // the maintainer's real backup folder name never shows in a marketing capture.
    let edm = Self.makeDestinationManager(for: composition)
    if composition.isScreenshotMode {
      // ContentView gates on `@AppStorage("hasCompletedOnboarding")`; without this it would
      // show OnboardingView and the capture script would never reach the marketing surfaces.
      // Under the capture script this lands in its own bundle id's domain, which the script
      // clears before each launch. A plain `--screenshot-mode` launch keeps the value.
      defaults.set(true, forKey: "hasCompletedOnboarding")
    }
    // With an override (the curated screenshot library, or a test fake) the manager forwards
    // every `PhotoLibraryService` method to it; without one it runs its PhotoKit code.
    let plm: PhotoLibraryManager =
      composition.photoLibraryServiceOverride.map {
        PhotoLibraryManager(
          overrideService: $0, refreshClock: composition.clock)
      }
      ?? PhotoLibraryManager(
        refreshClock: composition.clock)
    let ers = ExportRecordStore(baseDirectoryURL: composition.recordsRoot)
    let cers = CollectionExportRecordStore(baseDirectoryURL: composition.recordsRoot)
    let em = ExportManager(
      photoLibraryService: plm, photoKitReader: composition.photoKitReader,
      exportDestination: edm, exportRecordStore: ers,
      collectionExportRecordStore: cers,
      assetResourceWriter: composition.assetResourceWriter,
      mediaRenderer: composition.mediaRenderer,
      fileSystem: composition.fileSystem,
      phAssetCacheControl: composition.phAssetCacheControl(plm), userDefaults: defaults)
    #if DEBUG
      if composition.makeControlDestination != nil {
        em.controlSettlingWork = ControlSettlingWork()
      }
    #endif
    // Drive the PhotoLibraryManager `descriptor(from:)` Live Photo resource fallback from the
    // toggle ExportManager owns. Synchronous sink so the next fetch sees the current value;
    // the named bridge accessor synchronously replays its current value to new subscribers.
    plm.bindLivePhotoDetectionFallback(to: em.livePhotosPairedExportPublisher)

    let configure: (String?) -> ConfigureRecordStoresResult = { [edm, ers, cers] newId in
      Self.configureRecordStores(
        for: newId,
        destinationManager: edm,
        timelineStore: ers,
        collectionStore: cers
      )
    }
    let coordinator = AppLifecycleCoordinator(
      cancelActiveWork: { [em] in em.cancelAndClear() },
      interruptForDestinationUnavailable: { [em] in em.interruptForDestinationUnavailable() },
      configureRecordStores: configure,
      gcLegacyState: { [composition] legacyId in composition.removeLegacyState(for: legacyId) }
    )
    Self.connectAmbiguousSameFolderImport(
      destinationManager: edm, exportManager: em,
      hasMigrationConflict: { [weak coordinator] in coordinator?.migrationConflict != nil })

    let destinationsRoot = composition.autoSyncDestinationsRoot
    let dirtyStore = FileBackedAutoSyncDirtyStateStore(baseDirectoryURL: destinationsRoot)
    let retryStore = FileBackedAutoSyncRetryStateStore(baseDirectoryURL: destinationsRoot)
    let runSummaryStore = FileBackedAutoSyncRunSummaryStore(
      baseDirectoryURL: destinationsRoot)
    let tokenStore = GlobalPhotoChangeTokenStore(fileURL: composition.photoChangeTokenFileURL)
    let clock = composition.clock
    // The bridge callback wakes `PhotoLibraryManager` whenever the safety-net reconcile turns
    // up changes that PhotoKit's normal observer missed, so the timeline grid and sidebar
    // counts refresh alongside AutoSync. `[weak plm]` to avoid pinning the manager.
    let photoAdapter: PhotoLibraryPersistentChangeAdapter?
    if Self.usesPhotoChangeAdapter(in: composition) {
      photoAdapter = PhotoLibraryPersistentChangeAdapter(
        tokenStore: tokenStore,
        authorizationStatusPublisher: plm.authorizationStatusPublisher,
        clock: clock,
        onPotentialLibraryChange: { [weak plm] in plm?.invalidateCache() }
      )
    } else {
      photoAdapter = nil
    }
    let safetyConfirmationStore = FileBackedDestinationSafetyConfirmationStore(
      baseDirectoryURL: destinationsRoot)
    let safetyMonitor = DestinationSafetyMonitor(
      destinationManager: edm,
      exportRecordStore: ers,
      collectionExportRecordStore: cers,
      confirmationStore: safetyConfirmationStore
    )
    let destinationAdapter = DestinationSnapshotAdapter(
      destinationManager: edm, lifecycleCoordinator: coordinator,
      safetyMonitor: safetyMonitor)
    let scopeStore = UserDefaultsAutoExportScopeStore(userDefaults: defaults)
    let asm = AutoSyncManager()
    // AutoSync retry eligibility for ExportManager, evaluated at enqueue time and before each
    // variant attempt. `AutoSyncManager` reads its current retry state, kept up to date after
    // every recorded failure and on destination change. `[weak asm]` so the closure doesn't
    // keep the manager alive.
    em.autoSyncEligibilityCheck = { [weak asm] assetId, placement, variant, now in
      asm?.isAutoSyncEligible(
        assetId: assetId, placement: placement, variant: variant, now: now) ?? true
    }

    guard let changeSource = composition.persistentChangeSource ?? photoAdapter else {
      preconditionFailure("AppCore requires a Photos change source.")
    }

    exportDestinationManager = edm
    photoLibraryManager = plm
    exportRecordStore = ers
    collectionExportRecordStore = cers
    exportManager = em
    lifecycleCoordinator = coordinator
    autoSyncManager = asm
    autoSyncScopeStore = scopeStore
    loginItemController = LoginItemController(service: composition.loginItemService)
    whatsNewState = WhatsNewState(userDefaults: defaults)
    destinationSafetyMonitor = safetyMonitor
    autoSyncPhotoChangeAdapter = photoAdapter
    persistentChangeSource = changeSource
    autoSyncEnvironment = AutoSyncEnvironment(
      exportRunner: em,
      destination: destinationAdapter,
      scopes: scopeStore,
      photos: changeSource,
      importing: em,
      dirtyStateStore: dirtyStore,
      retryStateStore: retryStore,
      runSummaryStore: runSummaryStore,
      clock: clock,
      photosAuthorization: plm,
      userDefaults: defaults)
  }

  private static func makeDestinationManager(for composition: AppComposition)
    -> ExportDestinationManager
  {
    #if DEBUG
      if let makeControlDestination = composition.makeControlDestination {
        return makeControlDestination()
      }
    #endif
    let manager = ExportDestinationManager(
      skipRestore: composition.isScreenshotMode, userDefaults: composition.defaults)
    if composition.isScreenshotMode { manager.configureForScreenshotMode() }
    return manager
  }

  private static func usesPhotoChangeAdapter(in composition: AppComposition) -> Bool {
    #if DEBUG
      return composition.makeControlDestination == nil
    #else
      return true
    #endif
  }

  /// Runs the startup sequence once. Every window's `.task` calls this; later calls do
  /// nothing, so a second window doesn't register the Photos observer again or repeat the
  /// startup catch-up. A Photos grant after a deferred start still arrives through the
  /// change adapter's authorization subscription.
  func start() {
    guard !hasStarted else { return }
    hasStarted = true
    // First PhotoKit touch: here, after the window has rendered, not in App.init. On
    // macOS 15.7+ the synchronous singleton init has been observed to hang launch. A
    // no-op under tests and with a Photos service override.
    photoLibraryManager.start()
    // Configures the record stores for the current destination and follows its changes.
    lifecycleCoordinator.attach(
      initial: DestinationIdentitySnapshot(identity: exportDestinationManager.identity),
      identityPublisher: exportDestinationManager.identityPublisher
    )
    if composition.wiresAutoSync {
      // After the lifecycle coordinator, so the destination snapshot adapter sees the
      // initial migration-conflict state on its first emission. AutoSync subscribes to the
      // change source before the source starts, so the startup catch-up reaches it. The
      // PhotoKit adapter touches PhotoKit (`currentChangeToken`, `register(self)`) and can
      // raise the permission prompt; it waits for Photos authorization.
      autoSyncManager.attach(to: autoSyncEnvironment)
      persistentChangeSource.start()
    }
    // After the lifecycle coordinator, so the record stores are configured for the current
    // destination before the monitor reads their counts; it waits for a store still loading.
    destinationSafetyMonitor.attach()
    prepareScreenshotWindow()
    AppDiagnostics.endLaunch()
  }

  /// In screenshot mode, once the main window is on screen: resize it to the requested size
  /// and, when the capture script passed a window file, write the window's number and the
  /// surface that opened. The script captures by window number (`screencapture -l`), which
  /// needs only Screen Recording, not AppleScript, System Events or Accessibility. The window
  /// can reach the screen after `start()`, so this looks for up to 5 seconds and then records
  /// that it found none.
  private func prepareScreenshotWindow() {
    guard composition.isScreenshotMode else { return }
    Task { @MainActor [weak self] in
      for _ in 0..<50 {
        // The titled window, not the menu bar item's.
        if let window = NSApplication.shared.windows.first(where: {
          $0.styleMask.contains(.titled) && $0.isVisible && $0.windowNumber > 0
        }) {
          self?.prepareScreenshotWindow(window)
          return
        }
        try? await Task.sleep(for: .milliseconds(100))
      }
      self?.writeScreenshotWindowFile(windowNumber: nil)
    }
  }

  private func prepareScreenshotWindow(_ window: NSWindow) {
    if let size = composition.screenshotWindowSize {
      let screenFrame = window.screen?.visibleFrame ?? .zero
      let origin = NSPoint(
        x: screenFrame.midX - size.width / 2, y: screenFrame.midY - size.height / 2)
      window.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
    }
    // An inactive window captures with grey controls, so take focus from the app in front.
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
    writeScreenshotWindowFile(windowNumber: window.windowNumber)
  }

  private func writeScreenshotWindowFile(windowNumber: Int?) {
    guard let file = composition.screenshotWindowFile else { return }
    let record = Self.screenshotWindowRecord(
      windowNumber: windowNumber, surfaceKey: composition.screenshotSurfaceKey)
    do {
      try record.write(to: file, options: .atomic)
    } catch {
      Logger.app(.screenshot).error(
        "Could not write the screenshot window file: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  /// `{"window": N, "surface": key}`. `surface` is null when the key resolves to no surface,
  /// because the window then opens on the default Timeline month. Without a window, `window`
  /// is null and `error` says why.
  static func screenshotWindowRecord(windowNumber: Int?, surfaceKey: String?) -> Data {
    var object: [String: Any] = ["window": NSNull(), "surface": NSNull()]
    if let windowNumber {
      object["window"] = windowNumber
    } else {
      object["error"] = "No visible titled window within 5 seconds"
    }
    if let surfaceKey, ScreenshotSurfaceResolver.resolve(key: surfaceKey) != nil {
      object["surface"] = surfaceKey
    }
    return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
  }

  /// "Same Folder" for a pick that couldn't be compared with the previous destination checks
  /// the export history against the folder. Not while a migration conflict is open: its
  /// recovery owns the records until resolved.
  static func connectAmbiguousSameFolderImport(
    destinationManager: ExportDestinationManager, exportManager: ExportManager,
    hasMigrationConflict: @escaping @MainActor () -> Bool
  ) {
    destinationManager.onAmbiguousSameFolderChosen = { [weak exportManager] in
      guard !hasMigrationConflict() else { return }
      exportManager?.startImportForConfirmedSameFolder()
    }
  }

  /// Runs the per-destination directory coordinator (the lazy legacy-id migration) and then
  /// reconfigures both record stores. The coordinator runs **once** per destination change,
  /// before either store touches the directory, so the legacy `<oldId>` → `<newId>` rename
  /// happens exactly once and neither store can race the other to create `<newId>/`
  /// (which would orphan the legacy directory).
  ///
  /// Static so `AppLifecycleCoordinator` can call it from a closure captured at init time
  /// without holding a reference to the core.
  static func configureRecordStores(
    for newId: String?,
    destinationManager: ExportDestinationManager,
    timelineStore: ExportRecordStore,
    collectionStore: CollectionExportRecordStore
  ) -> ConfigureRecordStoresResult {
    guard let newId else {
      timelineStore.beginConfigure(for: nil)
      collectionStore.beginConfigure(for: nil)
      return .success
    }
    let coordinator = ExportRecordsDirectoryCoordinator(
      storeRootURL: timelineStore.storeRootURL)
    // Priority: most-recent legacy form first. For low-confidence drives, the
    // volumeIdentifier-based digest is the most recent pre-upgrade form, so it ranks above
    // the even older bookmark-hash form. High-confidence drives have only the bookmark-
    // hash legacy id (`currentPreV2LowConfidenceLegacyId` returns nil), so the order
    // is moot for them.
    let legacyIds = [
      destinationManager.currentPreV2LowConfidenceLegacyId(),
      destinationManager.currentLegacyDestinationId(),
    ].compactMap { $0 }
    let result = coordinator.prepareDirectory(for: newId, legacyIds: legacyIds)
    // The stores read the new destination's history off the main actor and are `.loading`
    // until it is in; the directory is prepared before either starts.
    switch result {
    case .success:
      timelineStore.beginConfigure(for: newId)
      collectionStore.beginConfigure(for: newId)
      return .success
    case .failure(.conflict(let conflictNewId, let legacyId)):
      // Both `<newId>/` and `<legacyId>/` exist. Configuring proceeds with `<newId>/` so
      // the user can keep using the app, but the conflict is surfaced on the lifecycle
      // coordinator so future Settings UI / auto-sync can present recovery options.
      timelineStore.beginConfigure(for: newId)
      collectionStore.beginConfigure(for: newId)
      return .migrationConflict(newId: conflictNewId, legacyId: legacyId)
    case .failure(.migrationFailed(let message)):
      // Transient I/O error during the legacy → new rename. `<legacyId>/` still has the
      // user's records; `<newId>/` does not exist yet. Configuring `for: newId` would
      // create `<newId>/` and trip the conflict-detection branch on every subsequent
      // launch, permanently stranding the legacy records. Leave both stores unconfigured;
      // next launch (or the next destinationId change) retries the rename.
      timelineStore.beginConfigure(for: nil)
      collectionStore.beginConfigure(for: nil)
      return .migrationFailed(message: message)
    }
  }
}

extension EnvironmentValues {
  /// `AppComposition.isScreenshotMode` for views: suppresses surfaces that would spoil a
  /// marketing capture.
  @Entry var isScreenshotMode = false
  /// `AppComposition.screenshotSurfaceKey`: where the library window first lands.
  @Entry var screenshotSurfaceKey: String?
  @Entry var photoChangeAdapter: PhotoLibraryPersistentChangeAdapter?
  #if DEBUG
    @Entry var controlLibrarySurface: ScreenshotSurfaceResolver.Surface?
  #endif
}

extension View {
  /// The environment every scene root gets from the core: its shared objects, the
  /// screenshot-mode flag and surface, and its preferences suite as the default
  /// `@AppStorage` store.
  func photoExportEnvironment(_ core: AppCore) -> some View {
    let root = self.environmentObject(core.exportDestinationManager)
      .environment(core.photoLibraryManager)
      .environment(core.exportManager)
      .environment(core.exportManager.progressState)
      .environment(core.exportRecordStore)
      .environment(core.collectionExportRecordStore)
      .environmentObject(core.lifecycleCoordinator)
      .environmentObject(core.autoSyncManager)
      .environmentObject(core.autoSyncScopeStore)
      .environment(\.photoChangeAdapter, core.autoSyncPhotoChangeAdapter)
      .environmentObject(core.destinationSafetyMonitor)
      .environment(core.loginItemController)
      .environment(core.whatsNewState)
      .environment(\.isScreenshotMode, core.composition.isScreenshotMode)
      .environment(\.screenshotSurfaceKey, core.composition.screenshotSurfaceKey)
      .defaultAppStorage(core.composition.defaults)
    #if DEBUG
      return root.environment(\.controlLibrarySurface, core.composition.controlLibrarySurface)
    #else
      return root
    #endif
  }
}
