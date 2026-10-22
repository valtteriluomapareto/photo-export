import AppKit
import Combine
import Foundation
import SwiftUI

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
  let autoSyncPhotoChangeAdapter: PhotoLibraryPersistentChangeAdapter
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
    let edm: ExportDestinationManager
    if composition.isScreenshotMode {
      edm = ExportDestinationManager(skipRestore: true, userDefaults: defaults)
      edm.configureForScreenshotMode()
    } else {
      edm = ExportDestinationManager(userDefaults: defaults)
    }
    if composition.isScreenshotMode {
      // ContentView gates on `@AppStorage("hasCompletedOnboarding")`; without this it would
      // show OnboardingView on a fresh machine and the capture script would never reach the
      // marketing surfaces. The change persists, but screenshot mode is only used on the
      // maintainer's machine, where the value is already true.
      defaults.set(true, forKey: "hasCompletedOnboarding")
      // macOS persists `NSSplitView Subview Frames …` divider positions across launches via
      // `NSWindow.frameAutosaveName`. The persisted values win over
      // `navigationSplitViewColumnWidth(min:ideal:max:)`, so a prior resize would survive
      // into the capture. Clearing them lets the declarative widths apply.
      for key in defaults.dictionaryRepresentation().keys
      where key.hasPrefix("NSSplitView Subview Frames ") {
        defaults.removeObject(forKey: key)
      }
    }
    // With an override (the curated screenshot library, or a test fake) the manager forwards
    // every `PhotoLibraryService` method to it; without one it runs its PhotoKit code.
    let plm: PhotoLibraryManager =
      composition.photoLibraryServiceOverride.map { PhotoLibraryManager(overrideService: $0) }
      ?? PhotoLibraryManager()
    let ers = ExportRecordStore(baseDirectoryURL: composition.recordsRoot)
    let cers = CollectionExportRecordStore(baseDirectoryURL: composition.recordsRoot)
    let em = ExportManager(
      photoLibraryService: plm, exportDestination: edm, exportRecordStore: ers,
      collectionExportRecordStore: cers,
      assetResourceWriter: composition.assetResourceWriter,
      fileSystem: composition.fileSystem,
      phAssetCacheControl: composition.phAssetCacheControl(plm), userDefaults: defaults)
    // Drive the PhotoLibraryManager `descriptor(from:)` Live Photo resource fallback from the
    // toggle ExportManager owns. Synchronous sink so the next fetch sees the current value;
    // the initial value flows immediately because `@Published` re-emits to new subscribers.
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
    let perDestinationTokenStore = FileBackedAutoSyncPerDestinationTokenStore(
      baseDirectoryURL: destinationsRoot)
    let currentRunStore = FileBackedAutoSyncCurrentRunStore(
      baseDirectoryURL: destinationsRoot)
    let tokenStore = GlobalPhotoChangeTokenStore(fileURL: composition.photoChangeTokenFileURL)
    let clock = composition.clock
    // The bridge callback wakes `PhotoLibraryManager` whenever the safety-net reconcile turns
    // up changes that PhotoKit's normal observer missed, so the timeline grid and sidebar
    // counts refresh alongside AutoSync. `[weak plm]` to avoid pinning the manager.
    let photoAdapter = PhotoLibraryPersistentChangeAdapter(
      tokenStore: tokenStore,
      authorizationStatusPublisher: plm.authorizationStatusPublisher,
      clock: clock,
      onPotentialLibraryChange: { [weak plm] in plm?.invalidateCache() }
    )
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

    let changeSource = composition.persistentChangeSource ?? photoAdapter

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
      perDestinationTokenStore: perDestinationTokenStore,
      currentRunStore: currentRunStore,
      clock: clock,
      photosAuthorization: plm,
      userDefaults: defaults)
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
    applyScreenshotWindowSizeIfRequested()
    AppDiagnostics.endLaunch()
  }

  /// In screenshot mode with a requested size, resize the main window so the capture
  /// script can grab a predictable frame. No-op outside screenshot mode.
  private func applyScreenshotWindowSizeIfRequested() {
    guard composition.isScreenshotMode else { return }
    guard let size = composition.screenshotWindowSize else {
      // No requested size: still publish the window id so the capture script can grab
      // whatever window the system gives us.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        Self.publishScreenshotWindowID()
      }
      return
    }
    guard let window = NSApplication.shared.windows.first else { return }
    let screenFrame = window.screen?.visibleFrame ?? .zero
    let origin = NSPoint(
      x: screenFrame.midX - size.width / 2,
      y: screenFrame.midY - size.height / 2
    )
    window.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
    // After the resize settles, publish the window's CGWindowID to a well-known temp file.
    // The capture script calls `screencapture -l<windowID>`: pixel-exact, no coordinate
    // math, and correct on whichever display the window lives on. This needs only Screen
    // Recording, not AppleScript, System Events or Accessibility.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      Self.publishScreenshotWindowID()
    }
  }

  /// Writes the main window's CGWindowID to `$TMPDIR/photo-export-screenshot-window-id.txt`
  /// as a single integer line. Removed if no window is available. Screenshot mode only.
  private static func publishScreenshotWindowID() {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("photo-export-screenshot-window-id.txt")
    guard let window = NSApplication.shared.windows.first else {
      try? FileManager.default.removeItem(at: url)
      return
    }
    let line = String(window.windowNumber)
    try? line.write(to: url, atomically: true, encoding: .utf8)
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
      timelineStore.configure(for: nil)
      collectionStore.configure(for: nil)
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
      timelineStore.configure(for: nil)
      collectionStore.configure(for: nil)
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
}

extension View {
  /// The environment every scene root gets from the core: its shared objects, the
  /// screenshot-mode flag and surface, and its preferences suite as the default
  /// `@AppStorage` store.
  func photoExportEnvironment(_ core: AppCore) -> some View {
    self.environmentObject(core.exportDestinationManager)
      .environmentObject(core.photoLibraryManager)
      .environmentObject(core.exportManager)
      .environment(core.exportManager.progressState)
      .environment(core.exportRecordStore)
      .environment(core.collectionExportRecordStore)
      .environmentObject(core.lifecycleCoordinator)
      .environmentObject(core.autoSyncManager)
      .environmentObject(core.autoSyncScopeStore)
      .environmentObject(core.autoSyncPhotoChangeAdapter)
      .environmentObject(core.destinationSafetyMonitor)
      .environment(core.loginItemController)
      .environment(core.whatsNewState)
      .environment(\.isScreenshotMode, core.composition.isScreenshotMode)
      .environment(\.screenshotSurfaceKey, core.composition.screenshotSurfaceKey)
      .defaultAppStorage(core.composition.defaults)
  }
}
