import SwiftUI

/// Button wrapper that mirrors the toolbar's "supersede an active AutoSync run"
/// confirmation for any in-pane manual export action (Export Year, Export Month,
/// Export Folder, Export Album). Without this, the in-pane buttons silently
/// enqueued onto the AutoSync queue, while pressing the toolbar's Cmd+E surfaced
/// the supersede dialog — an inconsistency the user reported.
///
/// Behavior:
/// - If `ExportManager.activeRunContext?.source == .autoSync`, presents the same
///   confirmation dialog the toolbar uses. On "Run X Now" the action proceeds via
///   `supersedeForManualRun` so AutoSync yields to the manual run.
/// - Otherwise dispatches the action immediately.
///
/// The wrapper owns its own `@EnvironmentObject ExportManager` subscription. It's
/// a tiny view (single Button + dialog config), so the per-`objectWillChange`
/// re-render cost is negligible — the heavy LazyVGrid sitting *above* this button
/// is insulated by its parent's `.equatable()` modifier.
struct AutoSyncAwareExportButton<Label: View>: View {
  @EnvironmentObject private var exportManager: ExportManager

  /// Short verb-phrase used in the dialog's "Run X Now" confirm button. Should
  /// match the visible label (e.g. "Export Year", "Export 3 Albums").
  let actionName: String
  /// What to dispatch on confirm (or immediately if AutoSync isn't running).
  let action: () -> Void
  @ViewBuilder let label: () -> Label

  @State private var isShowingSupersedeConfirm = false

  init(
    actionName: String,
    action: @escaping () -> Void,
    @ViewBuilder label: @escaping () -> Label
  ) {
    self.actionName = actionName
    self.action = action
    self.label = label
  }

  var body: some View {
    Button(action: dispatch, label: label)
      .confirmationDialog(
        "Auto Export is running",
        isPresented: $isShowingSupersedeConfirm,
        titleVisibility: .visible
      ) {
        Button("Run \(actionName) Now", role: .destructive) {
          exportManager.supersedeForManualRun()
          action()
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(
          "Auto Export is currently running. Cancel it and run your manual export instead? Any in-progress file finishes; any remaining queued items stay pending and Auto Export will resume once your manual run completes."
        )
      }
  }

  private func dispatch() {
    if exportManager.manualExportShouldConfirmSupersede {
      isShowingSupersedeConfirm = true
    } else {
      action()
    }
  }
}

/// Convenience overload for the common "plain text label" case so call sites
/// don't have to spell out the `label:` view builder.
extension AutoSyncAwareExportButton where Label == Text {
  init(_ title: String, action: @escaping () -> Void) {
    self.init(actionName: title, action: action) { Text(title) }
  }
}
