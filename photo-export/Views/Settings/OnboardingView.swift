import SwiftUI

struct OnboardingView: View {
  @EnvironmentObject private var exportManager: ExportManager
  @EnvironmentObject private var exportDestinationManager: ExportDestinationManager

  let onSkip: () -> Void

  @State private var exportAll = true
  @State private var includeOriginals: Bool = false
  @State private var convertHEICToJPEG: Bool = false

  var body: some View {
    // GeometryReader + ScrollView keeps the content vertically centered when it
    // fits, and scrolls when it doesn't — at the largest Dynamic Type sizes (or
    // on a short display) the steps + buttons can exceed the window's minimum
    // height, and without scrolling the action buttons would be clipped out of
    // reach. `minHeight: proxy.size.height` makes the inner stack fill the
    // viewport so the `Spacer`s still center it whenever there's room.
    GeometryReader { proxy in
      ScrollView {
        content
          .frame(maxWidth: .infinity, minHeight: proxy.size.height)
      }
    }
    .firstRunWindowMinSize()
    .background(Color(.windowBackgroundColor))
  }

  private var content: some View {
    VStack(spacing: 24) {
      Spacer(minLength: 0)

      Image(systemName: "photo.on.rectangle.angled")
        .resizable()
        .scaledToFit()
        .frame(width: 80, height: 80)
        .foregroundColor(.accentColor)

      Text("Welcome to Photo Export")
        .font(.largeTitle)
        .fontWeight(.bold)

      Text("Back up your Photos library to any drive.")
        .font(.title3)
        .foregroundColor(.secondary)

      VStack(alignment: .leading, spacing: 16) {
        // Step 1: Select destination
        HStack(alignment: .top, spacing: 12) {
          Text("1")
            .font(.headline)
            .foregroundColor(.white)
            .frame(width: 28, height: 28)
            .background(Circle().fill(Color.accentColor))

          VStack(alignment: .leading, spacing: 6) {
            Text("Select an export destination")
              .font(.headline)

            if let url = exportDestinationManager.selectedFolderURL {
              HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                  .foregroundColor(.green)
                Text(url.lastPathComponent)
                  .lineLimit(1)
                  .truncationMode(.middle)
              }
              Button("Change\u{2026}") {
                exportDestinationManager.selectFolder()
              }
              .buttonStyle(.bordered)
              .fixedSize()
            } else {
              Button("Choose Folder\u{2026}") {
                exportDestinationManager.selectFolder()
              }
              .buttonStyle(.borderedProminent)
            }
          }
        }

        // Step 2: Choose scope
        HStack(alignment: .top, spacing: 12) {
          Text("2")
            .font(.headline)
            .foregroundColor(.white)
            .frame(width: 28, height: 28)
            .background(Circle().fill(Color.accentColor))

          VStack(alignment: .leading, spacing: 10) {
            Text("Choose what to export")
              .font(.headline)

            Picker("", selection: $exportAll) {
              Text("Everything (Recommended)").tag(true)
              Text("Let me pick months").tag(false)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 4) {
              Toggle("Include originals for edited photos", isOn: $includeOriginals)
                .toggleStyle(.checkbox)
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
      .padding(.horizontal, 40)
      .frame(maxWidth: 440)

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
          if exportAll && exportDestinationManager.canExportNow {
            exportManager.startExportAll()
          }
          onSkip()
        }
        .buttonStyle(.borderedProminent)
        .disabled(exportDestinationManager.selectedFolderURL == nil)
      }

      Spacer(minLength: 0)
    }
  }
}
