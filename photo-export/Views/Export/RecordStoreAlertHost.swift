import AppKit
import SwiftUI

/// Presents one recovery alert at a time. IO failures offer non-destructive Retry;
/// only a corrupt snapshot offers Reset Records. Timeline takes presentation priority.
struct RecordStoreAlertHost: ViewModifier {
  @EnvironmentObject private var exportRecordStore: ExportRecordStore
  @EnvironmentObject private var collectionExportRecordStore: CollectionExportRecordStore

  func body(content: Content) -> some View {
    content
      .alert(
        "Photo Export couldn't access timeline progress",
        isPresented: timelineAlertBinding,
        actions: {
          if exportRecordStore.state == .persistenceFailed {
            Button("Retry") { exportRecordStore.retryPersistence() }
          } else {
            Button("Reset Records", role: .destructive) { exportRecordStore.resetToEmpty() }
          }
          Button("Quit") { NSApplication.shared.terminate(nil) }
        },
        message: {
          if exportRecordStore.state == .persistenceFailed {
            Text(storageFailureMessage(exportRecordStore.persistenceError))
          } else {
            Text(
              "Your exported photos on disk are safe — only the in-app progress tracking "
                + "for timeline (year/month) exports is affected. Reset Records will move "
                + "the broken file aside and start fresh; the next export run rebuilds the "
                + "records.")
          }
        }
      )
      .alert(
        "Photo Export couldn't access collections progress",
        isPresented: collectionAlertBinding,
        actions: {
          if collectionExportRecordStore.state == .persistenceFailed {
            Button("Retry") { collectionExportRecordStore.retryPersistence() }
          } else {
            Button("Reset Records", role: .destructive) {
              collectionExportRecordStore.resetToEmpty()
            }
          }
          Button("Quit") { NSApplication.shared.terminate(nil) }
        },
        message: {
          if collectionExportRecordStore.state == .persistenceFailed {
            Text(storageFailureMessage(collectionExportRecordStore.persistenceError))
          } else {
            Text(
              "Your exported photos on disk are safe — only the in-app progress tracking "
                + "for Favorites and album exports is affected. Reset Records will move the "
                + "broken file aside and start fresh; the next collection export rebuilds "
                + "the records.")
          }
        }
      )
  }

  private func storageFailureMessage(_ detail: String?) -> String {
    "Export progress could not be read or saved. Further exports using these records are blocked. "
      + "Restore storage access or free disk space, then choose Retry to preserve your history. "
      + "Keep the app open until Retry succeeds: recent progress may exist only in memory. "
      + (detail ?? "")
  }

  private var timelineAlertBinding: Binding<Bool> {
    Binding(
      get: { exportRecordStore.state.needsRecovery },
      set: { _ in }  // dismissal handled by the actions above
    )
  }

  private var collectionAlertBinding: Binding<Bool> {
    Binding(
      get: {
        // Only show the collection alert when the timeline alert isn't already active so
        // SwiftUI doesn't try to present two alerts on the same view at once.
        !exportRecordStore.state.needsRecovery
          && collectionExportRecordStore.state.needsRecovery
      },
      set: { _ in }
    )
  }
}

extension View {
  /// Attaches the record-store corruption-recovery alert host. See
  /// `RecordStoreAlertHost` for behavior.
  func recordStoreAlertHost() -> some View {
    modifier(RecordStoreAlertHost())
  }
}
