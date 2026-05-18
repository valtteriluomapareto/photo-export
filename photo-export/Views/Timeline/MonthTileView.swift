import AppKit
import SwiftUI

/// A single tile in `YearContentView`'s grid. Mirrors `FolderTileView`'s visual rhythm
/// (rounded cover area, 4-up cover grid, title, caption, fully-exported badge) so the
/// year-by-month overview reads the same as the Collections folder overview, but uses a
/// larger tile because a year always holds exactly twelve children — far fewer than a
/// folder typically does — so we can afford the additional cover area.
///
/// Covers are loaded lazily via `.task` so a year with 12 months only fetches covers for
/// the tiles that scroll into view (`LazyVGrid` semantics). Each tile requests the four
/// chronologically earliest assets in its month — fetched through
/// `PhotoLibraryService.fetchAssets(year:month:)`, which is the same API the year/month
/// content panes use.
struct MonthTileView: View {
  /// Side length of the tile's image area. Larger than `FolderTileView.tileSide` (144)
  /// because the year overview has a fixed cardinality of 12 children — there's
  /// breathing room to give each cover more real estate without the grid feeling sparse.
  static let tileSide: CGFloat = 180

  let year: Int
  let month: Int
  /// Total photo count for the month, or `nil` while the count is still loading. The
  /// caption reserves a line of height during loading so tiles don't jump.
  let photoCount: Int?
  /// `true` when every photo in the month has been exported under the active version
  /// selection. Drives the green checkmark badge on the cover.
  let isFullyExported: Bool

  let photoLibraryService: any PhotoLibraryService

  @State private var covers: [NSImage] = []
  @State private var coverState: CoverState = .idle
  @State private var isHovering: Bool = false

  private enum CoverState {
    case idle
    case loading
    case loaded
    case empty
    case failed
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      coverArea
        .frame(width: Self.tileSide, height: Self.tileSide)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .topTrailing) { exportedBadge }

      Text(MonthFormatting.name(for: month))
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
    .accessibilityHint("Opens the month's photos")
    // Note: the wrapping `Button` in `YearContentView` already supplies `.isButton`,
    // so the trait isn't repeated here.
    .task(id: "\(year)-\(month)") {
      await loadCovers()
    }
  }

  // MARK: - Cover area

  @ViewBuilder
  private var coverArea: some View {
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

  /// Fully-exported badge. Uses palette rendering (white check inside a green disc) so
  /// the glyph sits cleanly on top of any thumbnail content without a separate flat
  /// white plate behind it — that plate read as a foreign sticker and was particularly
  /// loud in Dark Mode. A subtle shadow keeps the green readable over light covers.
  @ViewBuilder
  private var exportedBadge: some View {
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

  // MARK: - Captions

  private var captionText: String {
    guard let photoCount else { return " " }
    return photoCount == 1 ? "1 photo" : "\(photoCount) photos"
  }

  private var accessibilityLabel: String {
    var parts = ["Month", "\(MonthFormatting.name(for: month)) \(year)"]
    if let photoCount {
      parts.append(photoCount == 1 ? "1 photo" : "\(photoCount) photos")
    }
    if isFullyExported { parts.append("fully exported") }
    return parts.joined(separator: ", ")
  }

  // MARK: - Cover loading

  /// Loads up to four cover thumbnails for the month. Renders 1-up if the month has a
  /// single asset, 4-up otherwise. Thumbnail fetches dispatch into a `TaskGroup`; the
  /// underlying `loadThumbnail` is `@MainActor`-isolated so the calls serialise on the
  /// main actor, but each await yields the runloop and PhotoKit can prefetch in the
  /// background — fast enough in practice that the simpler structure beats threading a
  /// detached fetch through the service seam.
  ///
  /// `fetchAssets(in: .timeline(year:month:))` materialises the full month list, which is
  /// acceptable for v1 — the tile only builds when the year view is shown, and a typical
  /// month holds tens to hundreds of photos. A `firstAssets(in:limit:)` fast path on
  /// `PhotoLibraryService` is the natural follow-up if this proves a bottleneck on very
  /// large months.
  private func loadCovers() async {
    // Reset state on every run: the .task id changes when the user flips
    // years, but SwiftUI keeps each month-tile's @State alive across that
    // switch because `ForEach(months, id: \.self)` keys identity on the month
    // alone. Without an explicit reset, a year flip leaves the prior year's
    // thumbnails on screen even though the task is firing for the new year.
    covers = []
    coverState = .loading
    do {
      let assets = try await photoLibraryService.fetchAssets(
        in: .timeline(year: year, month: month), mediaType: nil)
      // The previous task (different year/month) may have already been cancelled by
      // SwiftUI's .task(id:) lifecycle, but its `await` could still resume and write
      // state for a tile that's no longer visible. Bail before publishing.
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
      // Don't change state on cancellation — the new task that replaced us will
      // publish its own state from `covers = []` and `coverState = .loading`.
    } catch {
      coverState = .failed
    }
  }
}
