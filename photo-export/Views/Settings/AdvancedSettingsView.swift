import SwiftUI

/// Settings → Advanced tab. Houses mode-setting export-format options that
/// affect every future run rather than the immediate action: `Include
/// originals` (issue #19) and `Convert HEIC to JPEG` (issue #47). Both
/// previously lived in the toolbar's Format menu, where a SwiftUI `Menu`'s
/// inability to surface per-item tooltips meant the deferred-semantics
/// caveats were invisible. Migrating to Settings gives each toggle a
/// caption-style description that explains the trade-off in full, matching
/// the `AutoExportSettingsView` row layout (`Toggle { VStack { Text +
/// caption } }`).
///
/// Onboarding keeps its inline toggles — first-run users shouldn't have to
/// open Settings to set the initial export shape.
struct AdvancedSettingsView: View {
  @EnvironmentObject private var exportManager: ExportManager

  var body: some View {
    Form {
      if exportManager.hasActiveExportWork {
        Section {
          Label(
            "These options are locked while an export is running.",
            systemImage: "lock"
          )
          .foregroundStyle(.secondary)
        }
      }

      Section("Format") {
        includeOriginalsRow
        convertHEICToJPEGRow
      }
    }
    .formStyle(.grouped)
    .frame(minWidth: 480, idealWidth: 520, minHeight: 320)
  }

  private var includeOriginalsRow: some View {
    Toggle(isOn: $exportManager.includeOriginals) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Include originals for edited photos")
        Text(includeOriginalsDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .disabled(exportManager.hasActiveExportWork)
  }

  private var convertHEICToJPEGRow: some View {
    Toggle(isOn: $exportManager.convertHEICToJPEG) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Convert HEIC to JPEG")
        Text(convertHEICToJPEGDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .disabled(exportManager.hasActiveExportWork)
  }

  private var includeOriginalsDescription: String {
    switch exportManager.versionSelection {
    case .edited:
      return
        "Off: each photo is exported once, in the version Photos shows you. "
        + "Edited photos write the edit, unedited photos write the original "
        + "bytes. Filenames match the original Photos filename.\n\n"
        + "On: edited photos additionally write a `_orig` companion holding "
        + "the unmodified original bytes — e.g. `IMG_0001.JPG` (the edit) "
        + "next to `IMG_0001_orig.HEIC` (the original). Unedited photos still "
        + "produce a single file."
    case .editedWithOriginals:
      return
        "On: edited photos write both the user-visible version and a `_orig` "
        + "companion with the original bytes (e.g. `IMG_0001.JPG` next to "
        + "`IMG_0001_orig.HEIC`). Unedited photos still produce a single file.\n\n"
        + "Off: each photo is exported once, in the version Photos shows you."
    }
  }

  private var convertHEICToJPEGDescription: String {
    "Re-encode HEIC and HEIF photos as JPEG on export. Useful if your "
      + "destination (a NAS, a Windows PC, an older photo viewer) doesn't "
      + "understand HEIC. JPEG quality is set to 85% — visually "
      + "indistinguishable from HEIC for photos while keeping file size "
      + "moderate.\n\n"
      + "Applies to new exports only. Existing HEIC files on disk are not "
      + "touched; re-run an Export action (Export All, Export Month, Export "
      + "Album, or wait for Auto Export) to convert them.\n\n"
      + "Non-HEIC photos are unaffected."
  }
}
