import AppKit
import SwiftUI

enum CoverTileStyle {
  case month, collection
  var side: CGFloat { self == .month ? 180 : 144 }
  var radius: CGFloat { self == .month ? 8 : 6 }
}

/// Shared visual treatment; adapters retain their own task identity and accessibility semantics.
struct CoverTileView: View {
  let style: CoverTileStyle
  let title: String
  let caption: String
  let accessibilityLabel: String
  let content: CoverTileContent
  let isFullyExported: Bool
  var isFolder = false
  var isSelected = false
  @State private var isHovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      coverArea
        .frame(width: style.side, height: style.side)
        .clipShape(RoundedRectangle(cornerRadius: style.radius, style: .continuous))
        .overlay(alignment: .topTrailing) {
          if isFullyExported {
            Image(systemName: "checkmark.circle.fill")
              .symbolRenderingMode(.palette)
              .foregroundStyle(.white, .green)
              .font(.title3)
              .shadow(color: Color.black.opacity(0.25), radius: 1.5, y: 0.5)
              .padding(6)
              .accessibilityHidden(true)
          }
        }
        .overlay {
          if isSelected {
            RoundedRectangle(cornerRadius: style.radius, style: .continuous)
              .stroke(Color.accentColor, lineWidth: 3)
          }
        }
      Text(title)
        .font(.body)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(width: style.side, alignment: .leading)
      Text(caption)
        .font(.caption)
        .foregroundColor(.secondary)
        .lineLimit(1)
        .frame(width: style.side, alignment: .leading)
    }
    .scaleEffect(isHovering ? 1.02 : 1.0)
    .animation(.easeInOut(duration: 0.12), value: isHovering)
    .onHover { isHovering = $0 }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
  }

  @ViewBuilder private var coverArea: some View {
    if isFolder {
      ZStack {
        RoundedRectangle(cornerRadius: style.radius, style: .continuous)
          .fill(Color.secondary.opacity(0.12))
        Image(systemName: "folder.fill")
          .font(.system(size: 56))
          .foregroundStyle(.secondary)
      }
    } else {
      ZStack {
        Rectangle().fill(Color.gray.opacity(0.15))
        switch content {
        case .images(let images): coverGrid(images)
        case .idle, .loading:
          Rectangle().fill(Color.gray.opacity(0.2)).accessibilityLabel("Loading cover")
        case .empty:
          Image(systemName: "photo.on.rectangle.angled")
            .font(.system(size: 36)).foregroundStyle(.secondary)
        case .failed:
          Image(systemName: "exclamationmark.triangle")
            .foregroundStyle(.secondary).help("Couldn't load preview").accessibilityHidden(true)
        }
      }
    }
  }

  @ViewBuilder private func coverGrid(_ images: [CGImage]) -> some View {
    let displayed = Array(images.prefix(4))
    if displayed.count <= 1 {
      if let single = displayed.first {
        Image(decorative: single, scale: 1)
          .resizable().scaledToFill().frame(width: style.side, height: style.side).clipped()
      }
    } else {
      VStack(spacing: 1) {
        HStack(spacing: 1) {
          coverCell(0, displayed)
          coverCell(1, displayed)
        }
        HStack(spacing: 1) {
          coverCell(2, displayed)
          coverCell(3, displayed)
        }
      }
    }
  }

  @ViewBuilder private func coverCell(_ index: Int, _ images: [CGImage]) -> some View {
    let side = (style.side - 1) / 2
    if index < images.count {
      Image(decorative: images[index], scale: 1)
        .resizable().scaledToFill().frame(width: side, height: side).clipped()
    } else {
      Rectangle().fill(Color.secondary.opacity(0.18)).frame(width: side, height: side)
    }
  }
}

enum CoverTileFormatting {
  static func photoCount(_ count: Int?) -> String {
    guard let count else { return " " }
    return count == 1 ? "1 photo" : "\(count) photos"
  }

  static func title(_ descriptor: PhotoCollectionDescriptor) -> String {
    descriptor.title.isEmpty
      ? (descriptor.kind == .folder ? "Untitled folder" : "Untitled") : descriptor.title
  }

  static func caption(
    kind: PhotoCollectionDescriptor.Kind, photoCount: Int?, albumCount: Int
  ) -> String {
    switch kind {
    case .album: return Self.photoCount(photoCount)
    case .folder:
      let albums = albumCount == 1 ? "1 album" : "\(albumCount) albums"
      if let photoCount, photoCount > 0 { return "\(albums) · \(photoCount) photos" }
      return albums
    case .favorites, .sharedAlbum: return " "
    }
  }

  static func label(
    prefix: [String], photoCount: Int?, exported: Bool, content: CoverTileContent
  ) -> String {
    var parts = prefix
    if let photoCount { parts.append(Self.photoCount(photoCount)) }
    if exported { parts.append("fully exported") }
    if let hint = content.previewHint { parts.append(hint) }
    return parts.joined(separator: ", ")
  }

  static func collectionLabel(
    _ descriptor: PhotoCollectionDescriptor, photoCount: Int?, albumCount: Int,
    exported: Bool, content: CoverTileContent
  ) -> String {
    let title = Self.title(descriptor)
    switch descriptor.kind {
    case .album:
      return label(
        prefix: ["Album", title], photoCount: photoCount, exported: exported, content: content)
    case .folder:
      var parts = ["Folder", title, "\(albumCount) albums"]
      if let photoCount { parts.append("\(photoCount) photos") }
      return parts.joined(separator: ", ")
    case .favorites, .sharedAlbum: return title
    }
  }
}
