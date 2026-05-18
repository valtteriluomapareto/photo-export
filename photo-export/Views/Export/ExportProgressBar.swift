import SwiftUI

/// Persistent, full-width progress strip that lives between the toolbar
/// and the NavigationSplitView content area.
///
/// Why this lives outside the toolbar: macOS's toolbar overflow logic
/// pushes whole `ToolbarItem`s into the `≫` menu when the toolbar is too
/// narrow to fit them all, with no per-item-priority hook. A progress
/// indicator that only shows up while you're hovering an overflow menu
/// is worse than no indicator — the user can't tell if anything is
/// happening. Anchoring the bar to the window via `safeAreaInset` means
/// it survives every toolbar overflow state and any sidebar/detail
/// width.
///
/// The bar auto-hides when there is no work and no transient empty-run
/// message. While hidden it occupies zero height — the content area
/// keeps its full real estate when the queue is idle.
struct ExportProgressBar: View {
  @EnvironmentObject private var exportManager: ExportManager
  /// Read frequently-mutating progress state from a dedicated observable so the
  /// per-asset filename / per-job counter updates don't fan out as
  /// `ExportManager.objectWillChange` storms across every observing view (sidebar,
  /// year/month grids, etc.). See `ExportProgressState` for the rationale.
  @EnvironmentObject private var progressState: ExportProgressState

  var body: some View {
    Group {
      if progressState.totalJobsEnqueued > 0 {
        VStack(alignment: .leading, spacing: 0) {
          if let warning = progressState.queueWarningMessage {
            queueWarningBanner(message: warning)
          }
          progressContent
        }
      } else if let message = progressState.emptyRunMessage {
        emptyRunBanner(message: message)
      }
    }
    .animation(.default, value: progressState.totalJobsEnqueued > 0)
    .animation(.default, value: progressState.emptyRunMessage)
    .animation(.default, value: progressState.queueWarningMessage)
  }

  /// Persistent warning rendered above the progress strip when an enqueue partially
  /// failed and the queue is now draining what got through. The progress bar still
  /// shows the subset; this row tells the user *why* the run is partial.
  private func queueWarningBanner(message: String) -> some View {
    HStack(alignment: .center, spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundColor(.orange)
        .font(.caption)
      Text(message)
        .font(.caption)
        .foregroundColor(.secondary)
        .lineLimit(2)
        .truncationMode(.tail)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.bar)
    .overlay(alignment: .bottom) {
      Divider()
    }
    .transition(.move(edge: .top).combined(with: .opacity))
  }

  // MARK: - Active progress

  private var progressContent: some View {
    let total = progressState.totalJobsEnqueued
    let done = progressState.totalJobsCompleted
    let fraction = total > 0 ? Double(done) / Double(total) : 0

    return HStack(alignment: .center, spacing: 12) {
      ProgressView(value: fraction)
        .progressViewStyle(.linear)
        .frame(maxWidth: 240)
        .layoutPriority(2)

      Text("\(done)/\(total) assets")
        .font(.caption)
        .monospacedDigit()
        .fixedSize()
        .layoutPriority(2)
        .help(progressCountTooltip)

      currentAssetLabel
        .layoutPriority(1)

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.bar)
    .overlay(alignment: .bottom) {
      Divider()
    }
    .transition(.move(edge: .top).combined(with: .opacity))
  }

  /// Filename + render-activity hint. The hint is a separate Text so it
  /// stays visible when the filename middle-truncates.
  private var currentAssetLabel: some View {
    HStack(alignment: .center, spacing: 4) {
      Text(progressState.currentAssetFilename ?? "")
        .font(.caption)
        .foregroundColor(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      if let hint = renderActivityHint {
        Text(hint)
          .font(.caption)
          .foregroundColor(.secondary)
          .lineLimit(1)
          .fixedSize()
      }
    }
    .accessibilityLabel(accessibilityCurrentAssetLabel)
  }

  private var renderActivityHint: String? {
    switch progressState.renderActivity {
    case .none: return nil
    case .downloading: return "(downloading…)"
    case .rendering: return "(rendering…)"
    }
  }

  private var accessibilityCurrentAssetLabel: String {
    let filename = progressState.currentAssetFilename ?? ""
    switch progressState.renderActivity {
    case .none:
      return filename.isEmpty ? "" : "Currently exporting \(filename)"
    case .downloading:
      return filename.isEmpty
        ? "Downloading from iCloud" : "Downloading \(filename) from iCloud"
    case .rendering:
      return filename.isEmpty ? "Rendering edited video" : "Rendering edited \(filename)"
    }
  }

  private var progressCountTooltip: String {
    switch exportManager.versionSelection {
    case .editedWithOriginals:
      return
        "Counts assets, not files. Each adjusted asset writes both an edited file and a "
        + "_orig companion but counts once. The filename is whichever file is currently "
        + "being written."
    case .edited:
      return
        "Counts assets. The filename is the file currently being written for the asset "
        + "in progress."
    }
  }

  // MARK: - Empty-run banner

  /// Transient confirmation rendered when the user clicked Export
  /// Month/Year/All against a library that's already complete. Same
  /// shape as the toolbar version it replaced — a checkmark plus the
  /// message — so the click never feels dead.
  private func emptyRunBanner(message: String) -> some View {
    HStack(alignment: .center, spacing: 8) {
      Image(systemName: "checkmark.circle.fill")
        .foregroundColor(.green)
        .font(.caption)
      Text(message)
        .font(.caption)
        .foregroundColor(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.bar)
    .overlay(alignment: .bottom) {
      Divider()
    }
    .transition(.move(edge: .top).combined(with: .opacity))
  }
}
