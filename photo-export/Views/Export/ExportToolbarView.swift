import SwiftUI

struct ExportToolbarView: ToolbarContent {
  @Environment(ExportManager.self) private var exportManager
  @EnvironmentObject private var exportDestinationManager: ExportDestinationManager
  @EnvironmentObject private var autoSyncManager: AutoSyncManager
  #if DEBUG
    @Environment(\.bodyInvalidationCounter) private var bodyCounter
  #endif

  /// Drives the primary action button's label and target. Timeline shows
  /// "Export All"; Collections shows "Export All Albums" by default and flips to
  /// "Export Folder" or "Export N Items" depending on the multi-selection shape.
  /// The pause/cancel buttons are shared because the underlying queue is shared.
  let section: LibrarySection
  /// Current sidebar multi-selection. The toolbar normalizes this into per-section
  /// dispatch buckets at action time. Empty set → the section's "Export All" path.
  let selectionSet: Set<LibrarySelection>
  /// Most-recently-clicked item, surfaced from `LibraryRootView`. Used so the
  /// shared-album single-select case keeps its per-item label and dispatch.
  /// The global Export All Albums action excludes shared albums and would skip it.
  let focusedSelection: LibrarySelection?
  let historyState: RecordStoreState

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
        .modifier(LibraryTreeLoading())
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
    let destinationHelp = exportDestinationManager.destinationHelp
    if let url = exportDestinationManager.selectedFolderURL {
      Button {
        exportDestinationManager.selectFolder()
      } label: {
        HStack(alignment: .center, spacing: 6) {
          Image(systemName: destinationIconName)
            .foregroundColor(destinationIconColor)
            .accessibilityHidden(true)
          Text(url.lastPathComponent)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 180, alignment: .leading)
        }
      }
      .buttonStyle(.bordered)
      .help(destinationHelp)
      .accessibilityLabel(destinationHelp)
    } else {
      Button(
        exportDestinationManager.status == .permissionRequired
          ? "Choose Folder…" : "Select Export Folder…"
      ) {
        exportDestinationManager.selectFolder()
      }
      .buttonStyle(.bordered)
      .help(destinationHelp)
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
    let exportHelp = primaryActionHelpText
    #if DEBUG
      // swiftlint:disable:next redundant_discardable_let
      let _ = bodyCounter?.record("export-toolbar-actions")
    #endif
    // Internal spacing 12pt rather than 8pt — closer to macOS's default
    // between-button spacing in system toolbars (Mail/Finder/Notes). 8pt
    // packs the pause + cancel glyphs flush against the prominent Export
    // All button; 12pt gives them room to read as separate controls.
    return HStack(alignment: .center, spacing: 12) {
      Button(primaryActionLabel) {
        handlePrimaryAction()
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .tint(.accentColor)
      .keyboardShortcut("e", modifiers: .command)
      .accessibilityIdentifier("manual-export-primary")
      .disabled(!isPrimaryActionEnabled)
      .help(exportHelp)
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
          let pauseLabel = exportManager.isPaused ? "Resume" : "Pause"
          Label(
            pauseLabel,
            systemImage: exportManager.isPaused ? "play.fill" : "pause.fill")
        }
        .help(exportManager.isPaused ? "Resume export" : "Pause export")
        .accessibilityLabel(exportManager.isPaused ? "Resume export" : "Pause export")
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
            : "Cancel and clear queue"
        )
        .accessibilityLabel(
          autoSyncManager.isEnabled
            ? "Cancel and clear queue. Also turns Auto Export off."
            : "Cancel and clear queue")
      }
    }
  }

  private var presentation: ManualToolbarPresentation {
    ManualToolbarPresentation(
      section: section, selectionSet: selectionSet, focusedSelection: focusedSelection,
      versionSelection: exportManager.versionSelection,
      availability: ManualExportAvailability(
        destinationCanExport: exportDestinationManager.canExportNow, history: historyState),
      destinationHelp: exportDestinationManager.exportUnavailableHelp,
      isImporting: exportManager.isImporting,
      hasActiveExportWork: exportManager.hasActiveExportWork,
      activeRunSource: exportManager.activeRunContext?.source)
  }

  private var isPrimaryActionEnabled: Bool { presentation.isEnabled }
  private var primaryActionLabel: String { presentation.label }
  private var primaryActionHelpText: String { presentation.help }

  private func handlePrimaryAction() {
    if exportManager.manualExportShouldConfirmSupersede {
      isShowingSupersedeConfirm = true
    } else {
      startManualExport()
    }
  }

  private func startManualExport() {
    switch presentation.action {
    case .timelineAll:
      exportManager.startExportAll()
    case .timelineSelection(let buckets):
      exportManager.startExportTimelineSelection(years: buckets.years, months: buckets.months)
    case .userCollections:
      exportManager.startExportAllUserCollections()
    case .collectionsSelection(let items):
      exportManager.startExportCollectionsSelection(items: items)
    case .sharedAlbum(let id):
      exportManager.startExportSharedAlbum(collectionId: id)
    }
  }
}
