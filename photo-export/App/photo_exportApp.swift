//
//  photo_exportApp.swift
//  photo-export
//
//  Created by Valtteri Luoma on 22.4.2025.
//

import SwiftUI

/// Started by `AppEntry` for normal launches. The object graph lives on `AppCore`; this
/// type holds the core's remaining `ObservableObject`s as `@StateObject`s and lays out the
/// scenes.
struct PhotoExportApp: App {
  private let core: AppCore
  // The core's `ObservableObject`s, held as `@StateObject`s. Its `@Observable` objects
  // (`LoginItemController`, `WhatsNewState`, `ExportProgressState`) need no wrapper: the core
  // keeps them alive and nothing here reads them. Only `autoSyncManager` is read in `body`, for
  // the menu bar label; the other wrappers are dropped in the fixture-mode slice. Scenes get
  // the same instances through `photoExportEnvironment(core)`.
  @StateObject private var exportDestinationManager: ExportDestinationManager
  @StateObject private var photoLibraryManager: PhotoLibraryManager
  @StateObject private var exportRecordStore: ExportRecordStore
  @StateObject private var collectionExportRecordStore: CollectionExportRecordStore
  @StateObject private var exportManager: ExportManager
  @StateObject private var lifecycleCoordinator: AppLifecycleCoordinator
  @StateObject private var autoSyncManager: AutoSyncManager
  @StateObject private var autoSyncScopeStore: UserDefaultsAutoExportScopeStore
  @StateObject private var autoSyncPhotoChangeAdapter: PhotoLibraryPersistentChangeAdapter
  @StateObject private var destinationSafetyMonitor: DestinationSafetyMonitor

  /// Set when the real app is composed; the test host never composes it.
  @MainActor private(set) static var wasComposed = false

  init() {
    Self.wasComposed = true
    AppDiagnostics.beginLaunch()
    // `--screenshot-mode` swaps the real Photos backing for a curated synthetic library so
    // marketing screenshots don't leak the maintainer's personal Photos library. See
    // `docs/project/archive/screenshot-automation-plan.md`.
    let core = AppCore(
      composition: .forLaunch(arguments: ProcessInfo.processInfo.arguments))
    self.core = core
    _exportDestinationManager = StateObject(wrappedValue: core.exportDestinationManager)
    _photoLibraryManager = StateObject(wrappedValue: core.photoLibraryManager)
    _exportRecordStore = StateObject(wrappedValue: core.exportRecordStore)
    _collectionExportRecordStore = StateObject(wrappedValue: core.collectionExportRecordStore)
    _exportManager = StateObject(wrappedValue: core.exportManager)
    _lifecycleCoordinator = StateObject(wrappedValue: core.lifecycleCoordinator)
    _autoSyncManager = StateObject(wrappedValue: core.autoSyncManager)
    _autoSyncScopeStore = StateObject(wrappedValue: core.autoSyncScopeStore)
    _destinationSafetyMonitor = StateObject(wrappedValue: core.destinationSafetyMonitor)
    _autoSyncPhotoChangeAdapter = StateObject(wrappedValue: core.autoSyncPhotoChangeAdapter)
  }

  var body: some Scene {
    // Empty title hides the inline "Photo Export" text from the unified
    // toolbar so the toolbar reads as one row of controls. macOS-level
    // UIs that need a window name (Window menu, Dock tooltip, Mission
    // Control) fall back to the bundle's display name from Info.plist,
    // so the app is still identified as "Photo Export" everywhere it
    // matters outside the chrome.
    WindowGroup("") {
      ContentView(destinationManager: exportDestinationManager, recordStore: exportRecordStore)
        .equatable()
        .recordStoreAlertHost()
        .photoExportEnvironment(core)
        .task {
          // PhotoKit is first touched here, after the window has rendered, not in App.init
          // (#92). Every window runs this; the core starts once.
          core.start()
        }
    }
    // Default sized so the sidebar (240) and content grid (520) sit at their
    // ideal widths set in `LibraryRootView`, leaving ~520 for the detail pane.
    // The user can resize either column past these defaults; new windows
    // start at this size.
    .defaultSize(width: 1280, height: 800)
    // Make the window's minimum track its content minimum explicitly rather
    // than relying on `.automatic`'s implicit resolution, which has shifted
    // across macOS releases (issue #125 surfaced on Tahoe 26.5). Each routed
    // state supplies its own minimum: `LibraryRootView` uses its
    // `minimumWindowSize`, sized to fit a 1024x768 display with the title bar
    // and toolbar, while the first-run states use `firstRunWindowMinSize()`.
    // The library's minimum height (600) is deliberately below the first-run
    // one (640) because its toolbar adds 52pt that the first-run states lack.
    // The window stays freely resizable larger because every state's
    // `maxWidth/maxHeight` is `.infinity`. Mirrors the Settings scene below.
    .windowResizability(.contentMinSize)
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
          destinationManager: exportDestinationManager,
          photoChangeAdapter: autoSyncPhotoChangeAdapter,
          currentRunStore: core.autoSyncEnvironment.currentRunStore)
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
        .photoExportEnvironment(core)
    } label: {
      AutoSyncMenuBarLabel(state: autoSyncManager.state)
    }

    Settings {
      SettingsRootView()
        .photoExportEnvironment(core)
    }
    .windowResizability(.contentMinSize)
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
  let photoChangeAdapter: PhotoLibraryPersistentChangeAdapter
  let currentRunStore: any AutoSyncCurrentRunStore

  var body: some View {
    Button("Save Diagnostic Report\u{2026}") {
      SaveDiagnosticReportCommand.saveDiagnosticReport(
        timelineStore: timelineStore,
        collectionStore: collectionStore,
        destinationManager: destinationManager,
        photoChangeAdapter: photoChangeAdapter,
        currentRunStore: currentRunStore)
    }
  }

  /// Build the report from the current store snapshots and prompt for a save
  /// location. `nonisolated` would be nice for symmetry with `DiagnosticReporter`,
  /// but `NSSavePanel.runModal()` must run on the main thread and the stores
  /// are `@MainActor`.
  fileprivate static func saveDiagnosticReport(
    timelineStore: ExportRecordStore,
    collectionStore: CollectionExportRecordStore,
    destinationManager: ExportDestinationManager,
    photoChangeAdapter: PhotoLibraryPersistentChangeAdapter,
    currentRunStore: any AutoSyncCurrentRunStore
  ) {
    let info = Bundle.main.infoDictionary
    let appVersion = (info?["CFBundleShortVersionString"] as? String) ?? "?"
    let buildNumber = (info?["CFBundleVersion"] as? String) ?? "?"
    // Load the current-run journal at panel-open time for the active
    // destination. Absent destination → no journal (no per-destination
    // store to consult); absent file → no journal section in the report.
    let previousRunJournal = destinationManager.destinationId.flatMap {
      currentRunStore.load(destinationId: $0)
    }
    let reporter = DiagnosticReporter(
      timelineStore: timelineStore,
      collectionStore: collectionStore,
      destinationId: destinationManager.destinationId,
      appVersion: appVersion,
      buildNumber: buildNumber,
      lastCatchUpSummary: photoChangeAdapter.lastCatchUpSummary,
      previousRunJournal: previousRunJournal
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
