import SwiftUI

/// Current destination recovery remains visible above active or terminal export feedback.
struct DestinationStatusBanner: View {
  @EnvironmentObject private var destination: ExportDestinationManager

  var body: some View {
    let message = destination.destinationWarning
    let offersFolder = message != nil && destination.status.offersFolderSelection
    if let message {
      HStack(spacing: 8) {
        Image(systemName: "externaldrive.badge.exclamationmark")
          .foregroundStyle(.orange)
        Text(message)
          .lineLimit(2)
        Spacer(minLength: 0)
        if offersFolder {
          Button("Choose Folder…") { destination.selectFolder() }
        }
      }
      .font(.caption)
      .padding(.horizontal, 16)
      .padding(.vertical, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.bar)
      .overlay(alignment: .bottom) { Divider() }
      .accessibilityIdentifier("destination-status-banner")
    }
  }
}
