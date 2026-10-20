import AppKit
import Combine
import Foundation

/// The app's object graph, built from an `AppComposition`, and its startup sequence.
///
/// `PhotoExportApp.init` builds one eagerly and hands its objects to the scenes; the main
/// window's `.task` calls `start()`. Building touches no PhotoKit API: the first PhotoKit
/// call is in `start()`, after the first window has rendered (#92).
@MainActor
final class AppCore {
  /// One step of `start()`, in the order `startupSteps(wiresAutoSync:)` gives.
  enum StartupStep: Equatable, Sendable {
    /// `PhotoLibraryManager.start()`: authorization probe and change observer.
    case photoLibrary
    /// `AppLifecycleCoordinator.attach`: configures the record stores for the destination.
    case destinationLifecycle
    /// `AutoSyncManager.attach`.
    case autoSync
    /// `PhotoLibraryPersistentChangeAdapter.start()`.
    case photoChangeObservation
    /// `DestinationSafetyMonitor.attach()`.
    case destinationSafety
    /// Sizes the window for capture in screenshot mode; nothing otherwise.
    case screenshotWindow
    /// Ends the launch signpost interval.
    case launchFinished
  }

  /// The lifecycle coordinator attaches before AutoSync, so the destination snapshot
  /// adapter sees the initial migration-conflict state on its first emission, and before the
  /// safety monitor, so the record stores are configured for the current destination before
  /// the monitor reads their counts.
  static func startupSteps(wiresAutoSync: Bool) -> [StartupStep] {
    var steps: [StartupStep] = [.photoLibrary, .destinationLifecycle]
    if wiresAutoSync {
      steps += [.autoSync, .photoChangeObservation]
    }
    steps += [.destinationSafety, .screenshotWindow, .launchFinished]
    return steps
  }

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
  let autoSyncDestinationAdapter: DestinationSnapshotAdapter
  let autoSyncPhotoChangeAdapter: PhotoLibraryPersistentChangeAdapter
  let autoSyncDirtyStateStore: FileBackedAutoSyncDirtyStateStore
  let autoSyncRetryStateStore: FileBackedAutoSyncRetryStateStore
  let autoSyncRunSummaryStore: FileBackedAutoSyncRunSummaryStore
  let autoSyncPerDestinationTokenStore: FileBackedAutoSyncPerDestinationTokenStore
  let autoSyncCurrentRunStore: FileBackedAutoSyncCurrentRunStore
  let autoSyncClock: any AutoSyncClock
  let destinationSafetyMonitor: DestinationSafetyMonitor

  private let startupObserver: (@MainActor (StartupStep) -> Void)?
  private var hasStarted = false

  /// `startupObserver` is told each step just before it runs.
  init(
    composition: AppComposition,
    startupObserver: (@MainActor (StartupStep) -> Void)? = nil
  ) {
    self.composition = composition
    self.startupObserver = startupObserver
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
      authorizationStatusPublisher: plm.$authorizationStatus.eraseToAnyPublisher(),
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
    // variant attempt. Reads `AutoSyncManager.currentRetryState`, which the manager keeps
    // current after every `.recordRetryFailures` effect and on destination change. `[weak
    // asm]` so the closure doesn't keep the manager alive.
    em.autoSyncEligibilityCheck = { [weak asm] assetId, placement, variant, now in
      guard let asm else { return true }
      let scope = AutoSyncManager.retryScopeKey(for: placement)
      guard
        let entry = asm.currentRetryState.entry(
          scope: scope, assetId: assetId, variant: variant)
      else { return true }
      // Hard category (nextEligibleAt == nil) means user action is required; not eligible
      // to auto-retry.
      guard let nextEligibleAt = entry.nextEligibleAt else { return false }
      return nextEligibleAt <= now
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
    autoSyncDestinationAdapter = destinationAdapter
    autoSyncPhotoChangeAdapter = photoAdapter
    autoSyncDirtyStateStore = dirtyStore
    autoSyncRetryStateStore = retryStore
    autoSyncRunSummaryStore = runSummaryStore
    autoSyncPerDestinationTokenStore = perDestinationTokenStore
    autoSyncCurrentRunStore = currentRunStore
    autoSyncClock = clock
  }

  /// Runs the startup steps once. Every window's `.task` calls this; later calls do nothing.
  func start() {
    guard !hasStarted else { return }
    hasStarted = true
    for step in Self.startupSteps(wiresAutoSync: composition.wiresAutoSync) {
      startupObserver?(step)
      run(step)
    }
  }

  private func run(_ step: StartupStep) {
    switch step {
    case .photoLibrary:
      // First-touch PhotoKit here, not in App.init: on macOS 15.7+ the synchronous
      // singleton init has been observed to hang launch (#92). A no-op under tests and
      // with a Photos service override.
      photoLibraryManager.start()
    case .destinationLifecycle:
      lifecycleCoordinator.attach(
        initial: DestinationIdentitySnapshot(identity: exportDestinationManager.identity),
        identityPublisher: exportDestinationManager.$identity.eraseToAnyPublisher()
      )
    case .autoSync:
      autoSyncManager.attach(
        to: AutoSyncEnvironment(
          exportRunner: exportManager,
          destination: autoSyncDestinationAdapter,
          scopes: autoSyncScopeStore,
          photos: autoSyncPhotoChangeAdapter,
          importing: exportManager,
          dirtyStateStore: autoSyncDirtyStateStore,
          retryStateStore: autoSyncRetryStateStore,
          runSummaryStore: autoSyncRunSummaryStore,
          perDestinationTokenStore: autoSyncPerDestinationTokenStore,
          currentRunStore: autoSyncCurrentRunStore,
          clock: autoSyncClock,
          userDefaults: composition.defaults
        ))
    case .photoChangeObservation:
      // Touches PhotoKit (`currentChangeToken`, `register(self)`) and so can raise the
      // Photos permission prompt; a no-op until Photos is authorized.
      autoSyncPhotoChangeAdapter.start()
    case .destinationSafety:
      destinationSafetyMonitor.attach()
    case .screenshotWindow:
      applyScreenshotWindowSizeIfRequested()
    case .launchFinished:
      AppDiagnostics.endLaunch()
    }
  }

  /// When `--screenshot-mode` includes width/height arguments, resize the main window so the
  /// capture script can grab a predictable frame. No-op outside screenshot mode.
  private func applyScreenshotWindowSizeIfRequested() {
    guard composition.isScreenshotMode else { return }
    let args = ProcessInfo.processInfo.arguments
    func value(for prefix: String) -> CGFloat? {
      guard
        let arg = args.first(where: { $0.hasPrefix(prefix) }),
        let raw = arg.split(separator: "=").last.map(String.init),
        let n = Double(raw)
      else { return nil }
      return CGFloat(n)
    }
    guard
      let width = value(for: "--screenshot-width="),
      let height = value(for: "--screenshot-height=")
    else {
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
      x: screenFrame.midX - width / 2,
      y: screenFrame.midY - height / 2
    )
    window.setFrame(
      NSRect(origin: origin, size: CGSize(width: width, height: height)),
      display: true, animate: false)
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
  /// the export history against the folder (#334). Not while a migration conflict is open: its
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
    switch result {
    case .success:
      timelineStore.configure(for: newId)
      collectionStore.configure(for: newId)
      return .success
    case .failure(.conflict(let conflictNewId, let legacyId)):
      // Both `<newId>/` and `<legacyId>/` exist. Configuring proceeds with `<newId>/` so
      // the user can keep using the app, but the conflict is surfaced on the lifecycle
      // coordinator so future Settings UI / auto-sync can present recovery options.
      timelineStore.configure(for: newId)
      collectionStore.configure(for: newId)
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
