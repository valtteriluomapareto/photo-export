import AppKit
import SwiftUI

/// The month adapter owns year/month task identity; the shared tile owns rendering.
struct MonthTileView: View {
  static let tileSide = CoverTileStyle.month.side
  let year: Int
  let month: Int
  let photoCount: Int?
  let isFullyExported: Bool
  let photoLibraryService: any PhotoLibraryService
  @Environment(\.displayScale) private var displayScale
  @State private var content: CoverTileContent = .idle

  var body: some View {
    CoverTileView(
      style: .month, title: MonthFormatting.name(for: month),
      caption: CoverTileFormatting.photoCount(photoCount),
      accessibilityLabel: CoverTileFormatting.label(
        prefix: ["Month", "\(MonthFormatting.name(for: month)) \(year)"],
        photoCount: photoCount, exported: isFullyExported, content: content),
      content: content, isFullyExported: isFullyExported
    )
    .accessibilityHint("Opens the month's photos")
    .task(id: "\(year)-\(month)") {
      // ForEach keys the month alone. A year change must immediately discard old covers.
      content = .loading
      if let loaded = await CoverTileContent.load(
        scope: .timeline(year: year, month: month), service: photoLibraryService,
        side: Self.tileSide, displayScale: displayScale), !Task.isCancelled
      {
        content = loaded
      }
    }
  }
}
