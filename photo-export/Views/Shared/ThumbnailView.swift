import AppKit
import Photos
import SwiftUI

enum ThumbnailState {
  case loading
  case loaded(NSImage)
  case failed
}

struct ThumbnailView: View {
  let asset: AssetDescriptor
  let state: ThumbnailState
  let isSelected: Bool
  let isExported: Bool
  var onRetry: (() -> Void)?

  var body: some View {
    ZStack {
      switch state {
      case .loaded(let image):
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(width: 100, height: 100)
          .clipped()
      case .loading:
        Rectangle()
          .fill(Color.gray.opacity(0.3))
          .frame(width: 100, height: 100)
          .overlay(ProgressView())
      case .failed:
        Rectangle()
          .fill(Color.gray.opacity(0.2))
          .frame(width: 100, height: 100)
          .overlay(
            VStack(spacing: 4) {
              Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.secondary)
              if let onRetry {
                Button("Retry") { onRetry() }
                  .font(.caption2)
                  .buttonStyle(.borderless)
                // Keep the Retry button independently focusable for VoiceOver — it must
                // not get rolled into the tile's composed accessibility label/element.
              } else {
                Text("Failed")
                  .font(.caption2)
                  .foregroundColor(.secondary)
              }
            }
          )
      }

      // Decorations: not-yet-exported dot, selection ring, and a media-kind badge for videos.
      // These are visual-only — the tile's combined accessibility element (below) describes
      // all of these states in a single VoiceOver readout.
      if !isExported {
        VStack {
          HStack {
            Circle()
              .fill(Color.accentColor.opacity(0.95))
              .frame(width: 8, height: 8)
              .accessibilityHidden(true)
            Spacer()
          }
          Spacer()
        }
        .padding(6)
      }

      if isSelected {
        RoundedRectangle(cornerRadius: 4)
          .stroke(Color.blue, lineWidth: 3)
          .frame(width: 100, height: 100)
          .accessibilityHidden(true)
      }

      if asset.mediaType == .video {
        VStack {
          Spacer()
          HStack {
            Image(systemName: "video.fill")
              .foregroundColor(.white)
              .padding(4)
              .background(Color.black.opacity(0.6))
              .cornerRadius(4)
              .accessibilityHidden(true)
            Spacer()
          }
          .padding(4)
        }
      }
    }
    .cornerRadius(4)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityHint("Open details")
    .accessibilityAddTraits(accessibilityTraits)
  }

  // MARK: - Accessibility

  /// Composed VoiceOver label that describes the asset and its current backup/selection
  /// state in a single, natural sentence. The decorative ZStack children are hidden so
  /// SwiftUI doesn't read them separately.
  private var accessibilityLabel: String {
    var parts: [String] = []
    parts.append(asset.mediaType == .video ? "Video" : "Photo")
    if let date = asset.creationDate {
      parts.append("from \(Self.dateFormatter.string(from: date))")
    }
    if asset.mediaType == .video, asset.duration > 0 {
      let seconds = Int(asset.duration.rounded())
      parts.append("duration \(seconds) seconds")
    }
    parts.append(isExported ? "exported" : "not yet exported")
    if case .failed = state { parts.append("thumbnail failed to load") }
    return parts.joined(separator: ", ")
  }

  private var accessibilityTraits: AccessibilityTraits {
    var traits: AccessibilityTraits = .isButton
    if isSelected { traits.insert(.isSelected) }
    return traits
  }

  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .long
    formatter.timeStyle = .none
    return formatter
  }()
}
