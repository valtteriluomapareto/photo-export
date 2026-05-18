import Foundation
import Testing

@testable import Photo_Export

/// Cases from `docs/project/archive/collections-export-plan.md` §"Testing Plan → Placement
/// resolver". The resolver is the only code that maps a `LibrarySelection` to an
/// `ExportPlacement` for collection-side selections, so its determinism and collision
/// behavior are the only thing that keeps the on-disk paths stable across PhotoKit
/// traversal-order changes.
@MainActor
struct ExportPlacementResolverTests {

  // MARK: - Fixtures

  private func descriptor(
    id: String, title: String, parent: [String] = [], kind: PhotoCollectionDescriptor.Kind = .album,
    children: [PhotoCollectionDescriptor] = []
  ) -> PhotoCollectionDescriptor {
    PhotoCollectionDescriptor(
      id: "album:\(id)", localIdentifier: id, title: title, kind: kind,
      pathComponents: parent, children: children)
  }

  private func makeResolver(now: @escaping () -> Date = { Date(timeIntervalSince1970: 0) })
    -> ExportPlacementResolver
  {
    ExportPlacementResolver(now: now)
  }

  // MARK: - Timeline

  @Test func timelineSelectionResolvesToTimelinePlacement() throws {
    let resolver = makeResolver()
    let placement = try resolver.placement(
      for: .timelineMonth(year: 2025, month: 2),
      collections: [],
      existingPlacements: []
    )
    #expect(placement.kind == .timeline)
    #expect(placement.id == "timeline:2025-02")
    #expect(placement.relativePath == "2025/02/")
    #expect(placement.displayName == "2025/02")
  }

  // MARK: - Favorites

  @Test func favoritesResolvesToFixedPlacement() throws {
    let resolver = makeResolver()
    let placement = try resolver.placement(
      for: .favorites, collections: [], existingPlacements: [])
    #expect(placement.kind == .favorites)
    #expect(placement.id == "collections:favorites")
    #expect(placement.relativePath == "Collections/Favorites/")
    #expect(placement.displayName == "Favorites")
  }

  // MARK: - Album with nested folder

  @Test func albumWithNestedFolderProducesSanitizedPathAndHashedId() throws {
    let resolver = makeResolver()
    let album = descriptor(id: "abc-123", title: "Trip 2024", parent: ["Family"])
    let folder = descriptor(id: "family-id", title: "Family", kind: .folder, children: [album])
    let placement = try resolver.placement(
      for: .album(collectionId: "abc-123"),
      collections: [folder],
      existingPlacements: []
    )
    #expect(placement.kind == .album)
    #expect(placement.collectionLocalIdentifier == "abc-123")
    #expect(placement.relativePath == "Collections/Albums/Family/Trip 2024/")
    #expect(placement.displayName == "Family/Trip 2024")
    // Id format: collections:album:<16hex>:<8hex>
    #expect(placement.id.hasPrefix("collections:album:"))
    let parts = placement.id.split(separator: ":")
    #expect(parts.count == 4)
    #expect(parts[2].count == 16)
    #expect(parts[3].count == 8)
  }

  // MARK: - Identical title under same folder → distinct ids and paths

  @Test func twoAlbumsSameTitleSameFolderGetDistinctPlacements() throws {
    let resolver = makeResolver()
    let alpha = descriptor(id: "alpha", title: "Trip", parent: ["Family"])
    let beta = descriptor(id: "beta", title: "Trip", parent: ["Family"])
    let folder = descriptor(
      id: "family-id", title: "Family", kind: .folder, children: [alpha, beta])

    let pAlpha = try resolver.placement(
      for: .album(collectionId: "alpha"),
      collections: [folder], existingPlacements: [])
    let pBeta = try resolver.placement(
      for: .album(collectionId: "beta"),
      collections: [folder], existingPlacements: [])

    #expect(pAlpha.id != pBeta.id)
    #expect(pAlpha.relativePath != pBeta.relativePath)
    // Lex sort: "alpha" < "beta" so alpha gets bare, beta gets _2.
    #expect(pAlpha.relativePath == "Collections/Albums/Family/Trip/")
    #expect(pBeta.relativePath == "Collections/Albums/Family/Trip_2/")
  }

  /// Three colliding albums under the same folder, in shuffled descriptor order — the
  /// lex-sort tiebreaker means the assignment is identical regardless of order.
  @Test func threeCollidingAlbumsLexSortDeterministic() throws {
    let resolver = makeResolver()
    // Use shuffled order in the tree to verify the resolver doesn't depend on traversal.
    let charlie = descriptor(id: "charlie", title: "Trip")
    let alpha = descriptor(id: "alpha", title: "Trip")
    let beta = descriptor(id: "beta", title: "Trip")
    let collections = [charlie, alpha, beta]

    let pCharlie = try resolver.placement(
      for: .album(collectionId: "charlie"),
      collections: collections, existingPlacements: [])
    let pAlpha = try resolver.placement(
      for: .album(collectionId: "alpha"),
      collections: collections, existingPlacements: [])
    let pBeta = try resolver.placement(
      for: .album(collectionId: "beta"),
      collections: collections, existingPlacements: [])

    #expect(pAlpha.relativePath == "Collections/Albums/Trip/")
    #expect(pBeta.relativePath == "Collections/Albums/Trip_2/")
    #expect(pCharlie.relativePath == "Collections/Albums/Trip_3/")
  }

  // MARK: - Existing placement collisions

  @Test func newAlbumCollidingWithExistingGetsSuffix() throws {
    let resolver = makeResolver()
    let existing = ExportPlacement(
      kind: .album, id: "collections:album:hash16-old:hash8-old",
      displayName: "Trip", collectionLocalIdentifier: "old-album",
      relativePath: "Collections/Albums/Trip/",
      createdAt: Date(timeIntervalSince1970: 1000)
    )
    let newAlbum = descriptor(id: "new-album", title: "Trip")
    let placement = try resolver.placement(
      for: .album(collectionId: "new-album"),
      collections: [newAlbum],
      existingPlacements: [existing]
    )
    // Existing kept its bare path; new one gets _2.
    #expect(placement.relativePath == "Collections/Albums/Trip_2/")
  }

  @Test func newAlbumSkipsExistingSuffix() throws {
    let resolver = makeResolver()
    let bare = ExportPlacement(
      kind: .album, id: "collections:album:bare-hash:hash8",
      displayName: "Trip", collectionLocalIdentifier: "bare-id",
      relativePath: "Collections/Albums/Trip/",
      createdAt: Date(timeIntervalSince1970: 1000))
    let twoTaken = ExportPlacement(
      kind: .album, id: "collections:album:two-hash:hash8",
      displayName: "Trip", collectionLocalIdentifier: "two-id",
      relativePath: "Collections/Albums/Trip_2/",
      createdAt: Date(timeIntervalSince1970: 2000))
    let newAlbum = descriptor(id: "new", title: "Trip")
    let placement = try resolver.placement(
      for: .album(collectionId: "new"),
      collections: [newAlbum],
      existingPlacements: [bare, twoTaken]
    )
    #expect(placement.relativePath == "Collections/Albums/Trip_3/")
  }

  // MARK: - Rename detection

  /// Album rename → displayPathHash8 changes → resolver returns a new placement (the
  /// existing one is no longer matched by the (kind, collectionLocalIdentifier,
  /// displayPathHash8) triple).
  @Test func albumRenameProducesNewPlacementId() throws {
    let resolver = makeResolver()
    let renamed = descriptor(id: "abc", title: "Italy 2024")
    let priorPlacement = try resolver.placement(
      for: .album(collectionId: "abc"),
      collections: [descriptor(id: "abc", title: "Trip 2024")],
      existingPlacements: []
    )
    // Now the album was renamed to "Italy 2024"; the existing placement records
    // the old hash. Resolver should NOT match it on the new path-hash.
    let newPlacement = try resolver.placement(
      for: .album(collectionId: "abc"),
      collections: [renamed],
      existingPlacements: [priorPlacement]
    )
    #expect(newPlacement.id != priorPlacement.id)
    #expect(newPlacement.relativePath == "Collections/Albums/Italy 2024/")
  }

  /// Title with `/` produces a different displayPathHash8 than nested folder + album
  /// with the in-title separator interpreted structurally.
  @Test func titleWithSlashIsDistinguishedFromNestedFolder() throws {
    let resolver = makeResolver()
    // Album titled "Family/Trip" at root.
    let inTitle = descriptor(id: "id-1", title: "Family/Trip")
    // Album titled "Trip" inside folder "Family".
    let nested = descriptor(id: "id-2", title: "Trip", parent: ["Family"])

    let pTitle = try resolver.placement(
      for: .album(collectionId: "id-1"),
      collections: [inTitle], existingPlacements: [])
    let pNested = try resolver.placement(
      for: .album(collectionId: "id-2"),
      collections: [nested], existingPlacements: [])
    #expect(pTitle.id != pNested.id)  // displayPathHash8 differs because of the U+0000 separator
  }

  /// Regression: PhotoKit can return album titles in either Unicode normalization form
  /// (NFC composed: "é" as a single codepoint, NFD decomposed: "e" + combining acute).
  /// Two semantically-identical titles in different forms used to hash to different
  /// placement ids, so the same album silently relocated to a fresh on-disk folder
  /// across launches. The resolver now NFC-normalizes every component before hashing.
  @Test func nfcAndNfdTitleHashToSamePlacementId() throws {
    let resolver = makeResolver()
    // "Café" composed (NFC): U+0063 U+0061 U+0066 U+00E9.
    let nfc = "Caf\u{00E9}"
    // "Café" decomposed (NFD): U+0063 U+0061 U+0066 U+0065 U+0301.
    // Swift's String `==` is canonical-equivalence-aware, so `nfc == nfd` returns true,
    // but the underlying utf8 byte sequences differ (4 vs 5 bytes). The placement-id
    // hash takes `Data(string.utf8)`, so without normalization the two would still hash
    // differently — verify that's no longer the case.
    let nfd = "Cafe\u{0301}"
    #expect(
      Array(nfc.utf8) != Array(nfd.utf8),
      "fixture sanity: utf8 bytes must differ pre-normalization")

    let nfcDescriptor = descriptor(id: "id-cafe", title: nfc)
    let nfdDescriptor = descriptor(id: "id-cafe", title: nfd)

    let pNFC = try resolver.placement(
      for: .album(collectionId: "id-cafe"),
      collections: [nfcDescriptor], existingPlacements: [])
    let pNFD = try resolver.placement(
      for: .album(collectionId: "id-cafe"),
      collections: [nfdDescriptor], existingPlacements: [])

    #expect(pNFC.id == pNFD.id, "NFC vs NFD title must hash to the same placement id")
  }

  /// Same property for parent folder names: a folder titled "Café" in NFC vs NFD must
  /// not change the album's placement id either.
  @Test func nfcAndNfdParentFolderHashToSamePlacementId() throws {
    let resolver = makeResolver()
    let nfcParent = "Caf\u{00E9}"
    let nfdParent = "Cafe\u{0301}"

    let nfc = descriptor(id: "id-trip", title: "Trip", parent: [nfcParent])
    let nfd = descriptor(id: "id-trip", title: "Trip", parent: [nfdParent])

    let pNFC = try resolver.placement(
      for: .album(collectionId: "id-trip"),
      collections: [nfc], existingPlacements: [])
    let pNFD = try resolver.placement(
      for: .album(collectionId: "id-trip"),
      collections: [nfd], existingPlacements: [])

    #expect(pNFC.id == pNFD.id)
  }

  /// Regression: when album A has an old placement at a different path (e.g. it was
  /// renamed or moved) and is now collidng with album B at a new shared path, both must
  /// participate in collision resolution. Previously the filter excluded any descriptor
  /// with *any* existing placement, dropping A from the new sibling set and letting B
  /// take the bare path while A would also try to take it on its own resolve.
  @Test func renamedAlbumParticipatesInSiblingCollision() throws {
    let resolver = makeResolver()
    // Album A: old placement at "Old/Trip", now renamed to root-level "Trip".
    let albumARenamed = descriptor(id: "id-A", title: "Trip")
    // Album B: brand new, also titled "Trip" at root, no existing placement.
    let albumB = descriptor(id: "id-B", title: "Trip")
    let collections = [albumARenamed, albumB]

    // A has a stale placement under the old path-hash (different displayPathHash than the
    // new "Trip" at root would produce).
    let stalePlacement = ExportPlacement(
      kind: .album, id: "collections:album:hash16-A:stalehs",
      displayName: "Old/Trip", collectionLocalIdentifier: "id-A",
      relativePath: "Collections/Albums/Old/Trip/",
      createdAt: Date(timeIntervalSince1970: 1000)
    )

    let placementA = try resolver.placement(
      for: .album(collectionId: "id-A"),
      collections: collections, existingPlacements: [stalePlacement])
    let placementB = try resolver.placement(
      for: .album(collectionId: "id-B"),
      collections: collections, existingPlacements: [stalePlacement])

    #expect(placementA.relativePath != placementB.relativePath)
    // A and B sort lexicographically by collectionLocalIdentifier ("id-A" < "id-B"); the
    // stale placement is at a different path so it doesn't claim "Trip". Both A and B
    // are new claimants for the bare path → A gets bare, B gets _2.
    #expect(placementA.relativePath == "Collections/Albums/Trip/")
    #expect(placementB.relativePath == "Collections/Albums/Trip_2/")
  }

  // MARK: - Multiple existing matches → pick latest

  @Test func multipleExistingMatchesPicksLatestCreatedAt() throws {
    let resolver = makeResolver()
    let album = descriptor(id: "shared", title: "Trip")
    // Pre-compute the canonical id by resolving once with no existing.
    let canonical = try resolver.placement(
      for: .album(collectionId: "shared"),
      collections: [album], existingPlacements: [])
    let older = ExportPlacement(
      kind: .album, id: canonical.id,
      displayName: canonical.displayName,
      collectionLocalIdentifier: "shared",
      relativePath: canonical.relativePath,
      createdAt: Date(timeIntervalSince1970: 1000))
    let newer = ExportPlacement(
      kind: .album, id: canonical.id,
      displayName: canonical.displayName,
      collectionLocalIdentifier: "shared",
      relativePath: canonical.relativePath,
      createdAt: Date(timeIntervalSince1970: 5000))

    let resolved = try resolver.placement(
      for: .album(collectionId: "shared"),
      collections: [album], existingPlacements: [older, newer])
    #expect(resolved.createdAt == newer.createdAt)
  }

  // MARK: - Missing album

  @Test func missingAlbumThrows() {
    let resolver = makeResolver()
    #expect(throws: ExportPlacementResolver.ResolutionError.albumNotFound(collectionId: "ghost")) {
      _ = try resolver.placement(
        for: .album(collectionId: "ghost"),
        collections: [], existingPlacements: [])
    }
  }

  /// Folder selections must throw — folders are not their own placements.
  /// `ExportManager.startExportFolder` walks the subtree and resolves each descendant
  /// album individually; the resolver itself never produces a folder placement.
  @Test func folderSelectionThrowsFolderNotResolvable() {
    let resolver = makeResolver()
    #expect(
      throws: ExportPlacementResolver.ResolutionError.folderNotResolvable(
        collectionId: "F1")
    ) {
      _ = try resolver.placement(
        for: .folder(collectionId: "F1"),
        collections: [], existingPlacements: [])
    }
  }

  // MARK: - Shared albums

  /// Helper for `.sharedAlbum` descriptors. PhotoKit doesn't nest shared albums,
  /// so `pathComponents` is always empty — the helper enforces that contract.
  private func sharedDescriptor(id: String, title: String) -> PhotoCollectionDescriptor {
    PhotoCollectionDescriptor(
      id: "shared-album:\(id)", localIdentifier: id, title: title,
      kind: .sharedAlbum, pathComponents: [], children: [])
  }

  /// Shared albums resolve under their own root and carry the `shared-album`
  /// placement-id prefix, distinct from user albums. The id-format invariant
  /// (`collections:shared-album:<hash16>:<hash8>`) gates downstream label
  /// derivation in `ExportIssuesView` and is what `AutoSyncRetryScopeKey`'s
  /// `init?(rawValue:)` reads to disambiguate buckets.
  @Test func sharedAlbumResolvesUnderSharedAlbumsRoot() throws {
    let resolver = makeResolver()
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
    #expect(parts[2].count == 16)
    #expect(parts[3].count == 8)
  }

  @Test func sharedAlbumSanitizesPathSeparatorsInTitle() throws {
    let resolver = makeResolver()
    let desc = sharedDescriptor(id: "shared-2", title: "Trip / 2024")
    let placement = try resolver.placement(
      for: .sharedAlbum(collectionId: "shared-2"),
      collections: [desc], existingPlacements: [])
    #expect(placement.relativePath == "Collections/Shared Albums/Trip _ 2024/")
  }

  /// Two shared albums with the same sanitized title collide and disambiguate
  /// via the lex-sort-on-`collectionLocalIdentifier` tiebreaker. Mirrors the
  /// album-side `twoAlbumsSameTitleSameFolderGetDistinctPlacements` test.
  @Test func twoSharedAlbumsSameTitleGetDistinctPaths() throws {
    let resolver = makeResolver()
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

  /// Cross-kind disjointness: a user album titled "Trip" and a shared album
  /// titled "Trip" cannot collide because they live under different path
  /// prefixes. This is the invariant that lets `sharedAlbumLeafWithCollisionSuffix`
  /// limit its sibling search to other `.sharedAlbum` placements only — if a
  /// future refactor unifies the two trees, this test fails and forces a
  /// rethink of the collision domain.
  @Test func sharedAlbumDoesNotCollideWithUserAlbum() throws {
    let resolver = makeResolver()
    let user = descriptor(id: "user-1", title: "Trip")
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

  /// Missing shared album surfaces the same `albumNotFound` error as a missing
  /// user album. Callers don't need a parallel error path.
  @Test func missingSharedAlbumThrowsAlbumNotFound() {
    let resolver = makeResolver()
    #expect(
      throws: ExportPlacementResolver.ResolutionError.albumNotFound(collectionId: "ghost")
    ) {
      _ = try resolver.placement(
        for: .sharedAlbum(collectionId: "ghost"),
        collections: [], existingPlacements: [])
    }
  }

  /// Multiple existing placements that match the same `(kind, collectionId,
  /// displayPathHash8)` triple — defensive recovery from a buggy past write —
  /// pick the one with the latest `createdAt`. Mirrors the album-side
  /// `multipleExistingMatchesPicksLatestCreatedAt` test; without it the
  /// `resolveSharedAlbum.matches.count > 1` warning branch sits untested.
  @Test func multipleExistingSharedAlbumMatchesPicksLatestCreatedAt() throws {
    let resolver = makeResolver()
    let desc = sharedDescriptor(id: "shared-1", title: "Family")
    let canonical = try resolver.placement(
      for: .sharedAlbum(collectionId: "shared-1"),
      collections: [desc], existingPlacements: [])
    let older = ExportPlacement(
      kind: .sharedAlbum, id: canonical.id,
      displayName: canonical.displayName,
      collectionLocalIdentifier: "shared-1",
      relativePath: canonical.relativePath,
      createdAt: Date(timeIntervalSince1970: 1000))
    let newer = ExportPlacement(
      kind: .sharedAlbum, id: canonical.id,
      displayName: canonical.displayName,
      collectionLocalIdentifier: "shared-1",
      relativePath: canonical.relativePath,
      createdAt: Date(timeIntervalSince1970: 5000))

    let resolved = try resolver.placement(
      for: .sharedAlbum(collectionId: "shared-1"),
      collections: [desc], existingPlacements: [older, newer])
    #expect(resolved.createdAt == newer.createdAt)
  }

  /// Renaming a shared album produces a new placement id — the `displayPathHash8`
  /// component changes so the prior placement is no longer matched. The on-disk
  /// folder for the rename's *new* path is fresh; the old folder stays behind
  /// for the user to clean up (mirrors album-side rename behaviour).
  @Test func sharedAlbumRenameProducesNewPlacementId() throws {
    let resolver = makeResolver()
    let priorDesc = sharedDescriptor(id: "shared-1", title: "Old Title")
    let priorPlacement = try resolver.placement(
      for: .sharedAlbum(collectionId: "shared-1"),
      collections: [priorDesc], existingPlacements: [])

    let renamed = sharedDescriptor(id: "shared-1", title: "New Title")
    let newPlacement = try resolver.placement(
      for: .sharedAlbum(collectionId: "shared-1"),
      collections: [renamed], existingPlacements: [priorPlacement])

    #expect(newPlacement.id != priorPlacement.id)
    #expect(newPlacement.relativePath == "Collections/Shared Albums/New Title/")
  }
}
