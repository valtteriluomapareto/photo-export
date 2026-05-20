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
  /// Most-recently-clicked item, surfaced from `LibraryRootView`. Used so the
  /// shared-album single-select case can keep its per-item label and
  /// dispatch (issue #91 — shared albums are excluded from the global
  /// "Export All Albums" scope, so flipping the toolbar to a global action
  /// that would silently skip them is actively worse than the per-item
  /// dispatch).
  let focusedSelection: LibrarySelection?

  @EnvironmentObject private var photoLibraryManager: PhotoLibraryManager

  /// macOS 14+ environment action for opening the `Settings` scene. Used by
  /// the toolbar cog button so users have an in-app affordance for Settings
  /// → Advanced (Format options) without having to remember Cmd+,.
  @Environment(\.openSettings) private var openSettings

  var body: some ToolbarContent {
    ToolbarItem(placement: .automatic) {
      destinationIndicator
    }

    ToolbarItem(placement: .automatic) {
      AutoSyncStatusPill(state: autoSyncManager.state)
    }

    ToolbarItem(placement: .automatic) {
      settingsButton
    }

    ToolbarItem(placement: .primaryAction) {
      primaryActions
    }
  }

  // MARK: - Settings cog

  /// In-app entry point to the Settings window. Sits between the AutoSync pill
  /// and the primary action — roughly where the now-removed Format menu used to
  /// live, so muscle memory still finds an affordance there. Opens whichever
  /// tab the user last viewed; the user picks Advanced from inside.
  private var settingsButton: some View {
    Button {
      openSettings()
    } label: {
      Label("Settings", systemImage: "gearshape")
    }
    .help("Settings (\u{2318},)")
    .accessibilityLabel("Settings")
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
          // Cancel ⇒ disable Auto Export. Without this, AutoSync's debounce
          // re-fires within ~30s of a cancelled run (it sees dirty state
          // surviving the cancel and re-schedules), so "Cancel" felt to the
          // user like "pause for 30 seconds." Treating Cancel as "stop, and
          // don't restart automatically" matches the button's plain-language
          // meaning. The user can re-enable Auto Export from Settings.
          autoSyncManager.setEnabled(false)
          exportManager.cancelAndClear()
        } label: {
          Label("Cancel", systemImage: "xmark.circle")
        }
        .help(
          autoSyncManager.isEnabled
            ? "Cancel and clear queue. Also turns Auto Export off."
            : "Cancel and clear queue")
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
    if exportManager.manualExportShouldConfirmSupersede {
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
      // Issue #91: with 0 OR 1 sidebar items selected, the toolbar's primary
      // action is the global "Export All". Single-item dispatch (Export
      // Month, Export Year) remains available via the per-pane button inside
      // `MonthContentView` / `YearContentView`. Without this, selecting any
      // sidebar row hid "Export All" entirely — the original report.
      exportManager.startExportAll()
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
      // Shared albums are the one single-select case that keeps its per-item
      // dispatch: they're excluded from the "Export All Albums" scope (per
      // the iCloud reduced-fidelity caveat), so flipping the toolbar button
      // to a global action that silently skips the user's selection is
      // actively worse than just routing to the single-album call.
      if case .sharedAlbum(let id) = focusedSelection {
        exportManager.startExportSharedAlbum(collectionId: id)
        return
      }
      // Everything else (album, folder, favorites, no selection) routes to a
      // synthesized buckets dispatch that includes Favorites + every user
      // album, skipping shared albums. Per-pane buttons in
      // `CollectionContentView` / `FolderContentView` still expose the
      // single-item action.
      exportManager.startExportCollectionsSelection(allButSharedBuckets())
    }
  }

  /// Builds the synthesized `CollectionsSelectionBuckets` used by the
  /// toolbar's "Export All Albums" dispatch when 0 or 1 collection items are
  /// in the sidebar selection. Includes Favorites and every user album under
  /// the current Photos tree; deliberately excludes shared albums (issue #91
  /// + the iCloud shared-album reduced-fidelity caveat — `startExportAll`-
  /// style actions historically don't cover shared albums on this app).
  private func allButSharedBuckets() -> CollectionsSelectionBuckets {
    let tree = (try? photoLibraryManager.fetchCollectionTree()) ?? []
    let albumIds = PhotoCollectionDescriptor.albumLocalIds(in: tree)
    return CollectionsSelectionBuckets(
      includesFavorites: true, albumIds: albumIds, sharedAlbumIds: [])
  }

  private var primaryActionLabel: String {
    switch section {
    case .timeline:
      let timelineItems = selectionSet.filter(\.isTimeline)
      if timelineItems.count >= 2 {
        let buckets = TimelineSelectionBuckets.normalize(timelineItems)
        return "Export \(buckets.count) \(buckets.count == 1 ? "Item" : "Items")"
      }
      // Issue #91: the toolbar's primary action is the global "Export All"
      // when 0 or 1 sidebar items are selected. Per-pane "Export Month" /
      // "Export Year" buttons handle the single-item action.
      return "Export All"
    case .collections:
      let collectionItems = selectionSet.filter(\.isCollection)
      if collectionItems.count >= 2 {
        // Multi-select wins over the per-kind label so the toolbar advertises the
        // batch action. Folder expansion is deferred to dispatch time.
        return "Export \(collectionItems.count) Items"
      }
      // Shared albums are excluded from the global "Export All Albums" scope;
      // keep the per-item label so a user staring at a shared-album pane
      // doesn't see the toolbar advertise an action that would skip it.
      // Per-pane "Export Album" / "Export Folder" / "Export Favorites"
      // buttons in `CollectionContentView` / `FolderContentView` handle the
      // other single-item actions.
      if case .sharedAlbum = focusedSelection { return "Export Shared Album" }
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
    // Shared album single-select keeps its per-item dispatch (and label).
    if case .sharedAlbum = focusedSelection {
      // The "Include originals" toggle is a no-op for shared albums; surface that
      // here so the version-selection state doesn't read as a contradiction.
      return
        "Export every photo in this shared album. iCloud only provides downscaled "
        + "JPEGs for shared photos; Include originals is ignored."
    }
    switch (section, exportManager.versionSelection) {
    case (.timeline, .edited):
      return
        "Export every photo in the timeline (year/month) view, in the version "
        + "Photos shows. Use the in-pane Export Month or Export Year button "
        + "for a smaller scope."
    case (.timeline, .editedWithOriginals):
      return
        "Export every photo in the timeline (year/month) view, plus a _orig "
        + "companion for any photo edited in Photos. Use the in-pane Export "
        + "Month or Export Year button for a smaller scope."
    case (.collections, .edited):
      return
        "Export Favorites and every user album (including albums nested in "
        + "folders), in the version Photos shows. Shared albums are excluded "
        + "— use the Export Shared Album button on their pane."
    case (.collections, .editedWithOriginals):
      return
        "Export Favorites and every user album (including albums nested in "
        + "folders), plus a _orig companion for any photo edited in Photos. "
        + "Shared albums are excluded — use the Export Shared Album button "
        + "on their pane."
    }
  }

}
