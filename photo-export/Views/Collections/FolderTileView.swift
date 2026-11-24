import AppKit
import SwiftUI

/// Collection task policy stays distinct: folders do not fetch and loaded albums do not refetch.
struct FolderTileView: View {
  static let tileSide = CoverTileStyle.collection.side
  let descriptor: PhotoCollectionDescriptor
  let photoCount: Int?
  let albumCount: Int
  let isFullyExported: Bool
  let isSelected: Bool
  let photoLibraryService: any PhotoLibraryService
  @Environment(\.displayScale) private var displayScale
  @State private var content: CoverTileContent = .idle

  var body: some View {
    CoverTileView(
      style: .collection, title: CoverTileFormatting.title(descriptor),
      caption: CoverTileFormatting.caption(
        kind: descriptor.kind, photoCount: photoCount, albumCount: albumCount),
      accessibilityLabel: CoverTileFormatting.collectionLabel(
        descriptor, photoCount: photoCount, albumCount: albumCount,
        exported: isFullyExported, content: content),
      content: content, isFullyExported: descriptor.kind == .album && isFullyExported,
      isFolder: descriptor.kind != .album, isSelected: isSelected
    )
    .accessibilityAddTraits(accessibilityTraits)
    .task(id: descriptor.id) {
      guard descriptor.kind == .album, content.isIdle else { return }
      guard let id = descriptor.localIdentifier else {
        content = .empty
        return
      }
      content = .loading
      if let loaded = await CoverTileContent.load(
        scope: .album(collectionId: id), service: photoLibraryService,
        side: Self.tileSide, displayScale: displayScale), !Task.isCancelled
      {
        content = loaded
      }
    }
  }

  private var accessibilityTraits: AccessibilityTraits {
    var traits: AccessibilityTraits = .isButton
    if isSelected { traits.formUnion(.isSelected) }
    return traits
  }
}
