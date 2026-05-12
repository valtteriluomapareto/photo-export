import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Top-level layout for the authorized state. Hosts the segmented Timeline/Collections
/// selector above a `NavigationSplitView`. The sidebar swaps between
/// `TimelineSidebarView` and `CollectionsSidebarView` based on the active section; the
/// content + detail panes render the selected scope.
struct LibraryRootView: View {
  @EnvironmentObject private var photoLibraryManager: PhotoLibraryManager
  @EnvironmentObject private var exportManager: ExportManager
  @EnvironmentObject private var exportDestinationManager: ExportDestinationManager
  @EnvironmentObject private var exportRecordStore: ExportRecordStore
  @EnvironmentObject private var collectionExportRecordStore: CollectionExportRecordStore
  @EnvironmentObject private var whatsNewState: WhatsNewState

  @State private var section: LibrarySection
  @State private var selection: LibrarySelection?

  /// Last selection per section so flipping the segmented control returns the user to
  /// where they were. Updated whenever `selection` changes within a section.
  @State private var lastTimelineSelection: LibrarySelection?
  @State private var lastCollectionsSelection: LibrarySelection?

  init() {
    // Honour `--screenshot-surface=<key>` so the capture script can land each
    // marketing capture on a specific view without UI scripting. In production
    // launches the arg is absent and the defaults below match the pre-launch-arg
    // behaviour (Timeline / current month).
    let surface = Self.requestedScreenshotSurface()
    let now = Date()
    let currentYear = Calendar.current.component(.year, from: now)
    let currentMonth = Calendar.current.component(.month, from: now)
    let defaultTimeline: LibrarySelection = .timelineMonth(year: currentYear, month: currentMonth)
    let initialSection = surface?.section ?? .timeline
    let initialSelection = surface?.selection ?? defaultTimeline
    _section = State(initialValue: initialSection)
    _selection = State(initialValue: initialSelection)
    _lastTimelineSelection = State(
      initialValue: initialSection == .timeline ? initialSelection : defaultTimeline)
    _lastCollectionsSelection = State(
      initialValue: initialSection == .collections ? initialSelection : nil)
  }

  /// Reads `--screenshot-surface=<key>` from launch args and resolves it to an
  /// initial `(section, selection)` for screenshot captures. Returns `nil` for
  /// production launches (no matching arg) so the defaults below apply.
  ///
  /// Supported keys:
  ///   - `timeline`                  : Timeline section, current month
  ///   - `collections-favorites`     : Collections section, Favorites view
  ///   - `collections-album-family`  : Collections section, Family album
  ///   - `collections-album-porvoo`  : Collections section, Porvoo album
  ///   - `collections-folder-trips`  : Collections section, Trips folder (folder grid)
  ///   - `collections-album-london`  : Collections section, London album (under Trips)
  ///   - `collections-album-paris`   : Collections section, Paris album (under Trips)
  private static func requestedScreenshotSurface() -> (
    section: LibrarySection, selection: LibrarySelection
  )? {
    guard let raw = ProcessInfo.processInfo.arguments.first(where: {
      $0.hasPrefix("--screenshot-surface=")
    }) else { return nil }
    let key = String(raw.split(separator: "=", maxSplits: 1).last ?? "")
    switch key {
    case "timeline":
      let now = Date()
      return (
        .timeline,
        .timelineMonth(
          year: Calendar.current.component(.year, from: now),
          month: Calendar.current.component(.month, from: now))
      )
    case "collections-favorites":
      return (.collections, .favorites)
    case "collections-album-family":
      return (.collections, .album(collectionId: "family"))
    case "collections-album-porvoo":
      return (.collections, .album(collectionId: "porvoo"))
    case "collections-folder-trips":
      return (.collections, .folder(collectionId: "trips"))
    case "collections-album-london":
      return (.collections, .album(collectionId: "london"))
    case "collections-album-paris":
      return (.collections, .album(collectionId: "paris"))
    default:
      return nil
    }
  }

  @State private var selectedAsset: AssetDescriptor?

  /// Mirrors `ContentView`'s onboarding gate. The new home for it after the refactor.
  @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false

  // Import sheet
  @State private var isShowingImportSheet: Bool = false

  private var canImport: Bool {
    hasCompletedOnboarding && photoLibraryManager.isAuthorized
      && exportDestinationManager.canImportNow && !exportManager.hasActiveExportWork
      && !exportManager.isImporting
  }

  var body: some View {
    NavigationSplitView(
      sidebar: {
        sidebar
      },
      content: {
        // Persistent progress strip sits above the content column only —
        // not above the sidebar, where it would visually attach to the
        // year/month tree it has nothing to do with. Using
        // `safeAreaInset` here means the inset auto-collapses to zero
        // height when the bar is hidden, so an idle queue gives the
        // grid its full real estate back.
        contentArea
          .safeAreaInset(edge: .top, spacing: 0) {
            ExportProgressBar()
          }
      },
      detail: {
        AssetDetailView(asset: selectedAsset)
          .environmentObject(photoLibraryManager)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    )
    .toolbar {
      ToolbarItem(placement: .navigation) {
        sectionPicker
      }
      ExportToolbarView(
        section: section, selection: selection, folderAlbumCount: selectedFolderAlbumCount)
    }
    .sheet(isPresented: $isShowingImportSheet) {
      ImportView()
        .environmentObject(exportManager)
    }
    // First launch on a new app version shows a brief "What's New" sheet
    // explaining new UI surfaces and reassuring the user about file safety.
    // Attached here (not on `ContentView`) so it only renders post-auth /
    // post-onboarding, when the user is in the main library view. The
    // sheet's @Published `shouldShow` flips to false on dismiss, so the
    // binding doesn't re-present.
    .sheet(
      isPresented: Binding(
        get: { whatsNewState.shouldShow },
        set: { newValue in
          if !newValue { whatsNewState.markAsSeen() }
        }
      )
    ) {
      WhatsNewView(state: whatsNewState)
    }
    .onChange(of: selection) { _, newValue in
      // Track the last selection within each section so the segmented switch restores
      // it. Asset selection clears on any section change because the new section's
      // assets are a different set. Both branches are guarded against `nil` writes
      // (which can come from the segmented-switch transition itself or from List's
      // selection model swallowing empty-area clicks): nil should not clobber the
      // last-known per-section selection — preserving it is exactly the point of
      // tracking it.
      switch section {
      case .timeline:
        if case .timelineMonth = newValue {
          lastTimelineSelection = newValue
        }
      case .collections:
        switch newValue {
        case .favorites, .album, .folder:
          lastCollectionsSelection = newValue
        case .timelineMonth, .none:
          break  // ignore — only collection-shaped values count for this section
        }
      }
      selectedAsset = nil
    }
    .focusedSceneValue(
      \.importBackupAction,
      canImport
        ? ImportBackupAction {
          isShowingImportSheet = true
          exportManager.startImport()
        } : nil
    )
    .focusedSceneValue(
      \.saveDiagnosticReportAction,
      SaveDiagnosticReportAction { saveDiagnosticReport() }
    )
    // Window min must fit: sidebar min (220) + content min (480) + ~300pt
    // for the detail pane to render a useful asset preview.
    .frame(minWidth: 1100, minHeight: 700)
    .background(Color(.windowBackgroundColor))
  }

  // MARK: - Diagnostic report

  private func saveDiagnosticReport() {
    let info = Bundle.main.infoDictionary
    let appVersion = (info?["CFBundleShortVersionString"] as? String) ?? "?"
    let buildNumber = (info?["CFBundleVersion"] as? String) ?? "?"
    let reporter = DiagnosticReporter(
      timelineStore: exportRecordStore,
      collectionStore: collectionExportRecordStore,
      destinationId: exportDestinationManager.destinationId,
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

  // MARK: - Section picker

  private var sectionPicker: some View {
    Picker("Library section", selection: $section) {
      Text("Timeline").tag(LibrarySection.timeline)
      Text("Collections").tag(LibrarySection.collections)
    }
    .pickerStyle(.segmented)
    .frame(width: 220)
    .onChange(of: section) { _, newSection in
      switch newSection {
      case .timeline:
        selection =
          lastTimelineSelection
          ?? .timelineMonth(
            year: Calendar.current.component(.year, from: Date()),
            month: Calendar.current.component(.month, from: Date())
          )
      case .collections:
        // First flip to Collections defaults to Favorites instead of nil. Favorites is
        // always present (synthetic — no underlying PHAssetCollection required) and the
        // most common entry point; landing on a blank "Select a collection" pane on the
        // first switch felt broken to users in review.
        selection = lastCollectionsSelection ?? .favorites
      }
      selectedAsset = nil
    }
  }

  // MARK: - Sidebar / content branching

  @ViewBuilder
  private var sidebar: some View {
    Group {
      switch section {
      case .timeline:
        TimelineSidebarView(selection: $selection, photoLibraryService: photoLibraryManager)
      case .collections:
        CollectionsSidebarView(selection: $selection)
      }
    }
    // Sidebar shows "Photos by Year" + album titles without truncation at
    // ~240pt. Min ≈ ideal so AppKit's persisted NSSplitView dividers can't
    // collapse the sidebar back to its old narrow default; max caps the
    // runaway resize so the content grid stays primary.
    .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 360)
  }

  @ViewBuilder
  private var contentArea: some View {
    contentSwitch
      // ~520pt fits ~4 thumbnail columns at the 100–160pt adaptive tile
      // size. Min is just narrower than 3 columns so the grid never
      // collapses to a single column; max caps so a wide window still
      // leaves room for the detail pane.
      .navigationSplitViewColumnWidth(min: 480, ideal: 520, max: 900)
  }

  @ViewBuilder
  private var contentSwitch: some View {
    switch selection {
    case .timelineMonth(let year, let month):
      MonthContentView(
        year: year, month: month,
        selectedAsset: $selectedAsset,
        photoLibraryService: photoLibraryManager
      )
      .environmentObject(photoLibraryManager)
      .frame(maxWidth: .infinity, maxHeight: .infinity)

    case .favorites:
      CollectionContentView(
        selection: .favorites, title: "Favorites",
        selectedAsset: $selectedAsset,
        photoLibraryService: photoLibraryManager
      )
      .environmentObject(photoLibraryManager)
      .frame(maxWidth: .infinity, maxHeight: .infinity)

    case .album(let collectionId):
      CollectionContentView(
        selection: .album(collectionId: collectionId),
        title: albumTitle(forCollectionId: collectionId),
        selectedAsset: $selectedAsset,
        photoLibraryService: photoLibraryManager
      )
      .environmentObject(photoLibraryManager)
      .frame(maxWidth: .infinity, maxHeight: .infinity)

    case .folder(let collectionId):
      FolderContentView(
        folderId: collectionId,
        title: folderTitle(forCollectionId: collectionId),
        selection: $selection,
        selectedAsset: $selectedAsset,
        photoLibraryService: photoLibraryManager
      )
      .environmentObject(photoLibraryManager)
      .frame(maxWidth: .infinity, maxHeight: .infinity)

    case nil:
      VStack {
        Spacer()
        Text(section == .timeline ? "Select a month" : "Select a collection")
          .foregroundColor(.gray)
        Spacer()
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  /// Recursive album count under the currently-selected folder, or `nil` when the
  /// active selection isn't a folder. Drives the toolbar's primary-action label so
  /// "Export Folder" can render as "Export N Albums" — matching the in-pane button.
  private var selectedFolderAlbumCount: Int? {
    guard case .folder(let folderId) = selection else { return nil }
    let tree = (try? photoLibraryManager.fetchCollectionTree()) ?? []
    guard let folder = PhotoCollectionDescriptor.findFolder(id: folderId, in: tree) else {
      return nil
    }
    return PhotoCollectionDescriptor.albumLocalIds(under: folder).count
  }

  /// Looks up the album's display title from the cached collection tree. Falls back to
  /// "Album" when the tree hasn't been built yet — the next sidebar fetch will populate
  /// the title via the placement metadata anyway.
  private func albumTitle(forCollectionId id: String) -> String {
    let tree = (try? photoLibraryManager.fetchCollectionTree()) ?? []
    return findTitle(kind: .album, id: id, in: tree) ?? "Album"
  }

  private func folderTitle(forCollectionId id: String) -> String {
    let tree = (try? photoLibraryManager.fetchCollectionTree()) ?? []
    return findTitle(kind: .folder, id: id, in: tree) ?? "Folder"
  }

  private func findTitle(
    kind: PhotoCollectionDescriptor.Kind, id: String,
    in tree: [PhotoCollectionDescriptor]
  ) -> String? {
    for descriptor in tree {
      if descriptor.kind == kind, descriptor.localIdentifier == id {
        return descriptor.title
      }
      if let found = findTitle(kind: kind, id: id, in: descriptor.children) {
        return found
      }
    }
    return nil
  }
}
