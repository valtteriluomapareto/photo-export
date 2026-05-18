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
  /// `true` when this tile is part of the user's active multi-selection. Drives the
  /// blue selection ring.
  let isSelected: Bool

  let photoLibraryService: any PhotoLibraryService

  @State private var covers: [NSImage] = []
  @State private var coverState: CoverState = .idle
  @State private var isHovering: Bool = false

  private enum CoverState {
    case idle
    case loading
    case loaded
    case empty  // album has no assets
    case failed
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      coverArea
        .frame(width: Self.tileSide, height: Self.tileSide)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(alignment: .topTrailing) { exportedBadge }
        .overlay {
          if isSelected {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .stroke(Color.accentColor, lineWidth: 3)
          }
        }

      Text(displayTitle)
        .font(.body)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(width: Self.tileSide, alignment: .leading)

      Text(captionText)
        .font(.caption)
        .foregroundColor(.secondary)
        .lineLimit(1)
        .frame(width: Self.tileSide, alignment: .leading)
    }
    .scaleEffect(isHovering ? 1.02 : 1.0)
    .animation(.easeInOut(duration: 0.12), value: isHovering)
    .onHover { isHovering = $0 }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityAddTraits(accessibilityTraits)
    .task(id: descriptor.id) {
      // Subfolders never need a cover fetch.
      guard descriptor.kind == .album else { return }
      guard case .idle = coverState else { return }
      await loadCovers()
    }
  }

  private var accessibilityTraits: AccessibilityTraits {
    var traits: AccessibilityTraits = .isButton
    if isSelected { traits.insert(.isSelected) }
    return traits
  }

  // MARK: - Cover area

  @ViewBuilder
  private var coverArea: some View {
    switch descriptor.kind {
    case .album:
      albumCoverArea
    case .folder:
      subfolderPlaceholder
    case .favorites, .sharedAlbum:
      // Unreachable: favorites and shared albums render as their own sidebar sections,
      // never appear inside a folder. Use the subfolder placeholder defensively.
      subfolderPlaceholder
    }
  }

  @ViewBuilder
  private var albumCoverArea: some View {
    ZStack {
      Rectangle().fill(Color.gray.opacity(0.15))
      switch coverState {
      case .loaded:
        coverGrid
      case .loading, .idle:
        ProgressView().controlSize(.small)
      case .empty:
        Image(systemName: "photo.on.rectangle.angled")
          .font(.system(size: 36))
          .foregroundStyle(.secondary)
      case .failed:
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(.secondary)
          .help("Couldn't load preview")
      }
    }
  }

  /// 1-up when only one cover is available, 4-up (2x2) when four are available.
  /// In-between cases (2 or 3 covers) fill remaining slots with a soft tint so the
  /// composition stays balanced without faking duplicates. Mirrors Photos.app's
  /// album-tile behaviour.
  @ViewBuilder
  private var coverGrid: some View {
    let displayed = Array(covers.prefix(4))
    if displayed.count <= 1 {
      if let single = displayed.first {
        Image(nsImage: single)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(width: Self.tileSide, height: Self.tileSide)
          .clipped()
      }
    } else {
      VStack(spacing: 1) {
        HStack(spacing: 1) {
          coverCell(at: 0, of: displayed)
          coverCell(at: 1, of: displayed)
        }
        HStack(spacing: 1) {
          coverCell(at: 2, of: displayed)
          coverCell(at: 3, of: displayed)
        }
      }
    }
  }

  @ViewBuilder
  private func coverCell(at index: Int, of covers: [NSImage]) -> some View {
    let cellSide = (Self.tileSide - 1) / 2
    if index < covers.count {
      Image(nsImage: covers[index])
        .resizable()
        .aspectRatio(contentMode: .fill)
        .frame(width: cellSide, height: cellSide)
        .clipped()
    } else {
      Rectangle()
        .fill(Color.secondary.opacity(0.18))
        .frame(width: cellSide, height: cellSide)
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

  /// Fully-exported badge. Palette rendering puts the white check inside a green disc
  /// — the symbol is its own backing so we don't need a flat white plate underneath
  /// (which read as a foreign sticker, especially in Dark Mode). A subtle shadow keeps
  /// the green readable on light covers.
  @ViewBuilder
  private var exportedBadge: some View {
    if descriptor.kind == .album, isFullyExported {
      Image(systemName: "checkmark.circle.fill")
        .symbolRenderingMode(.palette)
        .foregroundStyle(.white, .green)
        .font(.title3)
        .shadow(color: Color.black.opacity(0.25), radius: 1.5, y: 0.5)
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
      guard let photoCount else { return " " }  // reserve line height while loading
      return photoCount == 1 ? "1 photo" : "\(photoCount) photos"
    case .folder:
      let albums = albumCount == 1 ? "1 album" : "\(albumCount) albums"
      if let photoCount, photoCount > 0 {
        return "\(albums) · \(photoCount) photos"
      }
      return albums
    case .favorites, .sharedAlbum:
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
    case .favorites, .sharedAlbum:
      return displayTitle
    }
  }

  // MARK: - Cover loading

  /// Loads up to four cover thumbnails for an album tile. Renders 1-up if the album has
  /// a single asset, 4-up otherwise. Thumbnail fetches dispatch into a `TaskGroup`; the
  /// underlying `loadThumbnail` is `@MainActor`-isolated so the calls serialise on the
  /// main actor, but each await yields the runloop and PhotoKit can prefetch in the
  /// background — fast enough in practice that the simpler structure beats threading a
  /// detached fetch through the service seam.
  ///
  /// `fetchAssets(in: .album(...))` materialises the full album list, which is
  /// acceptable for v1 — the tile only builds when the album scrolls into view, and
  /// the typical user album holds tens to hundreds of photos. A `firstAssets(in:limit:)`
  /// fast path on `PhotoLibraryService` is the natural follow-up if this proves a
  /// bottleneck on very large albums.
  private func loadCovers() async {
    guard let albumId = descriptor.localIdentifier else {
      coverState = .empty
      return
    }
    coverState = .loading
    do {
      let assets = try await photoLibraryService.fetchAssets(
        in: .album(collectionId: albumId), mediaType: nil)
      try Task.checkCancellation()
      let coverIds = assets.prefix(4).map(\.id)
      if coverIds.isEmpty {
        coverState = .empty
        return
      }
      let loaded = await withTaskGroup(of: (Int, NSImage?).self) { group in
        for (index, id) in coverIds.enumerated() {
          group.addTask {
            (index, await photoLibraryService.loadThumbnail(for: id, allowNetwork: true))
          }
        }
        var pairs: [(Int, NSImage)] = []
        for await (index, image) in group {
          if let image { pairs.append((index, image)) }
        }
        return pairs.sorted(by: { $0.0 < $1.0 }).map(\.1)
      }
      try Task.checkCancellation()
      if loaded.isEmpty {
        coverState = .failed
      } else {
        covers = loaded
        coverState = .loaded
      }
    } catch is CancellationError {
      // Don't change state on cancellation — the replacement task will publish its own.
    } catch {
      coverState = .failed
    }
  }
}
