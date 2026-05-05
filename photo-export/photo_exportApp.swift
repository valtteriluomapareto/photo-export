//
//  photo_exportApp.swift
//  photo-export
//
//  Created by Valtteri Luoma on 22.4.2025.
//

import SwiftUI

@main
struct PhotoExportApp: App {
  @StateObject private var exportDestinationManager: ExportDestinationManager
  @StateObject private var photoLibraryManager: PhotoLibraryManager
  @StateObject private var exportRecordStore: ExportRecordStore
  @StateObject private var collectionExportRecordStore: CollectionExportRecordStore
  @StateObject private var exportManager: ExportManager

  init() {
    // Initialize dependencies locally, then assign to stored properties and StateObjects
    let edm = ExportDestinationManager()
    let plm = PhotoLibraryManager()
    let ers = ExportRecordStore()
    let cers = CollectionExportRecordStore()
    _exportDestinationManager = StateObject(wrappedValue: edm)
    _photoLibraryManager = StateObject(wrappedValue: plm)
    _exportRecordStore = StateObject(wrappedValue: ers)
    _collectionExportRecordStore = StateObject(wrappedValue: cers)
    _exportManager = StateObject(
      wrappedValue: ExportManager(
        photoLibraryService: plm, exportDestination: edm, exportRecordStore: ers,
        collectionExportRecordStore: cers))
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
          // Configure store for current destination (if any) at launch
          configureRecordStore(for: exportDestinationManager.destinationId)
        }
        .onChange(of: exportDestinationManager.destinationId) { _, newId in
          // Cancel any in-flight exports and reconfigure the per-destination store
          exportManager.cancelAndClear()
          configureRecordStore(for: newId)
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
  private func configureRecordStore(for newId: String?) {
    guard let newId else {
      exportRecordStore.configure(for: nil)
      collectionExportRecordStore.configure(for: nil)
      return
    }
    let coordinator = ExportRecordsDirectoryCoordinator(
      storeRootURL: exportRecordStore.storeRootURL)
    let result = coordinator.prepareDirectory(
      for: newId,
      legacyId: exportDestinationManager.currentLegacyDestinationId()
    )
    switch result {
    case .success, .failure(.conflict):
      // Either the migration succeeded or `<newId>/` already exists with `<oldId>/` left
      // for inspection. Either way, configuring is safe — both stores adopt whatever's at
      // `<newId>/`. Coordinator already logged the conflict case.
      exportRecordStore.configure(for: newId)
      collectionExportRecordStore.configure(for: newId)
    case .failure(.migrationFailed):
      // Transient I/O error during the legacy → new rename. `<legacyId>/` still has the
      // user's records; `<newId>/` does not exist yet. Configuring `for: newId` would
      // create `<newId>/` and trip the conflict-detection branch on every subsequent
      // launch, permanently stranding the legacy records. Leave both stores unconfigured;
      // next launch (or the next destinationId change) retries the rename.
      exportRecordStore.configure(for: nil)
      collectionExportRecordStore.configure(for: nil)
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
