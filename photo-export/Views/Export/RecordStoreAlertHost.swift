import AppKit
import SwiftUI

/// Presents one recovery alert at a time. IO failures offer non-destructive Retry;
/// only a corrupt snapshot offers Reset Records. Timeline takes presentation priority.
@MainActor
struct RecordStoreAlertHost: ViewModifier {
  @Environment(ExportRecordStore.self) private var exportRecordStore
  @Environment(CollectionExportRecordStore.self) private var collectionExportRecordStore
  @Environment(ExportManager.self) private var exportManager
  @EnvironmentObject private var exportDestinationManager: ExportDestinationManager
  @Environment(PhotoLibraryManager.self) private var photoLibraryManager
  @State private var isShowingRecoveryImport = false
  @State private var timelineDismissed = false
  @State private var collectionDismissed = false

  func body(content: Content) -> some View {
    timelineAlert(content: content)
      .alert(
        "Photo Export couldn't access collections progress",
        isPresented: collectionAlertBinding,
        actions: {
          if collectionExportRecordStore.state == .persistenceFailed {
            Button("Retry") { Task { await collectionExportRecordStore.retryHistoryPersistence() } }
          } else {
            Button("Reset Records", role: .destructive) {
              Task { await collectionExportRecordStore.resetHistory() }
            }
          }
          Button("Quit") { NSApplication.shared.terminate(nil) }
        },
        message: {
          if collectionExportRecordStore.state == .persistenceFailed {
            Text(storageFailureMessage(collectionExportRecordStore.persistenceError))
          } else {
            Text(collectionResetMessage)
          }
        }
      )
      .onChange(of: exportRecordStore.destinationId) { timelineDismissed = false }
      .onChange(of: collectionExportRecordStore.destinationId) { collectionDismissed = false }
      .onChange(of: exportRecordStore.state) { _, state in
        if state == .ready || state == .unconfigured || state == .failed {
          timelineDismissed = false
        }
      }
      .onChange(of: collectionExportRecordStore.state) { _, state in
        if state == .ready || state == .unconfigured || state == .failed {
          collectionDismissed = false
        }
      }
      .sheet(isPresented: $isShowingRecoveryImport) {
        ImportView()
      }
  }

  private func timelineAlert(content: Content) -> some View {
    content
      .alert(
        "Photo Export couldn't access timeline progress",
        isPresented: timelineAlertBinding,
        actions: {
          if exportRecordStore.state == .persistenceFailed {
            Button("Retry") { Task { await exportRecordStore.retryHistoryPersistence() } }
          } else {
            Button("Reset and Rebuild from Folder…", action: resetAndRebuild)
              .disabled(!canRebuild)
            Button("Reset Records", role: .destructive) {
              Task { await exportRecordStore.resetHistory() }
            }
          }
          Button("Quit") { NSApplication.shared.terminate(nil) }
        },
        message: {
          if exportRecordStore.state == .persistenceFailed {
            Text(storageFailureMessage(exportRecordStore.persistenceError))
          } else {
            Text(timelineResetMessage)
          }
        }
      )
  }

  private var timelineResetMessage: String {
    """
    Your exported photos on disk are safe — only the in-app progress tracking \
    for timeline (year/month) exports is affected. Reset Records moves the \
    broken file aside and leaves tracking empty. Exporting before rebuilding \
    can create duplicate copies. Reset and Rebuild from Folder uses Import \
    Existing Backup to recognize files already in your export folder. \
    If rebuilding is unavailable, restore folder and Photos access and resolve \
    any collection history alert, then use File → Import Existing Backup….
    """
  }

  private var collectionResetMessage: String {
    """
    Your exported photos on disk are safe — only the in-app progress tracking \
    for Favorites and album exports is affected. Reset Records moves the \
    broken file aside and leaves tracking empty. Collection records cannot \
    be rebuilt from disk yet; re-exporting can create duplicate copies. \
    Import Existing Backup rebuilds timeline history only.
    """
  }

  private var canRebuild: Bool {
    photoLibraryManager.isAuthorized && exportDestinationManager.canImportNow
      && !collectionExportRecordStore.state.needsRecovery
      && !exportManager.hasActiveExportWork && !exportManager.isImporting
  }

  private func resetAndRebuild() {
    guard exportRecordStore.state == .failed, canRebuild else { return }
    Task {
      await exportRecordStore.resetHistory {
        guard canRebuild else { return }
        // Claim import in the same turn that recovery publishes an empty ready history.
        exportManager.startImport()
        if exportManager.isImporting { isShowingRecoveryImport = true }
      }
    }
  }

  private func storageFailureMessage(_ detail: String?) -> String {
    "Export progress could not be read or saved. Further exports using these records are blocked. "
      + "Restore storage access or free disk space, then choose Retry to preserve your history. "
      + "Keep the app open until Retry succeeds: recent progress may exist only in memory. "
      + (detail ?? "")
  }

  private var timelineAlertBinding: Binding<Bool> {
    Binding(
      get: { exportRecordStore.state.needsRecovery && !timelineDismissed },
      set: { if !$0 { timelineDismissed = true } }
    )
  }

  private var collectionAlertBinding: Binding<Bool> {
    Binding(
      get: {
        // Only show the collection alert when the timeline alert isn't already active so
        // SwiftUI doesn't try to present two alerts on the same view at once.
        (!exportRecordStore.state.needsRecovery || timelineDismissed)
          && collectionExportRecordStore.state.needsRecovery && !collectionDismissed
      },
      set: { if !$0 { collectionDismissed = true } }
    )
  }
}

extension View {
  /// Attaches the record-store corruption-recovery alert host. See
  /// `RecordStoreAlertHost` for behavior.
  @MainActor
  func recordStoreAlertHost() -> some View {
    modifier(RecordStoreAlertHost())
  }
}
