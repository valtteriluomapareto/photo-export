import AppKit
import SwiftUI

/// A single tile in `FolderContentView`'s grid. Renders either an album (cover thumbnail
/// + title + count + export-status badge) or a subfolder (folder glyph placeholder +
/// title + child album count). Mirrors the visual rhythm Apple uses in Photos.app's
/// folder view.
///
/// Cover thumbnails are loaded lazily via `.task` so a folder with many albums only
/// fetches covers for tiles that scroll into view (`LazyVGrid` semantics).
struct FolderTileView: View {
  /// Side length of the tile's image area. Tile total height grows by ~36pt to fit the
  /// title + count caption beneath.
  static let tileSide: CGFloat = 144

  let descriptor: PhotoCollectionDescriptor
  let photoCount: Int?
  /// Number of `.album` descendants. Only meaningful for `.folder` tiles.
  let albumCount: Int
  /// `true` when every photo in this album has been exported (album tiles only).
  let isFullyExported: Bool

  let photoLibraryService: any PhotoLibraryService

  @State private var cover: NSImage?
  @State private var coverState: CoverState = .idle

  private enum CoverState {
    case idle
    case loading
    case loaded
    case empty   // album has no assets
    case failed
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      coverArea
        .frame(width: Self.tileSide, height: Self.tileSide)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(alignment: .topTrailing) { exportedBadge }

      Text(displayTitle)
        .font(.body)
        .fontWeight(.medium)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(width: Self.tileSide, alignment: .leading)

      Text(captionText)
        .font(.caption)
        .foregroundColor(.secondary)
        .lineLimit(1)
        .frame(width: Self.tileSide, alignment: .leading)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityAddTraits(.isButton)
    .task(id: descriptor.id) {
      // Subfolders never need a cover fetch.
      guard descriptor.kind == .album else { return }
      guard case .idle = coverState else { return }
      await loadCover()
    }
  }

  // MARK: - Cover area

  @ViewBuilder
  private var coverArea: some View {
    switch descriptor.kind {
    case .album:
      albumCoverArea
    case .folder:
      subfolderPlaceholder
    case .favorites:
      // Unreachable: favorites is rendered as its own sidebar section, never appears
      // inside a folder. Render the same placeholder as a subfolder for safety.
      subfolderPlaceholder
    }
  }

  @ViewBuilder
  private var albumCoverArea: some View {
    ZStack {
      Rectangle().fill(Color.gray.opacity(0.15))
      switch coverState {
      case .loaded:
        if let cover {
          Image(nsImage: cover)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: Self.tileSide, height: Self.tileSide)
            .clipped()
        }
      case .loading, .idle:
        ProgressView().controlSize(.small)
      case .empty:
        Image(systemName: "photo.on.rectangle.angled")
          .font(.system(size: 36))
          .foregroundStyle(.secondary)
      case .failed:
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(.secondary)
      }
    }
  }

  private var subfolderPlaceholder: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(Color.secondary.opacity(0.12))
      Image(systemName: "folder.fill")
        .font(.system(size: 56))
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var exportedBadge: some View {
    if descriptor.kind == .album, isFullyExported {
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .background(Circle().fill(Color.white).padding(2))
        .font(.title3)
        .padding(6)
        .accessibilityHidden(true)
    }
  }

  // MARK: - Captions

  private var displayTitle: String {
    descriptor.title.isEmpty
      ? (descriptor.kind == .folder ? "Untitled folder" : "Untitled")
      : descriptor.title
  }

  private var captionText: String {
    switch descriptor.kind {
    case .album:
      guard let photoCount else { return " " }   // reserve line height while loading
      return photoCount == 1 ? "1 photo" : "\(photoCount) photos"
    case .folder:
      let albums = albumCount == 1 ? "1 album" : "\(albumCount) albums"
      if let photoCount, photoCount > 0 {
        return "\(albums) · \(photoCount) photos"
      }
      return albums
    case .favorites:
      return " "
    }
  }

  private var accessibilityLabel: String {
    switch descriptor.kind {
    case .album:
      var parts = ["Album", displayTitle]
      if let photoCount {
        parts.append(photoCount == 1 ? "1 photo" : "\(photoCount) photos")
      }
      if isFullyExported { parts.append("fully exported") }
      return parts.joined(separator: ", ")
    case .folder:
      var parts = ["Folder", displayTitle, "\(albumCount) albums"]
      if let photoCount { parts.append("\(photoCount) photos") }
      return parts.joined(separator: ", ")
    case .favorites:
      return displayTitle
    }
  }

  // MARK: - Cover loading

  private func loadCover() async {
    guard let albumId = descriptor.localIdentifier else {
      coverState = .empty
      return
    }
    coverState = .loading
    do {
      // `fetchAssets(in: .album(...))` materialises the full album list. Acceptable for
      // v1 — the tile is only built when the album scrolls into view, and the typical
      // user album holds tens to hundreds of photos. If this proves a bottleneck on
      // very large albums, a `firstAsset(in:)` fast path on `PhotoLibraryService` is
      // the natural follow-up.
      let assets = try await photoLibraryService.fetchAssets(
        in: .album(collectionId: albumId), mediaType: nil)
      guard let first = assets.first else {
        coverState = .empty
        return
      }
      if let image = await photoLibraryService.loadThumbnail(
        for: first.id, allowNetwork: true)
      {
        cover = image
        coverState = .loaded
      } else {
        coverState = .failed
      }
    } catch {
      coverState = .failed
    }
  }
}
