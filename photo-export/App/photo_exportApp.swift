//
//  photo_exportApp.swift
//  photo-export
//
//  Created by Valtteri Luoma on 22.4.2025.
//

import Combine
import SwiftUI

@main
struct PhotoExportApp: App {
  @StateObject private var exportDestinationManager: ExportDestinationManager
  @StateObject private var photoLibraryManager: PhotoLibraryManager
  @StateObject private var exportRecordStore: ExportRecordStore
  @StateObject private var collectionExportRecordStore: CollectionExportRecordStore
  @StateObject private var exportManager: ExportManager
  @StateObject private var lifecycleCoordinator: AppLifecycleCoordinator
  @StateObject private var autoSyncManager: AutoSyncManager
  /// `@StateObject` because Settings → Auto Export observes `selection` directly
  /// for checkbox state. The other AutoSync collaborators below stay plain
  /// `let` — no view subscribes to them.
  @StateObject private var autoSyncScopeStore: UserDefaultsAutoExportScopeStore
  @StateObject private var loginItemController: LoginItemController
  @StateObject private var whatsNewState: WhatsNewState

  private let autoSyncDestinationAdapter: DestinationSnapshotAdapter
  /// `@StateObject` because Settings → Auto Export observes
  /// `lastSuccessfulReconciliation` for the "Last checked iCloud …" line.
  @StateObject private var autoSyncPhotoChangeAdapter: PhotoLibraryPersistentChangeAdapter
  private let autoSyncDirtyStateStore: FileBackedAutoSyncDirtyStateStore
  private let autoSyncRetryStateStore: FileBackedAutoSyncRetryStateStore
  private let autoSyncRunSummaryStore: FileBackedAutoSyncRunSummaryStore
  private let autoSyncPerDestinationTokenStore: FileBackedAutoSyncPerDestinationTokenStore
  private let autoSyncClock: SystemAutoSyncClock
  @StateObject private var destinationSafetyMonitor: DestinationSafetyMonitor

  init() {
    // Screenshot mode (`--screenshot-mode` launch arg) swaps the real Photos
    // backing for a curated synthetic library so marketing screenshots don't
    // leak the maintainer's personal Photos library. The subclass shape lets
    // the eight downstream `@EnvironmentObject` sites stay typed against
    // `PhotoLibraryManager` — see
    // `docs/project/archive/screenshot-automation-plan.md`. The destination
    // manager gets the same treatment: skip bookmark restoration and override
    // the displayed folder name so the maintainer's real backup folder name
    // never leaks into a marketing capture.
    let edm: ExportDestinationManager
    if PhotoLibraryManager.isRunningInScreenshotMode {
      edm = ExportDestinationManager(skipRestore: true)
      edm.configureForScreenshotMode()
    } else {
      edm = ExportDestinationManager()
    }
    if PhotoLibraryManager.isRunningInScreenshotMode {
      // ContentView gates on `@AppStorage("hasCompletedOnboarding")`; without
      // this it would show OnboardingView on a fresh machine and the capture
      // script would never reach the marketing surfaces. Setting it for the
      // current launch only — the underlying UserDefaults change persists, but
      // screenshot mode is only ever used on the maintainer's machine where
      // the value should already be true anyway.
      UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
      // macOS persists `NSSplitView Subview Frames …` divider positions across
      // launches via `NSWindow.frameAutosaveName`. The persisted values win
      // over `navigationSplitViewColumnWidth(min:ideal:max:)`, so the maintainer's
      // prior resize would survive into the capture and the columns would
      // render at their old narrow widths even when the modifier asks for
      // wider ideals. Wipe these keys at screenshot-mode launch so the
      // declarative widths actually apply.
      let defaults = UserDefaults.standard
      for key in defaults.dictionaryRepresentation().keys
      where key.hasPrefix("NSSplitView Subview Frames ") {
        defaults.removeObject(forKey: key)
      }
    }
    // Compose: in screenshot mode, the curated service is injected as
    // `overrideService`; the wrapping `PhotoLibraryManager` forwards every
    // `PhotoLibraryService` method to it. In production, no override is set and
    // the manager runs its built-in PhotoKit code. The standalone-conformance
    // shape (issue #67 item 1) closes the inheritance hole the old override-gate
    // test only partially covered.
    let plm: PhotoLibraryManager =
      PhotoLibraryManager.isRunningInScreenshotMode
      ? PhotoLibraryManager(overrideService: ScreenshotPhotoLibraryService())
      : PhotoLibraryManager()
    let ers = ExportRecordStore()
    let cers = CollectionExportRecordStore()
    let em = ExportManager(
      photoLibraryService: plm, exportDestination: edm, exportRecordStore: ers,
      collectionExportRecordStore: cers)

    let configure: (String?) -> ConfigureRecordStoresResult = { [edm, ers, cers] newId in
      Self.configureRecordStores(
        for: newId,
        destinationManager: edm,
        timelineStore: ers,
        collectionStore: cers
      )
    }
    let autoSyncRoot = Self.autoSyncDirectoryURL()
    let recordsRoot = ers.storeRootURL
    let gcLegacy: (String) -> Void = { legacyId in
      // GC the app-internal directories owned by the legacy destination id.
      // Per the plan's Safety Invariants, only app-internal state is touched
      // — user-visible files on the destination drive are not.
      let recordsLegacyDir = recordsRoot.appendingPathComponent(
        legacyId, isDirectory: true)
      try? FileManager.default.removeItem(at: recordsLegacyDir)
      let autoSyncLegacyDir =
        autoSyncRoot
        .appendingPathComponent("destinations", isDirectory: true)
        .appendingPathComponent(legacyId, isDirectory: true)
      try? FileManager.default.removeItem(at: autoSyncLegacyDir)
    }
    let coordinator = AppLifecycleCoordinator(
      cancelActiveWork: { [em] in em.cancelAndClear() },
      interruptForDestinationUnavailable: { [em] in em.interruptForDestinationUnavailable() },
      configureRecordStores: configure,
      gcLegacyState: gcLegacy
    )

    let destinationsRoot = autoSyncRoot.appendingPathComponent(
      "destinations", isDirectory: true)
    let dirtyStore = FileBackedAutoSyncDirtyStateStore(baseDirectoryURL: destinationsRoot)
    let retryStore = FileBackedAutoSyncRetryStateStore(baseDirectoryURL: destinationsRoot)
    let runSummaryStore = FileBackedAutoSyncRunSummaryStore(
      baseDirectoryURL: destinationsRoot)
    let perDestinationTokenStore = FileBackedAutoSyncPerDestinationTokenStore(
      baseDirectoryURL: destinationsRoot)
    let tokenStore = GlobalPhotoChangeTokenStore(
      fileURL: autoSyncRoot.appendingPathComponent("photo-library-change-token.data"))
    // One clock shared between the photo-change adapter and AutoSync so test
    // doubles can advance time consistently across both subsystems if needed.
    let clock = SystemAutoSyncClock()
    // The bridge callback wakes `PhotoLibraryManager` whenever the safety-net
    // reconcile turns up changes that PhotoKit's normal observer missed — so
    // the timeline grid and sidebar counts refresh alongside AutoSync. `[weak
    // plm]` to avoid pinning the manager past App teardown.
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
    let scopeStore = UserDefaultsAutoExportScopeStore(userDefaults: .standard)
    let asm = AutoSyncManager()
    // AutoSync retry-eligibility hook for ExportManager. Reads from
    // AutoSyncManager.currentRetryState — kept up-to-date by the manager
    // after every .recordRetryFailures effect and on destination change.
    // Plan §"Retry and Failure Policy": retry evaluation belongs at
    // enqueue time. `[weak asm]` so the closure doesn't keep the manager
    // alive past app teardown.
    em.autoSyncEligibilityCheck = { [weak asm] assetId, placement, variant, now in
      guard let asm else { return true }
      let scope = AutoSyncManager.retryScopeKey(for: placement)
      guard
        let entry = asm.currentRetryState.entry(
          scope: scope, assetId: assetId, variant: variant)
      else { return true }
      // Hard category (nextEligibleAt == nil) means user-action-required;
      // not eligible to auto-retry.
      guard let nextEligibleAt = entry.nextEligibleAt else { return false }
      return nextEligibleAt <= now
    }

    _exportDestinationManager = StateObject(wrappedValue: edm)
    _photoLibraryManager = StateObject(wrappedValue: plm)
    _exportRecordStore = StateObject(wrappedValue: ers)
    _collectionExportRecordStore = StateObject(wrappedValue: cers)
    _exportManager = StateObject(wrappedValue: em)
    _lifecycleCoordinator = StateObject(wrappedValue: coordinator)
    _autoSyncManager = StateObject(wrappedValue: asm)
    _autoSyncScopeStore = StateObject(wrappedValue: scopeStore)
    _loginItemController = StateObject(wrappedValue: LoginItemController())
    _whatsNewState = StateObject(wrappedValue: WhatsNewState())
    _destinationSafetyMonitor = StateObject(wrappedValue: safetyMonitor)
    self.autoSyncDestinationAdapter = destinationAdapter
    _autoSyncPhotoChangeAdapter = StateObject(wrappedValue: photoAdapter)
    self.autoSyncDirtyStateStore = dirtyStore
    self.autoSyncRetryStateStore = retryStore
    self.autoSyncRunSummaryStore = runSummaryStore
    self.autoSyncPerDestinationTokenStore = perDestinationTokenStore
    self.autoSyncClock = clock
  }

  var body: some Scene {
    // Empty title hides the inline "Photo Export" text from the unified
    // toolbar so the toolbar reads as one row of controls. macOS-level
    // UIs that need a window name (Window menu, Dock tooltip, Mission
    // Control) fall back to the bundle's display name from Info.plist,
    // so the app is still identified as "Photo Export" everywhere it
    // matters outside the chrome.
    WindowGroup("") {
      ContentView()
        .recordStoreAlertHost()
        .environmentObject(exportDestinationManager)
        .environmentObject(photoLibraryManager)
        .environmentObject(exportManager)
        .environmentObject(exportRecordStore)
        .environmentObject(collectionExportRecordStore)
        .environmentObject(autoSyncManager)
        .environmentObject(autoSyncScopeStore)
        .environmentObject(autoSyncPhotoChangeAdapter)
        .environmentObject(exportManager.progressState)
        .environmentObject(whatsNewState)
        .task {
          // First-touch PhotoKit here, not in App.init. Issue #92: the prior
          // shape called `PHPhotoLibrary.shared().register(self)` and the
          // authorization probe inside `PhotoLibraryManager.init`, before any
          // window had rendered. On macOS 15.7+ that synchronous singleton
          // init has been observed to hang launch (PhotoKit's first call
          // touches accountsd/TCC paths). Moving it into `.task` keeps the
          // launch path UI-responsive even if PhotoKit takes a moment.
          // Idempotent under scene recreation; a no-op under tests + screenshot
          // mode.
          photoLibraryManager.start()
          lifecycleCoordinator.attach(
            initial: DestinationIdentitySnapshot(
              fingerprint: exportDestinationManager.destinationFingerprint),
            fingerprintPublisher: exportDestinationManager.$destinationFingerprint
              .eraseToAnyPublisher()
          )
          // Skip the entire AutoSync wiring in screenshot mode. The
          // `PhotoLibraryPersistentChangeAdapter.start()` call further down
          // triggers the system Photos permission prompt — `currentChangeToken`
          // and `register(self)` both touch PhotoKit even though `PhotoLibraryManager`'s
          // own observer registration is skipped. Screenshot mode is a
          // marketing-capture mode that doesn't need AutoSync; gate the
          // attach + start so the run is permission-free.
          if !PhotoLibraryManager.isRunningInScreenshotMode {
            // Wire AutoSync after the lifecycle coordinator so the
            // destination snapshot adapter sees the initial migration-conflict
            // state on first emission. AutoSyncManager.attach is idempotent;
            // the photo change adapter is a no-op until Photos authorization.
            let environment = AutoSyncEnvironment(
              exportRunner: exportManager,
              destination: autoSyncDestinationAdapter,
              scopes: autoSyncScopeStore,
              photos: autoSyncPhotoChangeAdapter,
              importing: exportManager,
              dirtyStateStore: autoSyncDirtyStateStore,
              retryStateStore: autoSyncRetryStateStore,
              runSummaryStore: autoSyncRunSummaryStore,
              perDestinationTokenStore: autoSyncPerDestinationTokenStore,
              clock: autoSyncClock,
              userDefaults: .standard
            )
            autoSyncManager.attach(to: environment)
            autoSyncPhotoChangeAdapter.start()
          }
          // Phase 0b: monitor begins observing destination changes and
          // running the safety scan against the active destination's
          // contents. Attached after lifecycleCoordinator so the record
          // stores have been configure(for:)d for the current destination
          // before the monitor reads their counts.
          destinationSafetyMonitor.attach()
          applyScreenshotWindowSizeIfRequested()
        }
    }
    // Default sized so the sidebar (~240) + content grid (~560) + detail
    // (~480) all fit at their ideal widths set in `LibraryRootView.body`.
    // The user can resize either column past these defaults; new windows
    // start at this size.
    .defaultSize(width: 1280, height: 800)
    .commands {
      CommandGroup(replacing: .appInfo) {
        AboutCommand()
      }
      CommandGroup(after: .importExport) {
        ImportBackupCommand()
      }
      CommandGroup(after: .help) {
        SaveDiagnosticReportCommand(
          timelineStore: exportRecordStore,
          collectionStore: collectionExportRecordStore,
          destinationManager: exportDestinationManager)
      }
      // Sidebar select-all wired through the standard Edit menu so the shortcut
      // (Cmd+A) is discoverable. The action's behavior changes per section —
      // years for Timeline, top-level rows for Collections — and the label
      // adapts via the published `SelectAllSidebarItemsAction`. Disabled (and
      // grayed) when no sidebar is focused; macOS's default "Select All" still
      // fires on text fields and any other first responder that handles it.
      CommandGroup(after: .pasteboard) {
        SelectAllSidebarItemsCommand()
      }
    }

    Window("About Photo Export", id: "about") {
      AboutView()
    }
    .windowResizability(.contentSize)
    .windowStyle(.hiddenTitleBar)

    MenuBarExtra {
      AutoSyncMenuBarContent()
        .environmentObject(autoSyncManager)
        .environmentObject(autoSyncScopeStore)
        .environmentObject(exportDestinationManager)
    } label: {
      AutoSyncMenuBarLabel(state: autoSyncManager.state)
    }

    Settings {
      TabView {
        AutoExportSettingsView()
          .tabItem { Label("Auto Export", systemImage: "arrow.triangle.2.circlepath") }
        ExportIssuesView()
          .tabItem { Label("Export Issues", systemImage: "exclamationmark.triangle") }
      }
      .environmentObject(autoSyncManager)
      .environmentObject(autoSyncScopeStore)
      .environmentObject(exportDestinationManager)
      .environmentObject(exportManager)
      .environmentObject(lifecycleCoordinator)
      .environmentObject(loginItemController)
      .environmentObject(destinationSafetyMonitor)
      .environmentObject(autoSyncPhotoChangeAdapter)
    }
    .windowResizability(.contentMinSize)
  }

  /// When `--screenshot-mode` includes width/height arguments, resize the main
  /// window after launch so the capture script can grab a predictable frame. No-op
  /// in production. Args read once on first appearance; subsequent calls are
  /// idempotent because the resize is to the same size.
  @MainActor
  private func applyScreenshotWindowSizeIfRequested() {
    guard PhotoLibraryManager.isRunningInScreenshotMode else { return }
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
      // No requested size — still publish the window id so the capture
      // script can grab whatever window the system gives us.
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
    // After the resize settles, publish the window's CGWindowID to a
    // well-known temp file. The capture script reads it and calls
    // `screencapture -l<windowID>` — pixel-exact, no coordinate math, works
    // regardless of which display the window lives on (matters on multi-
    // display setups where a rect-based capture against the wrong screen
    // would grab the wallpaper). This avoids needing AppleScript / System
    // Events / Accessibility — only Screen Recording.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      Self.publishScreenshotWindowID()
    }
  }

  /// Writes the main window's CGWindowID to
  /// `$TMPDIR/photo-export-screenshot-window-id.txt` as a single integer
  /// line. Removed if no window is available. Called only in screenshot mode.
  @MainActor
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

  /// Returns `<App Support>/<bundle-id>/AutoSync/` as the root for AutoSync persistence.
  /// Mirrors the pattern in `ExportRecordStore.init` so all per-bundle state lands
  /// under the same parent. The directory itself is created lazily by the individual
  /// stores (dirty/retry stores create per-destination subfolders; the token store
  /// creates the parent on first save).
  static func autoSyncDirectoryURL() -> URL {
    let appSupport = try! FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let bundleId = Bundle.main.bundleIdentifier ?? "com.valtteriluoma.photo-export"
    return
      appSupport
      .appendingPathComponent(bundleId, isDirectory: true)
      .appendingPathComponent("AutoSync", isDirectory: true)
  }

  /// Runs the per-destination directory coordinator (Phase 0 lazy migration) and then
  /// reconfigures both record stores. The coordinator runs **once** per destination change,
  /// before either store touches the directory, so the legacy `<oldId>` → `<newId>` rename
  /// happens exactly once and neither store can race the other to create `<newId>/`
  /// (which would orphan the legacy directory).
  ///
  /// Static so `AppLifecycleCoordinator` can call it from a closure captured at app-init time
  /// without holding a reference to `PhotoExportApp` (which is a struct value type recreated by
  /// SwiftUI on every body evaluation).
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
    // volumeIdentifier-based digest (introduced in Phase 0 collections, replaced in
    // auto-sync Phase 0a) is the most recent pre-upgrade form, so it ranks above the
    // even older bookmark-hash form. High-confidence drives have only the bookmark-
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

private struct AboutCommand: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("About Photo Export") {
      openWindow(id: "about")
    }
  }
}

// MARK: - Import Backup Command

struct ImportBackupAction {
  let callAsFunction: () -> Void
}

struct ImportBackupActionKey: FocusedValueKey {
  typealias Value = ImportBackupAction
}

extension FocusedValues {
  var importBackupAction: ImportBackupAction? {
    get { self[ImportBackupActionKey.self] }
    set { self[ImportBackupActionKey.self] = newValue }
  }
}

private struct ImportBackupCommand: View {
  @FocusedValue(\.importBackupAction) private var importAction

  var body: some View {
    Button("Import Existing Backup\u{2026}") {
      importAction?.callAsFunction()
    }
    .keyboardShortcut("i", modifiers: [.command, .shift])
    .disabled(importAction == nil)
  }
}

// MARK: - Save Diagnostic Report Command

/// Help-menu item. Owns its dependencies directly so the menu item stays
/// enabled regardless of which scene is focused — previously this lived
/// behind a `@FocusedValue` published from `LibraryRootView`, which made
/// the menu item grey out when the user opened Settings, opened About, or
/// closed the main window. Diagnostic reports don't need the library
/// window — just the three stores below and a save panel.
@MainActor
private struct SaveDiagnosticReportCommand: View {
  let timelineStore: ExportRecordStore
  let collectionStore: CollectionExportRecordStore
  let destinationManager: ExportDestinationManager

  var body: some View {
    Button("Save Diagnostic Report\u{2026}") {
      SaveDiagnosticReportCommand.saveDiagnosticReport(
        timelineStore: timelineStore,
        collectionStore: collectionStore,
        destinationManager: destinationManager)
    }
  }

  /// Build the report from the current store snapshots and prompt for a save
  /// location. `nonisolated` would be nice for symmetry with `DiagnosticReporter`,
  /// but `NSSavePanel.runModal()` must run on the main thread and the stores
  /// are `@MainActor`.
  fileprivate static func saveDiagnosticReport(
    timelineStore: ExportRecordStore,
    collectionStore: CollectionExportRecordStore,
    destinationManager: ExportDestinationManager
  ) {
    let info = Bundle.main.infoDictionary
    let appVersion = (info?["CFBundleShortVersionString"] as? String) ?? "?"
    let buildNumber = (info?["CFBundleVersion"] as? String) ?? "?"
    let reporter = DiagnosticReporter(
      timelineStore: timelineStore,
      collectionStore: collectionStore,
      destinationId: destinationManager.destinationId,
      appVersion: appVersion,
      buildNumber: buildNumber
    )
    let report = reporter.makeReport()
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    let stamp = ISO8601DateFormatter().string(from: Date())
      .replacingOccurrences(of: ":", with: "-")
    panel.nameFieldStringValue = "photo-export-diagnostic-\(stamp).txt"
    panel.canCreateDirectories = true
    panel.title = "Save Diagnostic Report"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try report.write(to: url, atomically: true, encoding: .utf8)
    } catch {
      let alert = NSAlert()
      alert.messageText = "Could not save diagnostic report"
      alert.informativeText = error.localizedDescription
      alert.alertStyle = .warning
      alert.runModal()
    }
  }
}

// MARK: - Sidebar Select-All Command

/// Action published by `LibraryRootView` so the Edit menu can drive the sidebar's
/// "select every visible top-level row" gesture. The label is context-aware
/// (timeline vs collections) so the Edit menu reads "Select All Years" or
/// "Select All Collections" depending on which sidebar is active. `nil` means
/// no sidebar is on-screen and the menu item should be disabled — macOS's
/// default Edit → Select All still fires on text fields and similar first
/// responders.
struct SelectAllSidebarItemsAction {
  let label: String
  let callAsFunction: () -> Void
}

struct SelectAllSidebarItemsActionKey: FocusedValueKey {
  typealias Value = SelectAllSidebarItemsAction
}

extension FocusedValues {
  var selectAllSidebarItemsAction: SelectAllSidebarItemsAction? {
    get { self[SelectAllSidebarItemsActionKey.self] }
    set { self[SelectAllSidebarItemsActionKey.self] = newValue }
  }
}

private struct SelectAllSidebarItemsCommand: View {
  @FocusedValue(\.selectAllSidebarItemsAction) private var action

  var body: some View {
    Button(action?.label ?? "Select All Sidebar Items") {
      action?.callAsFunction()
    }
    .keyboardShortcut("a", modifiers: .command)
    .disabled(action == nil)
  }
}
