import AppKit
import SwiftUI

/// View modifier that surfaces the corruption-recovery alert for both record stores.
///
/// Either store can independently transition to `.failed` when its snapshot fails to
/// decode (see `JSONLRecordFile.load()`). The store keeps the corrupt snapshot on disk
/// untouched and only renames it (`<name>.broken-<ISO8601>`) when the user explicitly
/// chooses Reset Records, so the user never silently loses their record history. This
/// host presents a single alert at a time; if both stores are failed, the timeline
/// alert shows first and the collection alert follows after the user resolves it.
///
/// Buttons:
/// - **Reset Records** — runs the deferred rename and reinitializes the failed store.
///   The exported files on disk are untouched; only the in-app progress tracking is
///   reset. The next export run rebuilds the records.
/// - **Quit** — terminates the app so the user can inspect the broken file by hand
///   before relaunching.
///
/// There is no Cancel action: dismissing without resolving would leave the affected
/// sidebar in an unexplained "stuck" state with no way back into the recovery flow
/// short of relaunching. Both actions move the user forward.
struct RecordStoreAlertHost: ViewModifier {
  @EnvironmentObject private var exportRecordStore: ExportRecordStore
  @EnvironmentObject private var collectionExportRecordStore: CollectionExportRecordStore

  func body(content: Content) -> some View {
    content
      .alert(
        "Photo Export couldn't read its timeline progress file",
        isPresented: timelineAlertBinding,
        actions: {
          Button("Reset Records") { exportRecordStore.resetToEmpty() }
          Button("Quit") { NSApplication.shared.terminate(nil) }
        },
        message: {
          Text(
            "Your exported photos on disk are safe — only the in-app progress tracking "
              + "for timeline (year/month) exports is affected. Reset Records will move "
              + "the broken file aside and start fresh; the next export run rebuilds the "
              + "records.")
        }
      )
      .alert(
        "Photo Export couldn't read its collections progress file",
        isPresented: collectionAlertBinding,
        actions: {
          Button("Reset Records") { collectionExportRecordStore.resetToEmpty() }
          Button("Quit") { NSApplication.shared.terminate(nil) }
        },
        message: {
          Text(
            "Your exported photos on disk are safe — only the in-app progress tracking "
              + "for Favorites and album exports is affected. Reset Records will move the "
              + "broken file aside and start fresh; the next collection export rebuilds "
              + "the records.")
        }
      )
  }

  private var timelineAlertBinding: Binding<Bool> {
    Binding(
      get: { exportRecordStore.state == .failed },
      set: { _ in }  // dismissal handled by the actions above
    )
  }

  private var collectionAlertBinding: Binding<Bool> {
    Binding(
      get: {
        // Only show the collection alert when the timeline alert isn't already active so
        // SwiftUI doesn't try to present two alerts on the same view at once.
        exportRecordStore.state != .failed
          && collectionExportRecordStore.state == .failed
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
