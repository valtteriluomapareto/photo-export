import SwiftUI

struct ExportToolbarView: ToolbarContent {
  @EnvironmentObject private var exportManager: ExportManager
  @EnvironmentObject private var exportDestinationManager: ExportDestinationManager
  @EnvironmentObject private var autoSyncManager: AutoSyncManager

  /// Drives the primary action button's label and target. Timeline shows
  /// "Export All"; Collections shows "Export All Albums" by default and flips to
  /// "Export Folder" when the user has a folder selected. The pause/cancel buttons
  /// are shared because the underlying queue is shared.
  let section: LibrarySection
  /// Current sidebar selection. Used only to detect a folder selection so the
  /// primary action can route to `startExportFolder(folderId:)` for that folder.
  let selection: LibrarySelection?
  /// Recursive album count under the selected folder, if any. `nil` for non-folder
  /// selections. Used so the primary-action label can read "Export 12 Albums"
  /// instead of just "Export Folder" — matching the in-pane button's wording so a
  /// user comparing them doesn't see a mismatch.
  var folderAlbumCount: Int?

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
      HStack(spacing: 4) {
        Image(systemName: "slider.horizontal.3")
        // Accent dot when at least one option is on — gives at-a-glance state
        // feedback without inlining the full label. Mirrors how the Photos /
        // Mail toolbars indicate "you've changed a default here."
        if exportManager.includeOriginals {
          Circle()
            .fill(Color.accentColor)
            .frame(width: 6, height: 6)
        }
      }
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .help(includeOriginalsHelp)
    .accessibilityLabel("Format options")
    .accessibilityHint(
      "Toggle Include originals to keep an unedited copy of photos that have edits in Photos."
    )
    .padding(.trailing, 8)
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
    HStack(alignment: .center, spacing: 8) {
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

      Button {
        if exportManager.isPaused {
          exportManager.resume()
        } else {
          exportManager.pause()
        }
      } label: {
        Image(systemName: exportManager.isPaused ? "play.fill" : "pause.fill")
      }
      .help(exportManager.isPaused ? "Resume export" : "Pause export")
      .opacity(exportManager.canTogglePause ? 1 : 0)
      .disabled(!exportManager.canTogglePause)

      Button {
        exportManager.cancelAndClear()
      } label: {
        Image(systemName: "xmark.circle")
      }
      .help("Cancel and clear queue")
      .opacity(exportManager.hasActiveExportWork ? 1 : 0)
      .disabled(!exportManager.hasActiveExportWork)
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
      exportManager.startExportAll()
    case .collections:
      if case .folder(let id) = selection {
        exportManager.startExportFolder(folderId: id)
      } else {
        exportManager.startExportAllAlbums()
      }
    }
  }

  private var primaryActionLabel: String {
    switch section {
    case .timeline: return "Export All"
    case .collections:
      if case .folder = selection {
        // Show the album count when known so the toolbar's label tracks the
        // in-pane button. Falls back to "Export Folder" when the count is
        // unavailable (e.g. tree not yet cached) rather than misreporting "0".
        guard let count = folderAlbumCount, count > 0 else { return "Export Folder" }
        return count == 1 ? "Export 1 Album" : "Export \(count) Albums"
      }
      return "Export All Albums"
    }
  }

  private var primaryActionHelpText: String {
    guard exportDestinationManager.canExportNow else {
      return "Select a writable export folder first"
    }
    let isFolderSelection: Bool = {
      if case .folder = selection { return true }
      return false
    }()
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
        + "Photos shows. Favorites is excluded — use the Export Favorites button on its "
        + "pane."
    case (.collections, .editedWithOriginals, false):
      return
        "Export every user album, including albums nested in folders, plus a _orig "
        + "companion for any photo edited in Photos. Favorites is excluded — use the "
        + "Export Favorites button on its pane."
    }
  }

}
