import SwiftUI

struct ExportToolbarView: ToolbarContent {
  @EnvironmentObject private var exportManager: ExportManager
  @EnvironmentObject private var exportDestinationManager: ExportDestinationManager
  @EnvironmentObject private var autoSyncManager: AutoSyncManager

  /// Drives the primary action button's label and target. Timeline shows
  /// "Export All"; Collections shows "Export All Albums". The pause/cancel buttons
  /// are shared because the underlying queue is shared.
  let section: LibrarySection

  var body: some ToolbarContent {
    ToolbarItem(placement: .automatic) {
      destinationIndicator
    }

    ToolbarItem(placement: .automatic) {
      AutoSyncStatusPill(state: autoSyncManager.state)
    }

    ToolbarItem(placement: .automatic) {
      includeOriginalsToggle
    }

    ToolbarItem(placement: .automatic) {
      primaryActions
    }
  }

  // MARK: - Include-originals toggle

  private var includeOriginalsToggle: some View {
    // Explicit HStack rather than `Label(...)` so the icon and text always
    // render side-by-side (mirroring the Destination indicator's layout) and
    // the toolbar's "Icon Only" customization mode can't strip the label —
    // both pieces are part of the view content, not adaptive to display mode.
    Toggle(isOn: $exportManager.includeOriginals) {
      HStack(alignment: .center, spacing: 6) {
        Image(
          systemName: exportManager.includeOriginals
            ? "doc.on.doc.fill" : "doc.on.doc"
        )
        Text("Include originals")
          .font(.callout)
      }
    }
    .toggleStyle(.button)
    .tint(.accentColor)
    .disabled(exportManager.hasActiveExportWork)
    .help(includeOriginalsHelp)
    .accessibilityLabel("Include originals for edited photos")
    .accessibilityHint(
      "Off by default. Turn on to keep original-bytes copies alongside edited photos."
    )
    .padding(.trailing, 16)
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

  @ViewBuilder
  private var destinationIndicator: some View {
    if let url = exportDestinationManager.selectedFolderURL {
      HStack(alignment: .center, spacing: 8) {
        Image(
          systemName: exportDestinationManager.isAvailable
            && exportDestinationManager.isWritable
            ? "externaldrive.fill" : "externaldrive.badge.exclamationmark"
        )
        .foregroundColor(
          exportDestinationManager.isAvailable && exportDestinationManager.isWritable
            ? .green : .yellow)

        // Two-row label gives this custom toolbar item a visible title that
        // mirrors what system buttons get for free in "Icon and Text" mode.
        VStack(alignment: .leading, spacing: 1) {
          Text("Destination")
            .font(.caption2)
            .foregroundColor(.secondary)
          Text(url.lastPathComponent)
            .font(.callout)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(url.path)
        }
        .frame(maxWidth: 140, alignment: .leading)

        Button("Change\u{2026}") {
          exportDestinationManager.selectFolder()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
      }
      // Inter-item spacing: 16pt past the system default. Matches the
      // trailing padding on `includeOriginalsToggle` so adjacent items
      // breathe consistently. The right-most item (`primaryActions`)
      // doubles this for window-edge spacing.
      .padding(.trailing, 16)
    } else {
      Button("Select Export Folder\u{2026}") {
        exportDestinationManager.selectFolder()
      }
      .buttonStyle(.bordered)
    }
  }

  // MARK: - Primary Actions

  @State private var isShowingSupersedeConfirm = false

  private var primaryActions: some View {
    HStack(alignment: .center, spacing: 8) {
      Button(primaryActionLabel) {
        handlePrimaryAction()
      }
      .buttonStyle(.borderedProminent)
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
    // Right-most toolbar item: pad twice the inter-item spacing so
    // the cancel button doesn't sit flush against the window edge.
    .padding(.trailing, 32)
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
      exportManager.startExportAllAlbums()
    }
  }

  private var primaryActionLabel: String {
    switch section {
    case .timeline: return "Export All"
    case .collections: return "Export All Albums"
    }
  }

  private var primaryActionHelpText: String {
    guard exportDestinationManager.canExportNow else {
      return "Select a writable export folder first"
    }
    switch (section, exportManager.versionSelection) {
    case (.timeline, .edited):
      return
        "Export every photo in the timeline (year/month) view, in the version Photos shows."
    case (.timeline, .editedWithOriginals):
      return
        "Export every photo in the timeline (year/month) view, plus a _orig companion "
        + "for any photo edited in Photos."
    case (.collections, .edited):
      return
        "Export every user album, including albums nested in folders, in the version "
        + "Photos shows. Favorites is excluded — use the Export Favorites button on its "
        + "pane."
    case (.collections, .editedWithOriginals):
      return
        "Export every user album, including albums nested in folders, plus a _orig "
        + "companion for any photo edited in Photos. Favorites is excluded — use the "
        + "Export Favorites button on its pane."
    }
  }

}
