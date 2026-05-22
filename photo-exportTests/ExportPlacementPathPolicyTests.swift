import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Tests for the `ExportPlacementPathPolicy` helper (issue #38). Two pure functions:
///
/// - `subfolder(for:layout:)` decides whether an asset's variants go into a `videos/`
///   subfolder inside the placement. Keys on the asset's `mediaType`, NOT the variant
///   kind, so Live Photo paired motion (image-mediaType, paired-video variant) stays
///   with its still — only standalone-video assets move.
/// - `relativePath(placement:subfolder:)` is path arithmetic; reused by reuse-source,
///   reconcile, and the chokepoint in `ExportManager.runJob`.
struct ExportPlacementPathPolicyTests {

  // MARK: - subfolder(for:layout:)

  @Test func subfolderFlatLayoutAlwaysNil() {
    // Flat layout never produces a subfolder regardless of mediaType.
    for mediaType: PHAssetMediaType in [.image, .video, .audio, .unknown] {
      #expect(ExportPlacementPathPolicy.subfolder(for: mediaType, layout: .flat) == nil)
    }
  }

  /// Image-mediaType assets stay at the bare placement path even with subfolder ON —
  /// this is the load-bearing Live Photo carve-out. A Live Photo's paired motion variant
  /// belongs to an image asset and must NOT move into videos/, or it would split the
  /// still + motion pair across folders and break on-disk Live Photo pairing.
  @Test func subfolderSubfolderLayoutImageReturnsNil() {
    #expect(ExportPlacementPathPolicy.subfolder(for: .image, layout: .subfolder) == nil)
  }

  @Test func subfolderSubfolderLayoutVideoReturnsVideos() {
    #expect(ExportPlacementPathPolicy.subfolder(for: .video, layout: .subfolder) == "videos")
  }

  @Test func subfolderSubfolderLayoutAudioReturnsNil() {
    // Audio assets fall through; the subfolder rule only fires for `mediaType == .video`.
    #expect(ExportPlacementPathPolicy.subfolder(for: .audio, layout: .subfolder) == nil)
  }

  @Test func subfolderSubfolderLayoutUnknownReturnsNil() {
    // `.unknown` mediaType falls through to nil. Pins that any future mediaType added
    // by PhotoKit defaults to bare placement until explicitly opted in.
    #expect(ExportPlacementPathPolicy.subfolder(for: .unknown, layout: .subfolder) == nil)
  }

  // MARK: - relativePath(placement:subfolder:)

  /// `nil` subfolder resolves to the bare placement path across every placement kind.
  @Test func relativePathNilSubfolderReturnsPlacementPath() {
    let timeline = ExportPlacement.timeline(year: 2026, month: 3)
    let favorites = ExportPlacement.favorites()
    let album = makeAlbumPlacement()
    let sharedAlbum = makeSharedAlbumPlacement()
    for placement in [timeline, favorites, album, sharedAlbum] {
      #expect(
        ExportPlacementPathPolicy.relativePath(placement: placement, subfolder: nil)
          == placement.relativePath)
    }
  }

  /// An empty-string subfolder is treated as nil (no spurious `/` appended).
  @Test func relativePathEmptySubfolderTreatedAsNil() {
    let timeline = ExportPlacement.timeline(year: 2026, month: 3)
    #expect(
      ExportPlacementPathPolicy.relativePath(placement: timeline, subfolder: "")
        == timeline.relativePath)
  }

  @Test func relativePathVideosSubfolderTimeline() {
    let timeline = ExportPlacement.timeline(year: 2026, month: 3)
    #expect(
      ExportPlacementPathPolicy.relativePath(placement: timeline, subfolder: "videos")
        == "2026/03/videos/")
  }

  @Test func relativePathVideosSubfolderFavorites() {
    let favorites = ExportPlacement.favorites()
    #expect(
      ExportPlacementPathPolicy.relativePath(placement: favorites, subfolder: "videos")
        == "Collections/Favorites/videos/")
  }

  @Test func relativePathVideosSubfolderAlbum() {
    let album = makeAlbumPlacement()
    let expected = album.relativePath + "videos/"
    #expect(
      ExportPlacementPathPolicy.relativePath(placement: album, subfolder: "videos") == expected)
  }

  @Test func relativePathVideosSubfolderSharedAlbum() {
    let sharedAlbum = makeSharedAlbumPlacement()
    let expected = sharedAlbum.relativePath + "videos/"
    #expect(
      ExportPlacementPathPolicy.relativePath(placement: sharedAlbum, subfolder: "videos")
        == expected)
  }

  // MARK: - Fixtures

  private func makeAlbumPlacement() -> ExportPlacement {
    ExportPlacement(
      kind: .album,
      id: "collections:album:abc:def",
      displayName: "Trip",
      collectionLocalIdentifier: "trip-id",
      relativePath: "Collections/Albums/Trip/",
      createdAt: Date(timeIntervalSinceReferenceDate: 0))
  }

  private func makeSharedAlbumPlacement() -> ExportPlacement {
    ExportPlacement(
      kind: .sharedAlbum,
      id: "collections:shared-album:abc:def",
      displayName: "Shared Trip",
      collectionLocalIdentifier: "shared-id",
      relativePath: "Collections/Shared Albums/Shared Trip/",
      createdAt: Date(timeIntervalSinceReferenceDate: 0))
  }
}
