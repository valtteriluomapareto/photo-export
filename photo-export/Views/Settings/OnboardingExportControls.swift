import SwiftUI

/// The first-run options keep their bindings in the parent that also owns the action row.
struct OnboardingExportOptions: View {
  @Binding var exportAll: Bool
  @Binding var includeOriginals: Bool
  @Binding var convertHEICToJPEG: Bool
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Picker("", selection: $exportAll) {
        Text("Everything (Recommended)").tag(true)
        Text("Let me pick months").tag(false)
      }
      .pickerStyle(.radioGroup)
      .labelsHidden()

      VStack(alignment: .leading, spacing: 4) {
        Toggle("Include originals for edited photos", isOn: $includeOriginals)
          .toggleStyle(.checkbox)
          .accessibilityIdentifier("onboarding-include-originals")
        Text(
          "Off: one file per photo. On: also keep original copies for photos "
            + "you've edited."
        )
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      VStack(alignment: .leading, spacing: 4) {
        Toggle("Convert HEIC to JPEG", isOn: $convertHEICToJPEG)
          .toggleStyle(.checkbox)
        Text(
          "Off: HEIC captures keep their format. On: re-encode HEIC captures as "
            + "JPEG on export. Non-HEIC photos are unaffected."
        )
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

/// The real first-run actions, used inside the scrollable screen.
struct OnboardingExportActions: View {
  @Environment(ExportManager.self) private var exportManager
  @EnvironmentObject private var exportDestinationManager: ExportDestinationManager
  let historyState: RecordStoreState
  let exportAll: Bool
  let includeOriginals: Bool
  let convertHEICToJPEG: Bool
  let onSkip: () -> Void

  private var exportAvailability: ManualExportAvailability {
    ManualExportAvailability(
      destinationCanExport: exportDestinationManager.canExportNow,
      history: historyState)
  }

  /// Why Start Export is disabled while the picked folder's history loads; empty otherwise.
  private var startExportHelp: String {
    guard exportAll, exportAvailability == .loadingHistory else { return "" }
    return exportAvailability.unavailableHelp(
      destinationHelp: exportDestinationManager.exportUnavailableHelp) ?? ""
  }

  var body: some View {
    HStack(spacing: 16) {
      Button("Skip") {
        onSkip()
      }
      .buttonStyle(.borderless)

      Button(exportAll ? "Start Export" : "Continue") {
        // Apply the chosen versions first so the export kicked off below uses the
        // selection the user made here, not the persisted default.
        exportManager.versionSelection = includeOriginals ? .editedWithOriginals : .edited
        exportManager.convertHEICToJPEG = convertHEICToJPEG
        if exportAll && exportAvailability.canStart {
          exportManager.startExportAll()
        }
        onSkip()
      }
      .buttonStyle(.borderedProminent)
      // A folder picked here has its history read first; starting meanwhile would drop the
      // export.
      .accessibilityIdentifier("onboarding-export-primary")
      .disabled(
        exportDestinationManager.selectedFolderURL == nil
          || (exportAll && exportAvailability == .loadingHistory)
      )
      .help(startExportHelp)
    }
  }
}
