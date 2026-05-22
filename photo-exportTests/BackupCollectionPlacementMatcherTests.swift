import Foundation
import Testing

@testable import Photo_Export

/// Unit tests for `BackupCollectionPlacementMatcher.match(...)`.
///
/// Pure helper, no Photos integration needed: fixtures are hand-built
/// `PhotoCollectionDescriptor` trees and `ExportPlacement` arrays.
///
/// The plan's load-bearing concerns:
/// - Existing-placement reuse takes priority over PhotoKit search.
/// - The `Trip_2` matrix (rename vs sibling-collision suffix) — the resolver
///   is the sole authority on suffix assignment, so the matcher must not
///   strip `_N` heuristically.
/// - Post-resolver path-equality guard catches the "resolver returned a
///   different leaf than what's on disk" case (would otherwise mis-route
///   records that the same import's reconcile pass would then prune).
/// - Sanitization non-injectivity tie → orphan.
struct BackupCollectionPlacementMatcherTests {

  // MARK: - Favorites

  @Test func favorites_withExistingPlacement_reuses() {
    let existing = ExportPlacement.favorites(createdAt: Date(timeIntervalSince1970: 100))
    let matcher = BackupCollectionPlacementMatcher()
    let group = makeGroup(kind: .favorites, leaf: "Favorites")
    let outcome = matcher.match(
      group: group, photoCollections: [], existingPlacements: [existing])
    switch outcome {
    case .existing(let placement):
      #expect(placement.id == "collections:favorites")
      #expect(placement.createdAt.timeIntervalSince1970 == 100)
    default:
      Issue.record("expected .existing, got \(outcome)")
    }
  }

  @Test func favorites_noExisting_emitsFresh() {
    let matcher = BackupCollectionPlacementMatcher()
    let group = makeGroup(kind: .favorites, leaf: "Favorites")
    let outcome = matcher.match(
      group: group, photoCollections: [], existingPlacements: [])
    switch outcome {
    case .fresh(let placement):
      #expect(placement.id == "collections:favorites")
      #expect(placement.relativePath == "Collections/Favorites/")
    default:
      Issue.record("expected .fresh, got \(outcome)")
    }
  }

  // MARK: - Albums — Trip_2 matrix

  @Test func album_existingPlacementAtBareLeaf_isReused() {
    let collectionA = albumDescriptor(id: "A", title: "Trip")
    let existing = albumPlacement(
      collectionId: "A", title: "Trip", relativePath: "Collections/Albums/Trip/")
    let matcher = BackupCollectionPlacementMatcher()
    let group = makeGroup(kind: .album, leaf: "Trip")
    let outcome = matcher.match(
      group: group, photoCollections: [collectionA], existingPlacements: [existing])
    #expect(outcome == .existing(existing))
  }

  @Test func album_existingTrip2_literalUnderscoreName_isReused() {
    // PhotoKit's literal album title is "Trip_2"; existing placement matches.
    let collectionA = albumDescriptor(id: "A", title: "Trip_2")
    let existing = albumPlacement(
      collectionId: "A", title: "Trip_2", relativePath: "Collections/Albums/Trip_2/")
    let matcher = BackupCollectionPlacementMatcher()
    let group = makeGroup(kind: .album, leaf: "Trip_2")
    let outcome = matcher.match(
      group: group, photoCollections: [collectionA], existingPlacements: [existing])
    #expect(outcome == .existing(existing))
  }

  @Test func album_existingTrip2_historicalCollisionSuffix_isReused() {
    // Two PhotoKit albums titled "Trip". Existing placements: collectionA at
    // bare Trip/, collectionB at Trip_2/ (historical suffix from when both were
    // first exported). The on-disk `Trip_2/` reuses collectionB's placement.
    let collectionA = albumDescriptor(id: "A", title: "Trip")
    let collectionB = albumDescriptor(id: "B", title: "Trip")
    let existingA = albumPlacement(
      collectionId: "A", title: "Trip", relativePath: "Collections/Albums/Trip/")
    let existingB = albumPlacement(
      collectionId: "B", title: "Trip", relativePath: "Collections/Albums/Trip_2/")
    let matcher = BackupCollectionPlacementMatcher()
    let group = makeGroup(kind: .album, leaf: "Trip_2")
    let outcome = matcher.match(
      group: group,
      photoCollections: [collectionA, collectionB],
      existingPlacements: [existingA, existingB])
    #expect(outcome == .existing(existingB))
  }

  @Test func album_freshLiteralUnderscoreName_resolverAgrees() {
    let collectionA = albumDescriptor(id: "A", title: "Trip_2")
    let matcher = BackupCollectionPlacementMatcher()
    let group = makeGroup(kind: .album, leaf: "Trip_2")
    let outcome = matcher.match(
      group: group, photoCollections: [collectionA], existingPlacements: [])
    switch outcome {
    case .fresh(let placement):
      #expect(placement.relativePath == "Collections/Albums/Trip_2/")
      #expect(placement.collectionLocalIdentifier == "A")
    default:
      Issue.record("expected .fresh, got \(outcome)")
    }
  }

  @Test func album_noPhotoKitMatchForTrip2_orphan() {
    // On-disk leaf `Trip_2`, only "Trip" exists in PhotoKit. Plan §3 case 4:
    // the matcher must NOT retroactively assign collectionA the `_2` suffix.
    let collectionA = albumDescriptor(id: "A", title: "Trip")
    let matcher = BackupCollectionPlacementMatcher()
    let group = makeGroup(kind: .album, leaf: "Trip_2")
    let outcome = matcher.match(
      group: group, photoCollections: [collectionA], existingPlacements: [])
    #expect(outcome == .orphan(.noPhotoKitCollection))
  }

  @Test func album_threeWayCollisionOnDisk_onlyOnePhotoKitMatch() {
    // Folders Trip/, Trip_2/, Trip_3/ all exist on disk; only "Trip" exists
    // in PhotoKit. Trip/ reuses the existing placement; Trip_2/ and Trip_3/
    // orphan because they have no PhotoKit equivalent.
    let collectionA = albumDescriptor(id: "A", title: "Trip")
    let existing = albumPlacement(
      collectionId: "A", title: "Trip", relativePath: "Collections/Albums/Trip/")
    let matcher = BackupCollectionPlacementMatcher()

    let g1 = makeGroup(kind: .album, leaf: "Trip")
    let g2 = makeGroup(kind: .album, leaf: "Trip_2")
    let g3 = makeGroup(kind: .album, leaf: "Trip_3")
    #expect(
      matcher.match(group: g1, photoCollections: [collectionA], existingPlacements: [existing])
        == .existing(existing))
    #expect(
      matcher.match(group: g2, photoCollections: [collectionA], existingPlacements: [existing])
        == .orphan(.noPhotoKitCollection))
    #expect(
      matcher.match(group: g3, photoCollections: [collectionA], existingPlacements: [existing])
        == .orphan(.noPhotoKitCollection))
  }

  @Test func album_staleExistingPlacementForDeletedAlbum_isAuthoritative() {
    // Plan §"Stale placements as historical authority": an existing
    // placement at Trip_2/ for collectionDeleted (no longer in PhotoKit) is
    // still load-bearing — it encodes the user's prior suffix assignment.
    // The matcher must reuse it on import.
    let collectionA = albumDescriptor(id: "A", title: "Trip")
    let staleExisting = albumPlacement(
      collectionId: "deleted",
      title: "Trip",
      relativePath: "Collections/Albums/Trip_2/")
    let matcher = BackupCollectionPlacementMatcher()
    let group = makeGroup(kind: .album, leaf: "Trip_2")
    let outcome = matcher.match(
      group: group,
      photoCollections: [collectionA],
      existingPlacements: [staleExisting])
    #expect(outcome == .existing(staleExisting))
  }

  // The `.resolverDisagreesWithOnDiskLeaf` orphan branch is **defensive**:
  // structurally unreachable given the matcher's step 1 (byte-equal existing
  // placement lookup) and step 2 (sanitized-title PhotoKit search), which
  // collectively catch every scenario where the resolver would produce a
  // path that disagrees with the on-disk leaf. Specifically, any setup that
  // would force the resolver to suffix-disambiguate would also produce an
  // existing-placement at the on-disk leaf or fail the sanitized-title
  // search at step 2. The branch is kept in `OrphanReason` so the guard
  // catches a regression if a future change relaxes step 1 (e.g. to a
  // looser match). No regression test fires it today — exercising it
  // would require constructing inputs that violate the current sanitizer
  // contract.

  @Test func album_ambiguousPhotoKitMatch_orphan() {
    // Two distinct PhotoKit albums sanitize to the same on-disk leaf.
    // Auto-tie-break would silently favor one rename history — orphan instead.
    // ("Trip:" and "Trip_" both sanitize to "Trip_".)
    let collectionA = albumDescriptor(id: "A", title: "Trip:")
    let collectionB = albumDescriptor(id: "B", title: "Trip_")
    let matcher = BackupCollectionPlacementMatcher()
    let group = makeGroup(kind: .album, leaf: "Trip_")
    let outcome = matcher.match(
      group: group,
      photoCollections: [collectionA, collectionB],
      existingPlacements: [])
    switch outcome {
    case .orphan(.ambiguousPhotoKitMatch(let candidateIds)):
      #expect(candidateIds == ["A", "B"])
    default:
      Issue.record("expected ambiguousPhotoKitMatch, got \(outcome)")
    }
  }

  // MARK: - Albums — NFC/NFD normalization

  @Test func album_titleInDifferentNormalizationForm_sameOnDiskLeaf() {
    // PhotoKit returns the title in NFD on one launch, NFC on another. The
    // resolver's `displayPathHash8` normalizes to NFC before hashing, so
    // both end up matching the same on-disk leaf and producing the same
    // placement id. Pinned end-to-end here so the resolver's normalization
    // stays load-bearing.
    let titleNFD = "Cafe\u{0301}"  // "Café" in NFD
    let titleNFC = "Caf\u{00E9}"  // "Café" in NFC
    // String equality in Swift compares canonical equivalence, so the two
    // forms ARE equal as `String`. The difference is at the byte level —
    // pin that here so a future Swift version doesn't silently break this
    // setup.
    #expect(Array(titleNFD.utf8) != Array(titleNFC.utf8))
    #expect(
      titleNFD.precomposedStringWithCanonicalMapping
        == titleNFC.precomposedStringWithCanonicalMapping)

    let collectionNFD = albumDescriptor(id: "A", title: titleNFD)
    let collectionNFC = albumDescriptor(id: "A", title: titleNFC)
    let matcher = BackupCollectionPlacementMatcher()
    let group = makeGroup(kind: .album, leaf: ExportPathPolicy.sanitizeComponent(titleNFC))

    let r1 = matcher.match(
      group: group, photoCollections: [collectionNFD], existingPlacements: [])
    let r2 = matcher.match(
      group: group, photoCollections: [collectionNFC], existingPlacements: [])

    // Both produce the same placement id (load-bearing for idempotent re-imports
    // across launches that return the title in different normalizations).
    switch (r1, r2) {
    case (.fresh(let p1), .fresh(let p2)):
      #expect(p1.id == p2.id)
    default:
      Issue.record("expected both .fresh, got \(r1), \(r2)")
    }
  }

  // MARK: - Shared albums

  @Test func sharedAlbum_existingPlacement_reused() {
    let collectionA = sharedAlbumDescriptor(id: "S", title: "Vacation")
    let existing = sharedAlbumPlacement(
      collectionId: "S", title: "Vacation",
      relativePath: "Collections/Shared Albums/Vacation/")
    let matcher = BackupCollectionPlacementMatcher()
    let group = makeGroup(kind: .sharedAlbum, leaf: "Vacation")
    let outcome = matcher.match(
      group: group, photoCollections: [collectionA], existingPlacements: [existing])
    #expect(outcome == .existing(existing))
  }

  @Test func sharedAlbum_noPhotoKitMatch_orphan() {
    let matcher = BackupCollectionPlacementMatcher()
    let group = makeGroup(kind: .sharedAlbum, leaf: "Vacation")
    let outcome = matcher.match(
      group: group, photoCollections: [], existingPlacements: [])
    #expect(outcome == .orphan(.noPhotoKitCollection))
  }

  @Test func sharedAlbum_nestedUnderFolder_synthetic_orphan() {
    // Scanner never emits this shape in production, but the matcher refuses
    // to construct a placement for it defensively.
    let matcher = BackupCollectionPlacementMatcher()
    let group = makeGroup(
      kind: .sharedAlbum, parent: ["UnexpectedFolder"], leaf: "Vacation")
    let outcome = matcher.match(
      group: group, photoCollections: [], existingPlacements: [])
    #expect(outcome == .orphan(.sharedAlbumNestedUnderFolder))
  }

  // MARK: - Fixture helpers

  private func makeGroup(
    kind: BackupCollectionScanner.CollectionScanGroup.Kind,
    parent: [String] = [],
    leaf: String
  ) -> BackupCollectionScanner.CollectionScanGroup {
    BackupCollectionScanner.CollectionScanGroup(
      kind: kind,
      parentPathComponents: parent,
      leafName: leaf,
      folderURL: URL(fileURLWithPath: "/tmp/test"),
      files: [])
  }

  private func albumDescriptor(
    id: String, title: String, pathComponents: [String] = []
  ) -> PhotoCollectionDescriptor {
    PhotoCollectionDescriptor(
      id: "album:\(id)", localIdentifier: id, title: title,
      kind: .album, pathComponents: pathComponents, children: [])
  }

  private func sharedAlbumDescriptor(
    id: String, title: String
  ) -> PhotoCollectionDescriptor {
    PhotoCollectionDescriptor(
      id: "shared-album:\(id)", localIdentifier: id, title: title,
      kind: .sharedAlbum, pathComponents: [], children: [])
  }

  private func albumPlacement(
    collectionId: String, title: String, relativePath: String,
    createdAt: Date = Date(timeIntervalSince1970: 100)
  ) -> ExportPlacement {
    // Build the placement id with the production hash format so reuse via
    // hasSuffix lookups also works downstream. We don't compute the hash
    // here — we just construct a stable id that the matcher's relativePath
    // byte-equality check finds.
    ExportPlacement(
      kind: .album,
      id: "collections:album:\(collectionId):placeholder",
      displayName: title,
      collectionLocalIdentifier: collectionId,
      relativePath: relativePath,
      createdAt: createdAt)
  }

  private func sharedAlbumPlacement(
    collectionId: String, title: String, relativePath: String,
    createdAt: Date = Date(timeIntervalSince1970: 100)
  ) -> ExportPlacement {
    ExportPlacement(
      kind: .sharedAlbum,
      id: "collections:shared-album:\(collectionId):placeholder",
      displayName: title,
      collectionLocalIdentifier: collectionId,
      relativePath: relativePath,
      createdAt: createdAt)
  }
}
