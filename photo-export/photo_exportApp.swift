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
    let coordinator = AppLifecycleCoordinator(
      cancelActiveWork: { [em] in em.cancelAndClear() },
      interruptForDestinationUnavailable: { [em] in em.interruptForDestinationUnavailable() },
      configureRecordStores: configure
    )

    _exportDestinationManager = StateObject(wrappedValue: edm)
    _photoLibraryManager = StateObject(wrappedValue: plm)
    _exportRecordStore = StateObject(wrappedValue: ers)
    _collectionExportRecordStore = StateObject(wrappedValue: cers)
    _exportManager = StateObject(wrappedValue: em)
    _lifecycleCoordinator = StateObject(wrappedValue: coordinator)
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
        .task {
          lifecycleCoordinator.attach(
            initial: DestinationIdentitySnapshot(
              fingerprint: exportDestinationManager.destinationFingerprint),
            fingerprintPublisher: exportDestinationManager.$destinationFingerprint
              .eraseToAnyPublisher()
          )
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
    let legacyIds = [
      destinationManager.currentLegacyDestinationId(),
      destinationManager.currentPreV2LowConfidenceLegacyId(),
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
