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

  private let autoSyncDestinationAdapter: DestinationSnapshotAdapter
  private let autoSyncPhotoChangeAdapter: PhotoLibraryPersistentChangeAdapter
  private let autoSyncDirtyStateStore: FileBackedAutoSyncDirtyStateStore
  private let autoSyncRetryStateStore: FileBackedAutoSyncRetryStateStore
  private let autoSyncRunSummaryStore: FileBackedAutoSyncRunSummaryStore
  private let autoSyncPerDestinationTokenStore: FileBackedAutoSyncPerDestinationTokenStore
  private let autoSyncClock: SystemAutoSyncClock

  init() {
    let edm = ExportDestinationManager()
    let plm = PhotoLibraryManager()
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
    let photoAdapter = PhotoLibraryPersistentChangeAdapter(
      tokenStore: tokenStore,
      authorizationStatusPublisher: plm.$authorizationStatus.eraseToAnyPublisher()
    )
    let destinationAdapter = DestinationSnapshotAdapter(
      destinationManager: edm, lifecycleCoordinator: coordinator)
    let scopeStore = UserDefaultsAutoExportScopeStore(userDefaults: .standard)
    let clock = SystemAutoSyncClock()
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
    self.autoSyncDestinationAdapter = destinationAdapter
    self.autoSyncPhotoChangeAdapter = photoAdapter
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
        .task {
          lifecycleCoordinator.attach(
            initial: DestinationIdentitySnapshot(
              fingerprint: exportDestinationManager.destinationFingerprint),
            fingerprintPublisher: exportDestinationManager.$destinationFingerprint
              .eraseToAnyPublisher()
          )
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
    }
    .defaultSize(width: 1100, height: 640)
    .commands {
      CommandGroup(replacing: .appInfo) {
        AboutCommand()
      }
      CommandGroup(after: .importExport) {
        ImportBackupCommand()
      }
      CommandGroup(after: .help) {
        SaveDiagnosticReportCommand()
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
    }
    .windowResizability(.contentMinSize)
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

struct SaveDiagnosticReportAction {
  let callAsFunction: () -> Void
}

struct SaveDiagnosticReportActionKey: FocusedValueKey {
  typealias Value = SaveDiagnosticReportAction
}

extension FocusedValues {
  var saveDiagnosticReportAction: SaveDiagnosticReportAction? {
    get { self[SaveDiagnosticReportActionKey.self] }
    set { self[SaveDiagnosticReportActionKey.self] = newValue }
  }
}

private struct SaveDiagnosticReportCommand: View {
  @FocusedValue(\.saveDiagnosticReportAction) private var action

  var body: some View {
    Button("Save Diagnostic Report\u{2026}") {
      action?.callAsFunction()
    }
    .disabled(action == nil)
  }
}
