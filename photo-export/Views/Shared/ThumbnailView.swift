import AppKit
import Photos
import SwiftUI

/// Grid thumbnail tile. Owns its own load via `.task(id: asset.id)` so
/// SwiftUI cancels the in-flight PhotoKit request when the cell scrolls
/// off-screen or is reused for a different asset.
///
/// Render order: cached HQ → cached fast → async fast → async HQ. Each
/// async leg awaits `PhotoLibraryManager.decodedThumbnail`, which wraps
/// PhotoKit's `requestImage` in `withTaskCancellationHandler` so this
/// cell's `.task` lifecycle propagates all the way to PhotoKit.
struct ThumbnailView: View {
  let asset: AssetDescriptor
  let isSelected: Bool
  let isExported: Bool

  @EnvironmentObject private var photoLibraryManager: PhotoLibraryManager

  @State private var image: CGImage?
  @State private var failed: Bool = false
  @State private var retryToken: Int = 0

  /// Quantized display-pixel target. Single bucket so the cache key stays
  /// stable across grid reuse; matches `MonthViewModel.gridThumbnailSize`.
  private static let targetSize = CGSize(width: 256, height: 256)

  var body: some View {
    ZStack {
      if let image {
        Image(nsImage: NSImage(cgImage: image, size: .zero))
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(width: 100, height: 100)
          .clipped()
      } else if failed {
        Rectangle()
          .fill(Color.gray.opacity(0.2))
          .frame(width: 100, height: 100)
          .overlay(
            VStack(spacing: 4) {
              Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.secondary)
              Button("Retry") { retryToken &+= 1 }
                .font(.caption2)
                .buttonStyle(.borderless)
              // Keep the Retry button independently focusable for VoiceOver — it must
              // not get rolled into the tile's composed accessibility label/element.
            }
          )
      } else {
        Rectangle()
          .fill(Color.gray.opacity(0.3))
          .frame(width: 100, height: 100)
          .overlay(ProgressView())
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
    .task(id: "\(asset.id)#\(retryToken)") {
      await loadThumbnail()
    }
  }

  private func loadThumbnail() async {
    failed = false
    // Cached probes first so a re-mount on warm scroll doesn't fire a PhotoKit request.
    if let hq = photoLibraryManager.cachedDecodedThumbnail(
      for: asset.id, quantizedSize: Self.targetSize, deliveryMode: .highQuality)
    {
      image = hq
      return
    }
    if let cachedFast = photoLibraryManager.cachedDecodedThumbnail(
      for: asset.id, quantizedSize: Self.targetSize, deliveryMode: .fast)
    {
      image = cachedFast
      // Fall through to attempt the HQ upgrade.
    } else if let fast = await photoLibraryManager.decodedThumbnail(
      for: asset.id, quantizedSize: Self.targetSize, deliveryMode: .fast)
    {
      image = fast
    } else if !Task.isCancelled {
      failed = true
    }
    guard !Task.isCancelled else { return }
    if let hq = await photoLibraryManager.decodedThumbnail(
      for: asset.id, quantizedSize: Self.targetSize, deliveryMode: .highQuality)
    {
      image = hq
      failed = false
    }
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
    if failed { parts.append("thumbnail failed to load") }
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
