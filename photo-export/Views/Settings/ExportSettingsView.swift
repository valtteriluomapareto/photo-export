import SwiftUI

/// Settings → Export tab. Home for export choices that apply to both manual and
/// Auto Export runs and are pick-once-forget (rather than per-batch toolbar
/// toggles). Today: just the Live Photo paired-export switch (issue #49). Future
/// export-wide settings (RAW handling, metadata sidecars, etc.) belong here too.
struct ExportSettingsView: View {
  @EnvironmentObject private var exportManager: ExportManager

  var body: some View {
    Form {
      Section("Live Photos") {
        Toggle(
          isOn: Binding(
            get: { exportManager.livePhotosPairedExport },
            set: { exportManager.livePhotosPairedExport = $0 }
          )
        ) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Export Live Photos as paired image + video")
            Text(
              // The disk-footprint caveat is the load-bearing reason this is opt-in.
              // A Live Photo's motion file is typically 1–3 MB; libraries with thousands
              // of Live Photos roughly double in size when the toggle is on.
              "Writes the motion file (`.MOV`) next to the still (e.g. `IMG_0001.HEIC` "
                + "alongside `IMG_0001.MOV`). Off by default. Each Live Photo's motion "
                + "file is typically 1–3 MB, so libraries with many Live Photos can roughly "
                + "double in size on disk when this is on. Shared-album Live Photos stay "
                + "still-only — Apple doesn't expose their motion component."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 520)
  }
}
