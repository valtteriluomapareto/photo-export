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

  /// Active multi-select for the current section. Bound into each sidebar via
  /// `List(selection:)`; `focusedSelection` drives the content pane. The pair is
  /// updated atomically in `applySelectionChange` so the content pane never lags
  /// the highlight set.
  @State private var selectionSet: Set<LibrarySelection> = []
  @State private var focusedSelection: LibrarySelection?

  /// Last selection per section so flipping the segmented control returns the user to
  /// where they were — both the highlighted set and which item the content pane was
  /// showing.
  @State private var lastTimeline: PersistedSidebarSelection = .empty
  @State private var lastCollections: PersistedSidebarSelection = .empty

  init() {
    // Honour `--screenshot-surface=<key>` so the capture script can land each
    // marketing capture on a specific view without UI scripting. In production
    // launches the resolver returns `nil` and the defaults below match the
    // pre-launch-arg behaviour (Timeline / current month). The parsing +
    // mapping lives in `ScreenshotSurfaceResolver` so it's testable without
    // instantiating SwiftUI views.
    let surface = ScreenshotSurfaceResolver.resolve()
    let now = Date()
    let currentYear = Calendar.current.component(.year, from: now)
    let currentMonth = Calendar.current.component(.month, from: now)
    let defaultTimeline: LibrarySelection = .timelineMonth(year: currentYear, month: currentMonth)
    let initialSection = surface?.section ?? .timeline
    let initialSelection = surface?.selection ?? defaultTimeline
    // Multi-select screenshot surfaces ship `additionalSelections` so the
    // sidebar highlights more than one row at launch. Empty for every
    // production launch (resolver returns `nil`) and for single-select keys.
    let initialSet: Set<LibrarySelection> = {
      var items: Set<LibrarySelection> = [initialSelection]
      items.formUnion(surface?.additionalSelections ?? [])
      return items
    }()
    _section = State(initialValue: initialSection)
    _selectionSet = State(initialValue: initialSet)
    _focusedSelection = State(initialValue: initialSelection)
    _lastTimeline = State(
      initialValue: initialSection == .timeline
        ? PersistedSidebarSelection(items: initialSet, focused: initialSelection)
        : PersistedSidebarSelection(items: [defaultTimeline], focused: defaultTimeline)
    )
    _lastCollections = State(
      initialValue: initialSection == .collections
        ? PersistedSidebarSelection(items: initialSet, focused: initialSelection)
        : .empty
    )
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
        section: section,
        selectionSet: selectionSet,
        focusedSelection: focusedSelection)
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
        get: {
          // Suppress the What's New sheet in screenshot mode — it would auto-
          // show on first launch after a version bump and ruin every capture.
          !PhotoLibraryManager.isRunningInScreenshotMode && whatsNewState.shouldShow
        },
        set: { newValue in
          if !newValue { whatsNewState.markAsSeen() }
        }
      )
    ) {
      WhatsNewView(state: whatsNewState)
    }
    .onChange(of: selectionSet) { oldSet, newSet in
      applySelectionChange(oldSet: oldSet, newSet: newSet)
    }
    .onChange(of: focusedSelection) { _, newValue in
      selectedAsset = nil
      persistLastSelection()
      let kind: String
      switch newValue {
      case .none: kind = "none"
      case .timelineYear: kind = "year"
      case .timelineMonth: kind = "month"
      case .favorites: kind = "favorites"
      case .album: kind = "album"
      case .sharedAlbum: kind = "sharedAlbum"
      case .folder: kind = "folder"
      }
      AppDiagnostics.selectionChanged(kind: kind)
    }
    .focusedSceneValue(
      \.importBackupAction,
      canImport
        ? ImportBackupAction {
          isShowingImportSheet = true
          exportManager.startImport()
        } : nil
    )
    .focusedSceneValue(\.selectAllSidebarItemsAction, sidebarSelectAllAction)
    // Window min must fit: sidebar min (220) + content min (480) + ~300pt
    // for the detail pane to render a useful asset preview.
    .frame(minWidth: 1100, minHeight: 700)
    .background(Color(.windowBackgroundColor))
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
      restoreSelection(forSection: newSection)
      selectedAsset = nil
    }
  }

  /// Restores the highlighted set + focus for the freshly-active section. Falls back to
  /// the section's natural default (current month for timeline, Favorites for
  /// collections) on first visit. Direct assignment to both pieces of state at once so
  /// `applySelectionChange` doesn't churn through a transient half-restored value.
  private func restoreSelection(forSection newSection: LibrarySection) {
    switch newSection {
    case .timeline:
      if !lastTimeline.items.isEmpty {
        selectionSet = lastTimeline.items
        focusedSelection = lastTimeline.focused ?? lastTimeline.items.first
      } else {
        let now = Date()
        let defaultSel: LibrarySelection = .timelineMonth(
          year: Calendar.current.component(.year, from: now),
          month: Calendar.current.component(.month, from: now)
        )
        selectionSet = [defaultSel]
        focusedSelection = defaultSel
      }
    case .collections:
      // First flip to Collections defaults to Favorites. Favorites is always present
      // (synthetic — no underlying PHAssetCollection required) and the most common
      // entry point; landing on a blank "Select a collection" pane on the first
      // switch felt broken to users in review.
      if !lastCollections.items.isEmpty {
        selectionSet = lastCollections.items
        focusedSelection = lastCollections.focused ?? lastCollections.items.first
      } else {
        selectionSet = [.favorites]
        focusedSelection = .favorites
      }
    }
  }

  /// Applies a sidebar selection change: updates `focusedSelection` based on the
  /// diff via `SidebarFocusReducer` and persists the per-section last-state. The
  /// reducer is pure and unit-tested in `SidebarFocusReducerTests`.
  private func applySelectionChange(
    oldSet: Set<LibrarySelection>, newSet: Set<LibrarySelection>
  ) {
    focusedSelection = SidebarFocusReducer.nextFocus(
      oldSet: oldSet, newSet: newSet, currentFocus: focusedSelection)
    persistLastSelection()
  }

  /// Writes the current `selectionSet`/`focusedSelection` into the per-section slot so
  /// the segmented control's restore path can return the user to where they were.
  /// Filters defensively so a cross-shape value (timeline case in the collections slot
  /// or vice versa) is never persisted.
  private func persistLastSelection() {
    switch section {
    case .timeline:
      let filtered = selectionSet.filter(\.isTimeline)
      let focus = (focusedSelection?.isTimeline == true) ? focusedSelection : filtered.first
      lastTimeline = PersistedSidebarSelection(items: filtered, focused: focus)
    case .collections:
      let filtered = selectionSet.filter(\.isCollection)
      let focus = (focusedSelection?.isCollection == true) ? focusedSelection : filtered.first
      lastCollections = PersistedSidebarSelection(items: filtered, focused: focus)
    }
  }

  // MARK: - Sidebar / content branching

  @ViewBuilder
  private var sidebar: some View {
    Group {
      switch section {
      case .timeline:
        TimelineSidebarView(
          selectionSet: $selectionSet, photoLibraryService: photoLibraryManager)
      case .collections:
        CollectionsSidebarView(selectionSet: $selectionSet)
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
    switch focusedSelection {
    case .timelineYear(let year):
      YearContentView(
        year: year,
        selection: folderNavigationBinding,
        selectedAsset: $selectedAsset,
        photoLibraryService: photoLibraryManager
      )
      .environmentObject(photoLibraryManager)
      .frame(maxWidth: .infinity, maxHeight: .infinity)

    case .timelineMonth(let year, let month):
      // Pass `versionSelection` and `isExportRunning` down as values rather than
      // letting `MonthContentView` subscribe to `ExportManager` directly. The
      // manager fires `objectWillChange` per export job (queueCount sink, etc.);
      // `.equatable()` on a value-comparing `MonthContentView` then short-circuits
      // the LazyVGrid re-evaluation when the rendering inputs are unchanged. Without
      // `.equatable()` the freshly-allocated `onExportMonth` closure per render
      // would defeat SwiftUI's structural diff.
      MonthContentView(
        year: year, month: month,
        versionSelection: exportManager.versionSelection,
        livePhotosPaired: exportManager.livePhotosPairedExport,
        isExportRunning: exportManager.isRunning,
        onExportMonth: { exportManager.startExportMonth(year: year, month: month) },
        selectedAsset: $selectedAsset,
        photoLibraryService: photoLibraryManager
      )
      .equatable()
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

    case .sharedAlbum(let collectionId):
      CollectionContentView(
        selection: .sharedAlbum(collectionId: collectionId),
        title: sharedAlbumTitle(forCollectionId: collectionId),
        selectedAsset: $selectedAsset,
        photoLibraryService: photoLibraryManager
      )
      .environmentObject(photoLibraryManager)
      .frame(maxWidth: .infinity, maxHeight: .infinity)

    case .folder(let collectionId):
      FolderContentView(
        folderId: collectionId,
        title: folderTitle(forCollectionId: collectionId),
        selection: folderNavigationBinding,
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

  /// Single-selection bridge for `FolderContentView`. The folder pane writes through
  /// this binding to navigate when the user clicks an album or sub-folder tile;
  /// replacing both the set and the focus ensures the sidebar's highlight follows.
  private var folderNavigationBinding: Binding<LibrarySelection?> {
    Binding(
      get: { focusedSelection },
      set: { newValue in
        if let newValue {
          selectionSet = [newValue]
          focusedSelection = newValue
        } else {
          selectionSet = []
          focusedSelection = nil
        }
      }
    )
  }

  // MARK: - Sidebar Select-All wiring

  /// Action published into the focused-scene chain so the Edit menu's "Select All"
  /// command can drive the active sidebar. Label is section-aware so the menu reads
  /// "Select All Years" or "Select All Collections" — discoverability beats
  /// per-sidebar hidden keyboard hosts (HIG: Cmd+A belongs in the Edit menu).
  private var sidebarSelectAllAction: SelectAllSidebarItemsAction {
    switch section {
    case .timeline:
      return SelectAllSidebarItemsAction(label: "Select All Years") {
        selectAllTimelineYears()
      }
    case .collections:
      return SelectAllSidebarItemsAction(label: "Select All Collections") {
        selectAllVisibleCollections()
      }
    }
  }

  /// Selects every year currently in the timeline sidebar. Mirrors the previous
  /// hidden-button host that lived in `TimelineSidebarView`; moved up here so the
  /// Edit menu can drive it without a private sidebar API.
  private func selectAllTimelineYears() {
    let years = (try? photoLibraryManager.availableYears()) ?? []
    let yearItems = Set(years.map { LibrarySelection.timelineYear(year: $0) })
    let preserved = selectionSet.filter { !$0.isTimeline }
    selectionSet = yearItems.union(preserved)
  }

  /// Selects every top-level row currently visible in the Collections sidebar
  /// (Favorites + top-level albums/folders + shared albums). Doesn't auto-expand
  /// folders — matches Finder's "select all" scope, which doesn't reach into
  /// closed disclosure groups.
  private func selectAllVisibleCollections() {
    let tree = (try? photoLibraryManager.fetchCollectionTree()) ?? []
    var picked: Set<LibrarySelection> = [.favorites]
    for descriptor in tree {
      guard let localId = descriptor.localIdentifier else { continue }
      switch descriptor.kind {
      case .album: picked.insert(.album(collectionId: localId))
      case .folder: picked.insert(.folder(collectionId: localId))
      case .sharedAlbum: picked.insert(.sharedAlbum(collectionId: localId))
      case .favorites: break
      }
    }
    let preserved = selectionSet.filter { !$0.isCollection }
    selectionSet = picked.union(preserved)
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

  private func sharedAlbumTitle(forCollectionId id: String) -> String {
    let tree = (try? photoLibraryManager.fetchCollectionTree()) ?? []
    return findTitle(kind: .sharedAlbum, id: id, in: tree) ?? "Shared Album"
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
