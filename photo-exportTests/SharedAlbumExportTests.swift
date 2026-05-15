import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Tests for iCloud shared album support (issue #48). Cover four surfaces:
/// - Resolver: `.sharedAlbum` selections land under `Collections/Shared Albums/`,
///   carry the `shared-album` placement-id prefix, and collide independently from
///   user albums.
/// - Path partition: `PhotoCollectionDescriptor.albumLocalIds(in:)` skips shared
///   albums so "Export All Albums" never picks them up.
/// - Reduced-fidelity flag: `requiredVariants(...)` clamps to `[.original]` for
///   `.sharedAlbum` placements regardless of `hasAdjustments` or the version
///   selection. This is the "Include originals is a no-op" guarantee.
/// - Fake service plumbing: the fetch/count paths accept `.sharedAlbum` scopes and
///   return the canned per-shared-album fixtures.
@MainActor
struct SharedAlbumExportTests {

  // MARK: - Fixtures

  private func makeAsset(id: String, adjusted: Bool = false) -> AssetDescriptor {
    AssetDescriptor(
      id: id,
      creationDate: Date(timeIntervalSince1970: 1_700_000_000),
      mediaType: .image,
      pixelWidth: 100,
      pixelHeight: 100,
      duration: 0,
      hasAdjustments: adjusted
    )
  }

  private func sharedDescriptor(id: String, title: String) -> PhotoCollectionDescriptor {
    PhotoCollectionDescriptor(
      id: "shared-album:\(id)", localIdentifier: id, title: title, kind: .sharedAlbum,
      pathComponents: [], children: [])
  }

  // MARK: - Resolver: path + id format

  @Test func sharedAlbumResolvesUnderSharedAlbumsRoot() throws {
    let resolver = ExportPlacementResolver(now: { Date(timeIntervalSince1970: 0) })
    let desc = sharedDescriptor(id: "shared-1", title: "Family Trip")
    let placement = try resolver.placement(
      for: .sharedAlbum(collectionId: "shared-1"),
      collections: [desc], existingPlacements: [])

    #expect(placement.kind == .sharedAlbum)
    #expect(placement.collectionLocalIdentifier == "shared-1")
    #expect(placement.relativePath == "Collections/Shared Albums/Family Trip/")
    #expect(placement.displayName == "Family Trip")
    #expect(placement.id.hasPrefix("collections:shared-album:"))
    let parts = placement.id.split(separator: ":")
    #expect(parts.count == 4)
    #expect(parts[2].count == 16)  // collectionIdHash16
    #expect(parts[3].count == 8)  // displayPathHash8
  }

  @Test func sharedAlbumWithSpecialCharsIsSanitized() throws {
    let resolver = ExportPlacementResolver(now: { Date(timeIntervalSince1970: 0) })
    let desc = sharedDescriptor(id: "shared-2", title: "Trip / 2024")
    let placement = try resolver.placement(
      for: .sharedAlbum(collectionId: "shared-2"),
      collections: [desc], existingPlacements: [])
    // `/` is a path separator and must be replaced.
    #expect(placement.relativePath == "Collections/Shared Albums/Trip _ 2024/")
  }

  /// Two shared albums with the same sanitized title collide; lex-sort by collection id
  /// decides who keeps the bare path.
  @Test func twoSharedAlbumsSameTitleGetDistinctPaths() throws {
    let resolver = ExportPlacementResolver(now: { Date(timeIntervalSince1970: 0) })
    let alpha = sharedDescriptor(id: "alpha", title: "Trip")
    let beta = sharedDescriptor(id: "beta", title: "Trip")
    let collections = [alpha, beta]
    let pAlpha = try resolver.placement(
      for: .sharedAlbum(collectionId: "alpha"),
      collections: collections, existingPlacements: [])
    let pBeta = try resolver.placement(
      for: .sharedAlbum(collectionId: "beta"),
      collections: collections, existingPlacements: [])

    #expect(pAlpha.relativePath == "Collections/Shared Albums/Trip/")
    #expect(pBeta.relativePath == "Collections/Shared Albums/Trip_2/")
  }

  /// A user album and a shared album with the same sanitized title don't collide —
  /// they live under disjoint root paths.
  @Test func sharedAlbumDoesNotCollideWithUserAlbum() throws {
    let resolver = ExportPlacementResolver(now: { Date(timeIntervalSince1970: 0) })
    let user = PhotoCollectionDescriptor(
      id: "album:user-1", localIdentifier: "user-1", title: "Trip", kind: .album,
      pathComponents: [], children: [])
    let shared = sharedDescriptor(id: "shared-1", title: "Trip")
    let collections = [user, shared]

    let pUser = try resolver.placement(
      for: .album(collectionId: "user-1"),
      collections: collections, existingPlacements: [])
    let pShared = try resolver.placement(
      for: .sharedAlbum(collectionId: "shared-1"),
      collections: collections, existingPlacements: [])

    #expect(pUser.relativePath == "Collections/Albums/Trip/")
    #expect(pShared.relativePath == "Collections/Shared Albums/Trip/")
    #expect(pUser.id != pShared.id)
  }

  /// Missing shared album surfaces the same `albumNotFound` error as missing user album.
  /// We reuse the existing error case so callers don't need a parallel error path.
  @Test func missingSharedAlbumThrowsAlbumNotFound() {
    let resolver = ExportPlacementResolver(now: { Date(timeIntervalSince1970: 0) })
    #expect(
      throws: ExportPlacementResolver.ResolutionError.albumNotFound(collectionId: "ghost")
    ) {
      _ = try resolver.placement(
        for: .sharedAlbum(collectionId: "ghost"),
        collections: [], existingPlacements: [])
    }
  }

  /// Resolving a shared album twice with the same id returns the same placement, so
  /// subsequent runs reuse the persisted createdAt and relativePath. This is the
  /// "existing-match" branch of the resolver.
  @Test func sharedAlbumReusesExistingPlacement() throws {
    let resolver = ExportPlacementResolver(now: { Date(timeIntervalSince1970: 5000) })
    let desc = sharedDescriptor(id: "shared-1", title: "Trip")
    let prior = try resolver.placement(
      for: .sharedAlbum(collectionId: "shared-1"),
      collections: [desc], existingPlacements: [])
    let again = try resolver.placement(
      for: .sharedAlbum(collectionId: "shared-1"),
      collections: [desc], existingPlacements: [prior])
    #expect(again.id == prior.id)
    #expect(again.createdAt == prior.createdAt)
  }

  // MARK: - Tree partitioning

  /// `albumLocalIds(in:)` walks the user-album tree only. Shared albums must not be
  /// returned even when present at the top level, so "Export All Albums" doesn't pull
  /// them in.
  @Test func albumLocalIdsExcludesSharedAlbums() {
    let user = PhotoCollectionDescriptor(
      id: "album:user-1", localIdentifier: "user-1", title: "Trip", kind: .album,
      pathComponents: [], children: [])
    let shared = sharedDescriptor(id: "shared-1", title: "Family")
    let ids = PhotoCollectionDescriptor.albumLocalIds(in: [user, shared])
    #expect(ids == ["user-1"])
  }

  @Test func sharedAlbumLocalIdsReturnsOnlySharedTopLevel() {
    let user = PhotoCollectionDescriptor(
      id: "album:user-1", localIdentifier: "user-1", title: "Trip", kind: .album,
      pathComponents: [], children: [])
    let s1 = sharedDescriptor(id: "shared-1", title: "Family")
    let s2 = sharedDescriptor(id: "shared-2", title: "Friends")
    let folder = PhotoCollectionDescriptor(
      id: "folder:f", localIdentifier: "f", title: "Folder", kind: .folder,
      pathComponents: [], children: [user])
    let ids = PhotoCollectionDescriptor.sharedAlbumLocalIds(in: [folder, s1, s2])
    #expect(ids == ["shared-1", "shared-2"])
  }

  // MARK: - VariantPolicy / single-resource clamp

  /// Adjusted asset under `.singleResource` must collapse to `[.original]` regardless
  /// of selection mode. This is what makes "Include originals" a no-op for shared
  /// albums.
  @Test func singleResourcePolicyClampsAdjustedAssetToOriginal() {
    let adjusted = makeAsset(id: "a", adjusted: true)
    let edited = requiredVariants(
      for: adjusted, selection: .edited, policy: .singleResource)
    let withOrig = requiredVariants(
      for: adjusted, selection: .editedWithOriginals, policy: .singleResource)
    #expect(edited == [.original])
    #expect(withOrig == [.original])
  }

  @Test func singleResourcePolicyClampsUnadjustedAssetToOriginal() {
    let unadjusted = makeAsset(id: "b", adjusted: false)
    let edited = requiredVariants(
      for: unadjusted, selection: .edited, policy: .singleResource)
    let withOrig = requiredVariants(
      for: unadjusted, selection: .editedWithOriginals, policy: .singleResource)
    #expect(edited == [.original])
    #expect(withOrig == [.original])
  }

  /// Sanity check: `.standard` policy still honours the selection. Confirms the
  /// clamp is scoped to `.singleResource`.
  @Test func standardPolicyHonoursEditedWithOriginals() {
    let adjusted = makeAsset(id: "a", adjusted: true)
    let result = requiredVariants(
      for: adjusted, selection: .editedWithOriginals, policy: .standard)
    #expect(result == [.original, .edited])
  }

  // MARK: - ExportPlacement.Kind.variantPolicy

  @Test func sharedAlbumKindReturnsSingleResourcePolicy() {
    #expect(ExportPlacement.Kind.sharedAlbum.variantPolicy == .singleResource)
    #expect(ExportPlacement.Kind.timeline.variantPolicy == .standard)
    #expect(ExportPlacement.Kind.favorites.variantPolicy == .standard)
    #expect(ExportPlacement.Kind.album.variantPolicy == .standard)
  }

  // MARK: - Fake fetch + count

  @Test func fakeServiceServesSharedAlbumScope() async throws {
    let svc = FakePhotoLibraryService()
    svc.assetsBySharedAlbumLocalId["shared-1"] = [
      makeAsset(id: "s1"), makeAsset(id: "s2"),
    ]
    svc.assetsByAlbumLocalId["album-1"] = [makeAsset(id: "a1")]

    let shared = try await svc.fetchAssets(
      in: .sharedAlbum(collectionId: "shared-1"), mediaType: nil)
    let user = try await svc.fetchAssets(
      in: .album(collectionId: "album-1"), mediaType: nil)

    #expect(shared.map(\.id) == ["s1", "s2"])
    #expect(user.map(\.id) == ["a1"])

    let sharedCount = try await svc.countAssets(in: .sharedAlbum(collectionId: "shared-1"))
    #expect(sharedCount == 2)
  }

  // MARK: - CollectionExportRecordStore: shared-album record routing

  /// The collection record store accepts `.sharedAlbum` placements just like
  /// `.album` and `.favorites`. This guards the `accept(_:)` gate from regressing
  /// (it was previously a `.timeline`-only refuse).
  @Test func collectionStoreAcceptsSharedAlbumPlacement() throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("shared-album-store-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let store = CollectionExportRecordStore(baseDirectoryURL: tempDir)
    store.configure(for: "dest-1")

    let placement = ExportPlacement(
      kind: .sharedAlbum, id: "collections:shared-album:h16:h8",
      displayName: "Family", collectionLocalIdentifier: "shared-1",
      relativePath: "Collections/Shared Albums/Family/",
      createdAt: Date(timeIntervalSince1970: 1000))
    store.upsertPlacement(placement)
    store.flushForTesting()

    #expect(store.placement(id: placement.id)?.kind == .sharedAlbum)
    #expect(store.placements(matching: .sharedAlbum).count == 1)
  }

  @Test func collectionStoreRecordCountIncludesSharedAlbum() {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("shared-album-recordcount-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let store = CollectionExportRecordStore(baseDirectoryURL: tempDir)
    store.configure(for: "dest-1")

    let placement = ExportPlacement(
      kind: .sharedAlbum, id: "collections:shared-album:h16:h8",
      displayName: "Family", collectionLocalIdentifier: "shared-1",
      relativePath: "Collections/Shared Albums/Family/",
      createdAt: Date(timeIntervalSince1970: 1000))
    store.upsertPlacement(placement)
    store.markVariantExported(
      assetId: "asset-1", placement: placement, variant: .original,
      filename: "asset-1.jpg", exportedAt: Date(timeIntervalSince1970: 2000))
    store.flushForTesting()

    #expect(store.recordCount(in: .sharedAlbum(collectionLocalId: "shared-1")) == 1)
    #expect(store.recordCount(in: .album(collectionLocalId: "shared-1")) == 0)
    #expect(store.recordCount(in: .any) == 1)
  }
}
