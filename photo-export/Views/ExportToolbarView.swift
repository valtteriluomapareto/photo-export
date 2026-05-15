import SwiftUI

struct ExportToolbarView: ToolbarContent {
  @EnvironmentObject private var exportManager: ExportManager
  @EnvironmentObject private var exportDestinationManager: ExportDestinationManager
  @EnvironmentObject private var autoSyncManager: AutoSyncManager

  /// Drives the primary action button's label and target. Timeline shows
  /// "Export All"; Collections shows "Export All Albums" by default and flips to
  /// "Export Folder" or "Export N Items" depending on the multi-selection shape.
  /// The pause/cancel buttons are shared because the underlying queue is shared.
  let section: LibrarySection
  /// Current sidebar multi-selection. The toolbar normalizes this into per-section
  /// dispatch buckets at action time. Empty set → the section's "Export All" path.
  let selectionSet: Set<LibrarySelection>
  /// Most-recently-clicked item, surfaced from `LibraryRootView`. Used for the
  /// single-select fast path (1 item → existing per-kind start methods) so we
  /// preserve the existing "Export Month" / "Export Album" labels and dispatch.
  let focusedSelection: LibrarySelection?
  /// Recursive album count under the selected folder, if any. `nil` for non-folder
  /// or multi-item selections. Used so the primary-action label can read
  /// "Export 12 Albums" instead of just "Export Folder".
  var folderAlbumCount: Int?

  @EnvironmentObject private var photoLibraryManager: PhotoLibraryManager

  var body: some ToolbarContent {
    ToolbarItem(placement: .automatic) {
      destinationIndicator
    }

    ToolbarItem(placement: .automatic) {
      AutoSyncStatusPill(state: autoSyncManager.state)
    }

    ToolbarItem(placement: .automatic) {
      formatMenu
    }

    ToolbarItem(placement: .primaryAction) {
      primaryActions
    }
  }

  // MARK: - Format menu

  /// Houses export-shape options that were previously inline toolbar items. As
  /// the toolbar grew, having "Include originals" sit as a peer to the primary
  /// `Export All` button competed for visual weight against the action that's
  /// the entire reason this app exists. A `Menu` keeps the affordance one click
  /// away without eating prime real estate.
  private var formatMenu: some View {
    Menu {
      Toggle(isOn: $exportManager.includeOriginals) {
        Label("Include originals for edited photos", systemImage: "doc.on.doc")
      }
      .disabled(exportManager.hasActiveExportWork)
    } label: {
      // `Label` rather than a custom `HStack { Image(...) }` so the toolbar's
      // "Icon and Text" customization mode can render "Format" beneath the
      // glyph. The accent dot for "an option is on" overlays via
      // `Image(systemName:).symbolVariant(.fill)` swap on the trailing badge.
      Label("Format", systemImage: "slider.horizontal.3")
    }
    // `.menuIndicator(.hidden)` removes the chevron — the slider glyph is the
    // affordance, and the chevron crowds the icon in the limited toolbar space.
    .menuIndicator(.hidden)
    .help(includeOriginalsHelp)
    .accessibilityLabel("Format options")
    .accessibilityHint(
      "Toggle Include originals to keep an unedited copy of photos that have edits in Photos."
    )
    // Overlay the accent dot when at least one option is on — at-a-glance
    // state feedback without inlining the full toggle. Mirrors how Photos /
    // Mail toolbars indicate "you've changed a default here." Sits outside
    // the `Label` so it doesn't interfere with "Icon and Text" mode text.
    .overlay(alignment: .topTrailing) {
      if exportManager.includeOriginals {
        Circle()
          .fill(Color.accentColor)
          .frame(width: 6, height: 6)
          .offset(x: 2, y: -2)
      }
    }
  }

  private var includeOriginalsHelp: String {
    if exportManager.hasActiveExportWork {
      return "Available after the current export finishes."
    }
    switch exportManager.versionSelection {
    case .edited:
      return
        "Each photo is exported once, in the version Photos shows. "
        + "Turn on to also keep an original-bytes copy alongside edited photos."
    case .editedWithOriginals:
      return
        "Edited photos export both the user-visible version and a _orig companion "
        + "with the original bytes."
    }
  }

  // MARK: - Destination Indicator

  /// One clickable item: an icon-coloured status glyph plus the destination
  /// folder name, tap opens the folder picker. The previous design rendered
  /// four visual elements (drive icon, "Destination" caption, filename,
  /// standalone "Change…" button) for one job. Consolidation matches the way
  /// Finder + Mail surface destination/account selectors — single button, full
  /// path in the tooltip.
  @ViewBuilder
  private var destinationIndicator: some View {
    if let url = exportDestinationManager.selectedFolderURL {
      Button {
        exportDestinationManager.selectFolder()
      } label: {
        HStack(alignment: .center, spacing: 6) {
          Image(systemName: destinationIconName)
            .foregroundColor(destinationIconColor)
          Text(url.lastPathComponent)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 180, alignment: .leading)
        }
      }
      .buttonStyle(.bordered)
      .help("Destination: \(url.path) — click to change")
    } else {
      Button("Select Export Folder\u{2026}") {
        exportDestinationManager.selectFolder()
      }
      .buttonStyle(.bordered)
    }
  }

  private var destinationIconName: String {
    exportDestinationManager.isAvailable && exportDestinationManager.isWritable
      ? "externaldrive.fill" : "externaldrive.badge.exclamationmark"
  }

  private var destinationIconColor: Color {
    exportDestinationManager.isAvailable && exportDestinationManager.isWritable
      ? .green : .yellow
  }

  // MARK: - Primary Actions

  @State private var isShowingSupersedeConfirm = false

  private var primaryActions: some View {
    // Internal spacing 12pt rather than 8pt — closer to macOS's default
    // between-button spacing in system toolbars (Mail/Finder/Notes). 8pt
    // packs the pause + cancel glyphs flush against the prominent Export
    // All button; 12pt gives them room to read as separate controls.
    HStack(alignment: .center, spacing: 12) {
      Button(primaryActionLabel) {
        handlePrimaryAction()
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .tint(.accentColor)
      .keyboardShortcut("e", modifiers: .command)
      .disabled(!isPrimaryActionEnabled)
      .help(primaryActionHelpText)
      .confirmationDialog(
        "Auto Export is running",
        isPresented: $isShowingSupersedeConfirm,
        titleVisibility: .visible
      ) {
        Button("Run \(primaryActionLabel) Now", role: .destructive) {
          exportManager.supersedeForManualRun()
          startManualExport()
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(
          "Auto Export is currently running. Cancel it and run your manual export instead? Any in-progress file finishes; any remaining queued items stay pending and Auto Export will resume once your manual run completes."
        )
      }

      // Pause + Cancel are conditional: they exist only when there's an
      // active or pausable export. The previous design used `.opacity(0)` to
      // reserve toolbar space so the layout wouldn't shift when state changed,
      // but the toolbar's "Icon and Text" customization mode renders an item's
      // text caption regardless of opacity — so an invisible Pause icon was
      // leaving a ghost "Pause" caption underneath Export All. Conditionally
      // rendering avoids that at the cost of a small reflow when an export
      // starts (pause/cancel slide in from Export All's right). The reflow is
      // bounded to the trailing-edge primaryAction position and only happens
      // on state transitions a user just triggered, so it reads as feedback
      // rather than jitter.
      if exportManager.canTogglePause {
        Button {
          if exportManager.isPaused {
            exportManager.resume()
          } else {
            exportManager.pause()
          }
        } label: {
          Label(
            exportManager.isPaused ? "Resume" : "Pause",
            systemImage: exportManager.isPaused ? "play.fill" : "pause.fill")
        }
        .help(exportManager.isPaused ? "Resume export" : "Pause export")
      }

      if exportManager.hasActiveExportWork {
        Button {
          exportManager.cancelAndClear()
        } label: {
          Label("Cancel", systemImage: "xmark.circle")
        }
        .help("Cancel and clear queue")
      }
    }
  }

  /// Manual exports stay clickable while an AutoSync run is in flight per
  /// plan §"Phase 4" ("Keep manual export actions enabled while Auto Export
  /// is on"). Disabled only when a *manual* run is already going, when
  /// import is running, or when the destination isn't writable.
  private var isPrimaryActionEnabled: Bool {
    guard exportDestinationManager.canExportNow, !exportManager.isImporting else {
      return false
    }
    // hasActiveExportWork = true && activeRunContext?.source == .autoSync
    // means AutoSync is running — we WANT the button clickable so the
    // confirmation sheet can fire. Disable only when a non-autoSync run
    // (fire-and-forget manual or .manual-sourced runExport) is in flight.
    let manualOrUnknownInFlight =
      exportManager.hasActiveExportWork
      && exportManager.activeRunContext?.source != .autoSync
    return !manualOrUnknownInFlight
  }

  private func handlePrimaryAction() {
    if exportManager.activeRunContext?.source == .autoSync {
      isShowingSupersedeConfirm = true
    } else {
      startManualExport()
    }
  }

  private func startManualExport() {
    switch section {
    case .timeline:
      let timelineItems = selectionSet.filter(\.isTimeline)
      if timelineItems.count >= 2 {
        let buckets = TimelineSelectionBuckets.normalize(timelineItems)
        exportManager.startExportTimelineSelection(
          years: buckets.years, months: buckets.months)
        return
      }
      // 0 or 1 items selected — preserve existing single-select dispatch.
      switch focusedSelection {
      case .timelineYear(let year):
        exportManager.startExportYear(year: year)
      case .timelineMonth(let year, let month):
        // With exactly one month selected, "Export All" still reads "Export Month";
        // calling startExportMonth keeps the existing per-month dispatch + messaging.
        // When zero is selected, we fall through to startExportAll.
        if timelineItems.count == 1 {
          exportManager.startExportMonth(year: year, month: month)
        } else {
          exportManager.startExportAll()
        }
      default:
        exportManager.startExportAll()
      }
    case .collections:
      let collectionItems = selectionSet.filter(\.isCollection)
      if collectionItems.count >= 2 {
        let buckets = CollectionsSelectionBuckets.normalize(collectionItems) { folderId in
          let tree = (try? photoLibraryManager.fetchCollectionTree()) ?? []
          guard let folder = PhotoCollectionDescriptor.findFolder(id: folderId, in: tree)
          else { return [] }
          return PhotoCollectionDescriptor.albumLocalIds(under: folder)
        }
        exportManager.startExportCollectionsSelection(buckets)
        return
      }
      switch focusedSelection {
      case .folder(let id):
        exportManager.startExportFolder(folderId: id)
      case .sharedAlbum(let id):
        // Shared albums aren't included in `startExportAllAlbums` (their reduced-
        // fidelity bytes and per-album export action are an opt-in surface). Route
        // the toolbar primary action to the single-album call so a user staring at
        // a shared-album pane doesn't see the batch button silently skip what
        // they're looking at.
        exportManager.startExportSharedAlbum(collectionId: id)
      case .album(let id) where collectionItems.count == 1:
        exportManager.startExportAlbum(collectionId: id)
      case .favorites where collectionItems.count == 1:
        exportManager.startExportFavorites()
      default:
        exportManager.startExportAllAlbums()
      }
    }
  }

  private var primaryActionLabel: String {
    switch section {
    case .timeline:
      let timelineItems = selectionSet.filter(\.isTimeline)
      if timelineItems.count >= 2 {
        let buckets = TimelineSelectionBuckets.normalize(timelineItems)
        return "Export \(buckets.count) \(buckets.count == 1 ? "Item" : "Items")"
      }
      if case .timelineYear = focusedSelection, timelineItems.count == 1 {
        return "Export Year"
      }
      if case .timelineMonth = focusedSelection, timelineItems.count == 1 {
        return "Export Month"
      }
      return "Export All"
    case .collections:
      let collectionItems = selectionSet.filter(\.isCollection)
      if collectionItems.count >= 2 {
        // Multi-select wins over the per-kind label so the toolbar advertises the
        // batch action. Folder expansion is deferred to dispatch time.
        return "Export \(collectionItems.count) Items"
      }
      if case .folder = focusedSelection {
        // Show the album count when known so the toolbar's label tracks the
        // in-pane button. Falls back to "Export Folder" when the count is
        // unavailable (e.g. tree not yet cached) rather than misreporting "0".
        guard let count = folderAlbumCount, count > 0 else { return "Export Folder" }
        return count == 1 ? "Export 1 Album" : "Export \(count) Albums"
      }
      if case .sharedAlbum = focusedSelection { return "Export Shared Album" }
      if case .album = focusedSelection, collectionItems.count == 1 {
        return "Export Album"
      }
      if case .favorites = focusedSelection, collectionItems.count == 1 {
        return "Export Favorites"
      }
      return "Export All Albums"
    }
  }

  private var primaryActionHelpText: String {
    guard exportDestinationManager.canExportNow else {
      return "Select a writable export folder first"
    }
    let multiCount: Int = {
      switch section {
      case .timeline: return selectionSet.filter(\.isTimeline).count
      case .collections: return selectionSet.filter(\.isCollection).count
      }
    }()
    if multiCount >= 2 {
      switch section {
      case .timeline:
        return
          "Export every photo across the selected years and months. Years cover their months — selecting a year and a month inside it exports the whole year."
      case .collections:
        return
          "Export every photo in the selected collections. Selected folders are expanded to their nested albums; Favorites and shared albums are included if selected."
      }
    }
    let isFolderSelection: Bool = {
      if case .folder = focusedSelection { return true }
      return false
    }()
    let isSharedAlbumSelection: Bool = {
      if case .sharedAlbum = focusedSelection { return true }
      return false
    }()
    if isSharedAlbumSelection {
      // The "Include originals" toggle is a no-op for shared albums; surface that
      // here so the version-selection state doesn't read as a contradiction.
      return
        "Export every photo in this shared album. iCloud only provides downscaled "
        + "JPEGs for shared photos; Include originals is ignored."
    }
    switch (section, exportManager.versionSelection, isFolderSelection) {
    case (.timeline, .edited, _):
      return
        "Export every photo in the timeline (year/month) view, in the version Photos shows."
    case (.timeline, .editedWithOriginals, _):
      return
        "Export every photo in the timeline (year/month) view, plus a _orig companion "
        + "for any photo edited in Photos."
    case (.collections, .edited, true):
      return
        "Export every photo in every album under the selected folder, in the version "
        + "Photos shows."
    case (.collections, .editedWithOriginals, true):
      return
        "Export every photo in every album under the selected folder, plus a _orig "
        + "companion for any photo edited in Photos."
    case (.collections, .edited, false):
      return
        "Export every user album, including albums nested in folders, in the version "
        + "Photos shows. Favorites and shared albums are excluded — use the Export "
        + "Favorites or Export Shared Album button on their pane."
    case (.collections, .editedWithOriginals, false):
      return
        "Export every user album, including albums nested in folders, plus a _orig "
        + "companion for any photo edited in Photos. Favorites and shared albums are "
        + "excluded — use the Export Favorites or Export Shared Album button on their "
        + "pane."
    }
  }

}
