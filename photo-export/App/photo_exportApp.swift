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
  #if DEBUG
    private let control: ControlRuntime?
  #endif

  private var windowSize: CGSize {
    #if DEBUG
      if let control { return control.options.size }
    #endif
    return CGSize(width: 1280, height: 800)
  }

  private var restoration: SceneRestorationBehavior {
    #if DEBUG
      if control != nil { return .disabled }
    #endif
    return .automatic
  }
  // AppCore owns the shared graph. These wrappers retain its ObservableObject services;
  // Observation owners are injected directly through photoExportEnvironment(core).
  @StateObject private var exportDestinationManager: ExportDestinationManager
  @StateObject private var lifecycleCoordinator: AppLifecycleCoordinator
  @StateObject private var autoSyncManager: AutoSyncManager
  @StateObject private var autoSyncScopeStore: UserDefaultsAutoExportScopeStore
  @StateObject private var destinationSafetyMonitor: DestinationSafetyMonitor

  init() {
    AppDiagnostics.beginLaunch()
    // `--screenshot-mode` swaps the real Photos backing for a curated synthetic library so
    // marketing screenshots don't leak the maintainer's personal Photos library. See
    // scripts/README.md for the capture workflow.
    #if DEBUG
      let control = ControlRuntime.launch
      self.control = control
      let core =
        control?.core
        ?? AppCore(
          composition: .forLaunch(arguments: ProcessInfo.processInfo.arguments))
    #else
      let core = AppCore(composition: .forLaunch(arguments: ProcessInfo.processInfo.arguments))
    #endif
    self.core = core
    _exportDestinationManager = StateObject(wrappedValue: core.exportDestinationManager)
    _lifecycleCoordinator = StateObject(wrappedValue: core.lifecycleCoordinator)
    _autoSyncManager = StateObject(wrappedValue: core.autoSyncManager)
    _autoSyncScopeStore = StateObject(wrappedValue: core.autoSyncScopeStore)
    _destinationSafetyMonitor = StateObject(wrappedValue: core.destinationSafetyMonitor)
  }

  private var menuBar: some Scene {
    #if DEBUG
      if control != nil {
        return MenuBarExtra(isInserted: .constant(false)) {
          menuBarContent
        } label: {
          menuBarLabel
        }
      }
    #endif
    return MenuBarExtra {
      menuBarContent
    } label: {
      menuBarLabel
    }
  }

  private var menuBarContent: some View {
    AutoSyncMenuBarContent().photoExportEnvironment(core)
  }

  private var menuBarLabel: some View {
    AutoSyncMenuBarLabel(state: autoSyncManager.state)
  }

  var body: some Scene {
    // Empty title hides the inline "Photo Export" text from the unified
    // toolbar so the toolbar reads as one row of controls. macOS-level
    // UIs that need a window name (Window menu, Dock tooltip, Mission
    // Control) fall back to the bundle's display name from Info.plist,
    // so the app is still identified as "Photo Export" everywhere it
    // matters outside the chrome.
    WindowGroup("") {
      MainWindowRoot(
        destinationManager: exportDestinationManager, recordStore: core.exportRecordStore
      )
      .recordStoreAlertHost()
      .photoExportEnvironment(core)
      // Store screenshots are a light set whatever the Mac's appearance.
      .preferredColorScheme(core.composition.isScreenshotMode ? .light : nil)
      #if DEBUG
        .background {
          if let control { ControlWindowReader(runtime: control) }
        }
      #endif
      .task {
        #if DEBUG
          if control != nil { return }
        #endif
        // PhotoKit is first touched here, after the window has rendered, not in App.init.
        // Every window runs this; the core starts once.
        core.start()
      }
    }
    // Default sized so the sidebar (240) and content grid (520) sit at their
    // ideal widths set in `LibraryRootView`, leaving ~520 for the detail pane.
    // The user can resize either column past these defaults; new windows
    // start at this size.
    .defaultSize(width: windowSize.width, height: windowSize.height)
    .restorationBehavior(restoration)
    // Make the window's minimum track its content minimum explicitly rather
    // than relying on `.automatic`'s implicit resolution, which has shifted
    // across macOS releases (surfaced on Tahoe 26.5). Each routed
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
          timelineStore: core.exportRecordStore,
          collectionStore: core.collectionExportRecordStore,
          destinationManager: exportDestinationManager,
          photoChangeAdapter: core.autoSyncPhotoChangeAdapter)
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
        #if DEBUG
          .background {
            if let control { ControlWindowReader(runtime: control, publishesWindowNumber: false) }
          }
        #endif
    }
    .windowResizability(.contentSize)
    .windowStyle(.hiddenTitleBar)
    .restorationBehavior(restoration)

    menuBar

    Settings {
      SettingsRootView()
        .photoExportEnvironment(core)
        #if DEBUG
          .background {
            if let control { ControlWindowReader(runtime: control, publishesWindowNumber: false) }
          }
        #endif
    }
    .windowResizability(.contentMinSize)
    .restorationBehavior(restoration)
  }
}

/// Supplies timeline history readiness as a render-time input to the equatable router.
struct MainWindowRoot: View {
  let destinationManager: ExportDestinationManager
  let recordStore: ExportRecordStore
  #if DEBUG
    @Environment(\.bodyInvalidationCounter) private var bodyCounter
  #endif

  var body: some View {
    #if DEBUG
      // swiftlint:disable:next redundant_discardable_let
      let _ = bodyCounter?.record("main-window-root")
    #endif
    ContentView(
      destinationManager: destinationManager, recordStore: recordStore,
      timelineHistoryState: recordStore.state
    ).equatable()
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
  let photoChangeAdapter: PhotoLibraryPersistentChangeAdapter?

  var body: some View {
    Button("Save Diagnostic Report\u{2026}") {
      SaveDiagnosticReportCommand.saveDiagnosticReport(
        timelineStore: timelineStore,
        collectionStore: collectionStore,
        destinationManager: destinationManager,
        photoChangeAdapter: photoChangeAdapter)
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
    photoChangeAdapter: PhotoLibraryPersistentChangeAdapter?
  ) {
    let info = Bundle.main.infoDictionary
    let appVersion = (info?["CFBundleShortVersionString"] as? String) ?? "?"
    let buildNumber = (info?["CFBundleVersion"] as? String) ?? "?"
    let reporter = DiagnosticReporter(
      timelineStore: timelineStore,
      collectionStore: collectionStore,
      destinationId: destinationManager.destinationId,
      appVersion: appVersion,
      buildNumber: buildNumber,
      lastCatchUpSummary: photoChangeAdapter?.lastCatchUpSummary
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
