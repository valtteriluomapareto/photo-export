import SwiftUI

/// Settings → Advanced tab. Houses mode-setting export-format options that
/// affect every future run rather than the immediate action: `Include
/// originals` (issue #19), `Convert HEIC to JPEG` (issue #47), and `Export
/// Live Photos as paired image + video` (issue #49). The first two previously
/// lived in the toolbar's Format menu, where a SwiftUI `Menu`'s inability to
/// surface per-item tooltips meant the deferred-semantics caveats were
/// invisible. Migrating to Settings gives each toggle a caption-style
/// description that explains the trade-off in full, matching the
/// `AutoExportSettingsView` row layout (`Toggle { VStack { Text + caption } }`).
///
/// Onboarding keeps its inline toggles — first-run users shouldn't have to
/// open Settings to set the initial export shape.
struct AdvancedSettingsView: View {
  @EnvironmentObject private var exportManager: ExportManager

  var body: some View {
    Form {
      if exportManager.hasActiveExportWork {
        Section {
          ExportInProgressBanner()
            .listRowInsets(EdgeInsets())
        }
      }

      Section("Format") {
        includeOriginalsRow
        convertHEICToJPEGRow
        livePhotosPairedRow
      }

      Section("Organization") {
        videoLayoutRow
      }
    }
    .formStyle(.grouped)
    .frame(minWidth: 460, minHeight: 460)
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

  private var livePhotosPairedRow: some View {
    Toggle(isOn: $exportManager.livePhotosPairedExport) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Export Live Photos as paired image + video")
        Text(livePhotosPairedDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .disabled(exportManager.hasActiveExportWork)
  }

  private var videoLayoutRow: some View {
    Toggle(
      isOn: Binding(
        get: { exportManager.videoLayout == .subfolder },
        set: { exportManager.videoLayout = $0 ? .subfolder : .flat }
      )
    ) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Separate videos into a subfolder")
        Text(videoLayoutDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .disabled(exportManager.hasActiveExportWork)
  }

  private var includeOriginalsDescription: String {
    "Off: each photo is exported once, in the version Photos shows you. "
      + "Edited photos write the edit, unedited photos write the original "
      + "bytes.\n\n"
      + "On: edited photos additionally write a `_orig` companion holding "
      + "the unmodified original bytes — e.g. `IMG_0001.JPG` (the edit) "
      + "next to `IMG_0001_orig.HEIC` (the original). Unedited photos still "
      + "produce a single file."
  }

  private var convertHEICToJPEGDescription: String {
    "Re-encode HEIC and HEIF photos as high-quality JPEG on export. "
      + "Useful if your destination (a NAS, a Windows PC, an older photo "
      + "viewer) doesn't understand HEIC.\n\n"
      + "Applies to new exports only. Existing HEIC files on disk are not "
      + "touched; re-run an Export action (Export All, Export Month, Export "
      + "Album, or wait for Auto Export) to convert them.\n\n"
      + "Non-HEIC photos are unaffected."
  }

  private var livePhotosPairedDescription: String {
    "Writes the paired video (a .MOV file) next to the still for each Live "
      + "Photo (e.g. IMG_0001.HEIC alongside IMG_0001.MOV).\n\n"
      + "Off by default. A Live Photo's paired video is typically 1–3 MB, so "
      + "libraries with many Live Photos can roughly double in size on disk "
      + "when this is on.\n\n"
      + "Shared-album Live Photos stay still-only — Apple doesn't expose "
      + "their paired video resource."
  }

  private var videoLayoutDescription: String {
    "Off: photos and videos share each month or album folder.\n\n"
      + "On: videos go into a \"videos\" subfolder next to their photos. "
      + "The paired video of a Live Photo is an exception — it stays next "
      + "to its still so the pair isn't split across folders.\n\n"
      + "Applies to new exports only. Videos already on disk stay where "
      + "they are; turning this on later produces a mixed layout until you "
      + "re-export."
  }
}

/// Inline banner shown above the Format section while an export is
/// running, mirroring the visual weight of `AutoExportSettingsView`'s
/// migration/safety banners (icon + title + body in an inset card). The
/// toggles themselves stay visible and disabled — the banner explains
/// *why* without the user having to discover the disabled state via
/// hover/grey-out alone.
private struct ExportInProgressBanner: View {
  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "lock.fill")
        .foregroundStyle(.secondary)
        .font(.title3)
      VStack(alignment: .leading, spacing: 4) {
        Text("Export In Progress")
          .font(.headline)
        Text(
          "Export settings are locked while an export is running. Cancel or "
            + "wait for the current run to finish to change these."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(12)
  }
}
