import SwiftUI

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

  @State private var section: LibrarySection = .timeline
  @State private var selection: LibrarySelection? = .timelineMonth(
    year: Calendar.current.component(.year, from: Date()),
    month: Calendar.current.component(.month, from: Date())
  )

  /// Last selection per section so flipping the segmented control returns the user to
  /// where they were. Updated whenever `selection` changes within a section.
  @State private var lastTimelineSelection: LibrarySelection? = .timelineMonth(
    year: Calendar.current.component(.year, from: Date()),
    month: Calendar.current.component(.month, from: Date())
  )
  @State private var lastCollectionsSelection: LibrarySelection?

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
      sidebar: { sidebar },
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
      ExportToolbarView(section: section)
    }
    .sheet(isPresented: $isShowingImportSheet) {
      ImportView()
        .environmentObject(exportManager)
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
        case .favorites, .album:
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
    .frame(minWidth: 900, minHeight: 600)
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
    switch section {
    case .timeline:
      TimelineSidebarView(selection: $selection, photoLibraryService: photoLibraryManager)
    case .collections:
      CollectionsSidebarView(selection: $selection)
    }
  }

  @ViewBuilder
  private var contentArea: some View {
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

  /// Looks up the album's display title from the cached collection tree. Falls back to
  /// "Album" when the tree hasn't been built yet — the next sidebar fetch will populate
  /// the title via the placement metadata anyway.
  private func albumTitle(forCollectionId id: String) -> String {
    let tree = (try? photoLibraryManager.fetchCollectionTree()) ?? []
    return findTitle(forCollectionId: id, in: tree) ?? "Album"
  }

  private func findTitle(forCollectionId id: String, in tree: [PhotoCollectionDescriptor])
    -> String?
  {
    for descriptor in tree {
      if descriptor.kind == .album, descriptor.localIdentifier == id {
        return descriptor.title
      }
      if let found = findTitle(forCollectionId: id, in: descriptor.children) {
        return found
      }
    }
    return nil
  }
}
