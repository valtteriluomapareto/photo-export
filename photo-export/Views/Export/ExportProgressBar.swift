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
  @Environment(ExportProgressState.self) private var progressState

  #if DEBUG
    @Environment(\.bodyInvalidationCounter) private var counter
  #endif
  @Environment(\.openSettings) private var openSettings
  @AppStorage(SettingsTab.storageKey) private var selectedSettingsTab: SettingsTab = .autoExport
  private let successDelay: @Sendable () async throws -> Void
  private let settingsOpener: (@MainActor () -> Void)?

  init(
    successDelay: @escaping @Sendable () async throws -> Void = {
      try await Task.sleep(for: .seconds(5))
    },
    settingsOpener: (@MainActor () -> Void)? = nil
  ) {
    self.successDelay = successDelay
    self.settingsOpener = settingsOpener
  }

  private func observed(_ message: String) -> String {
    #if DEBUG
      counter?.recordText([message], for: "progress-message")
    #endif
    return message
  }

  private var isVisible: Bool {
    if let summary = progressState.manualSummary { return !summary.isDismissed }
    return progressState.totalJobsEnqueued > 0 || progressState.emptyRunMessage != nil
  }

  var body: some View {
    #if DEBUG
      // swiftlint:disable:next redundant_discardable_let
      let _ = recordVisibility()
    #endif
    Group {
      if let summary = progressState.manualSummary {
        if !summary.isDismissed { terminalSummary(summary) }
      } else if progressState.totalJobsEnqueued > 0 {
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
    .task(id: progressState.manualSummary?.id) {
      guard let summary = progressState.manualSummary,
        !summary.isDismissed, summary.result == .completed
      else { return }
      do { try await successDelay() } catch { return }
      #if DEBUG
        counter?.record("progress-expiry-finished:\(summary.id)")
      #endif
      guard !Task.isCancelled, progressState.manualSummary?.id == summary.id else { return }
      progressState.manualSummary?.isDismissed = true
    }
  }

  #if DEBUG
    private func recordVisibility() {
      counter?.recordText([String(isVisible)], for: "progress-visible")
      if !isVisible { counter?.recordText([], for: "progress-message") }
    }
  #endif

  private func terminalSummary(_ summary: ManualExportSummary) -> some View {
    let dismiss = {
      guard progressState.manualSummary?.id == summary.id else { return }
      progressState.manualSummary?.isDismissed = true
    }
    let showIssues = {
      guard progressState.manualSummary?.id == summary.id,
        progressState.manualSummary?.isDismissed == false
      else { return }
      selectedSettingsTab = .exportIssues
      if let settingsOpener { settingsOpener() } else { openSettings() }
    }
    #if DEBUG
      counter?.recordAction("progress-dismiss", action: dismiss)
      counter?.recordAction("progress-view-issues", action: showIssues)
    #endif
    return VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Image(
          systemName: summary.result == .completed
            ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        )
        .foregroundStyle(summary.result == .completed ? Color.green : .orange)
        Text(observed(summary.message))
        Spacer(minLength: 0)
        if summary.result == .failed { Button("View Issues", action: showIssues) }
        Button("Dismiss", systemImage: "xmark", action: dismiss)
          .labelStyle(.iconOnly)
          .help("Dismiss export summary")
      }
      if let message = summary.failureMessage {
        Text(message).foregroundStyle(.secondary)
      }
    }
    .font(.caption)
    .padding(.horizontal, 16)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    // Keep complete wrapped recovery text at its ideal height. A truncating fitted view
    // can otherwise shrink its window again on each layout pass.
    .fixedSize(horizontal: false, vertical: true)
    .background(.bar)
    .overlay(alignment: .bottom) { Divider() }
  }

  /// Persistent warning rendered above the progress strip when an enqueue partially
  /// failed and the queue is now draining what got through. The progress bar still
  /// shows the subset; this row tells the user *why* the run is partial.
  private func queueWarningBanner(message: String) -> some View {
    HStack(alignment: .center, spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundColor(.orange)
        .font(.caption)
      Text(observed(message))
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

      Text(observed("\(done)/\(total) assets"))
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
      Text(observed(message))
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
