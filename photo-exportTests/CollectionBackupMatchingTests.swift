import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Which folder under `Collections/` belongs to which current album, shared album or
/// Favorites. A folder is adopted only on evidence: matched files, enough of the folder's
/// files matched, and a clear best claimant. The adopted placement uses the id
/// `ExportPlacementResolver` gives the album and the resolver's spelling of the folder path.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct CollectionBackupMatchingTests {
  typealias F = CollectionBackupFixture

  private let library = FakePhotoLibraryService()

  /// Adds an image asset whose only resource is `filename`, dated `F.date(index)`.
  @discardableResult
  private func asset(
    _ id: String, _ filename: String, index: Int, mediaType: PHAssetMediaType = .image,
    adjusted: Bool = false
  ) -> AssetDescriptor {
    let asset = TestAssetFactory.makeAsset(
      id: id, creationDate: F.date(index), mediaType: mediaType, hasAdjustments: adjusted)
    library.resourcesByAssetId[id] = [
      TestAssetFactory.makeResource(
        type: mediaType == .video ? .video : .photo, originalFilename: filename)
    ]
    return asset
  }

  private func match(
    _ directories: [ScannedCollectionDirectory], tree: [PhotoCollectionDescriptor],
    existing: [ExportPlacement] = [], caseSensitiveVolume: Bool = false
  ) async throws -> CollectionBackupPlanner.Plan {
    library.collectionTree = tree
    return try await BackupScanner.matchCollectionFolders(
      ScannedCollections(directories: directories, isCaseSensitiveVolume: caseSensitiveVolume),
      collections: tree, existingPlacements: existing,
      photoLibraryService: library, fingerprintCache: BackupScanner.FingerprintCache(),
      progress: { _ in })
  }

  /// The placement the resolver gives `album` today, for comparing ids.
  private func resolvedId(_ selection: LibrarySelection, tree: [PhotoCollectionDescriptor])
    throws -> String
  {
    try ExportPlacementResolver().placement(
      for: selection, collections: tree, existingPlacements: []
    ).id
  }

  private func adoptedPaths(_ result: CollectionBackupPlanner.Plan) -> [String: String] {
    var paths: [String: String] = [:]
    for adoption in result.adoptions {
      paths[adoption.placement.collectionLocalIdentifier ?? adoption.placement.id] =
        adoption.placement.relativePath
    }
    return paths
  }

  // MARK: - Names and suffixes

  @Test func albumAtItsBareNameIsAdoptedWithTheResolversPlacement() async throws {
    let tree = [F.folder("trips", "Trips", children: [F.album("paris", "Paris", in: ["Trips"])])]
    library.assetsByAlbumLocalId["paris"] = [
      asset("p1", "IMG_1.JPG", index: 1), asset("p2", "IMG_2.JPG", index: 2),
    ]
    let result = try await match(
      [
        F.directory(.albums, ["Trips"], []),
        F.directory(
          .albums, ["Trips", "Paris"],
          [F.file("IMG_1.JPG", date: F.date(1)), F.file("IMG_2.JPG", date: F.date(2))]),
      ], tree: tree)

    let adoption = try #require(result.adoptions.first)
    #expect(result.adoptions.count == 1)
    #expect(adoption.placement.id == (try resolvedId(.album(collectionId: "paris"), tree: tree)))
    #expect(adoption.placement.relativePath == "Collections/Albums/Trips/Paris/")
    #expect(adoption.placement.kind == .album)
    #expect(Set(adoption.matched.map(\.asset.id)) == ["p1", "p2"])
    #expect(result.unrecognizedFolders.isEmpty)
  }

  @Test func collidingAlbumsAreAssignedTheirOwnSuffixedFolders() async throws {
    let tree = [F.album("a1", "Trip"), F.album("a2", "Trip")]
    library.assetsByAlbumLocalId["a1"] = [asset("x", "X.JPG", index: 1)]
    library.assetsByAlbumLocalId["a2"] = [asset("y", "Y.JPG", index: 2)]
    let result = try await match(
      [
        F.directory(.albums, ["Trip"], [F.file("X.JPG", date: F.date(1))]),
        F.directory(.albums, ["Trip_2"], [F.file("Y.JPG", date: F.date(2))]),
      ], tree: tree)
    #expect(
      adoptedPaths(result) == [
        "a1": "Collections/Albums/Trip/", "a2": "Collections/Albums/Trip_2/",
      ])
  }

  /// The second album was exported first, so it holds the bare folder even though the resolver
  /// would give it the suffix today.
  @Test func collidingAlbumsExportedInTheOtherOrderKeepTheirFolders() async throws {
    let tree = [F.album("a1", "Trip"), F.album("a2", "Trip")]
    library.assetsByAlbumLocalId["a1"] = [asset("x", "X.JPG", index: 1)]
    library.assetsByAlbumLocalId["a2"] = [asset("y", "Y.JPG", index: 2)]
    let result = try await match(
      [
        F.directory(.albums, ["Trip"], [F.file("Y.JPG", date: F.date(2))]),
        F.directory(.albums, ["Trip_2"], [F.file("X.JPG", date: F.date(1))]),
      ], tree: tree)
    #expect(
      adoptedPaths(result) == [
        "a1": "Collections/Albums/Trip_2/", "a2": "Collections/Albums/Trip/",
      ])
    #expect(result.unrecognizedFolders.isEmpty)
  }

  @Test func albumWhoseSiblingWasDeletedKeepsItsSuffixedFolder() async throws {
    let tree = [F.album("a2", "Trip")]
    library.assetsByAlbumLocalId["a2"] = [asset("y", "Y.JPG", index: 2)]
    asset("gone", "GONE.JPG", index: 9)
    let result = try await match(
      [
        F.directory(.albums, ["Trip"], [F.file("GONE.JPG", date: F.date(9))]),
        F.directory(.albums, ["Trip_2"], [F.file("Y.JPG", date: F.date(2))]),
      ], tree: tree)
    #expect(adoptedPaths(result) == ["a2": "Collections/Albums/Trip_2/"])
    #expect(result.unrecognizedFolders == ["Collections/Albums/Trip/"])
  }

  /// An album literally titled "Trip_2" owns that folder; a third "Trip" skips the name, as
  /// the resolver does.
  @Test func albumTitledWithASuffixKeepsItsNaturalFolder() async throws {
    let tree = [F.album("a1", "Trip"), F.album("a2", "Trip_2"), F.album("a3", "Trip")]
    library.assetsByAlbumLocalId["a1"] = [asset("x", "X.JPG", index: 1)]
    library.assetsByAlbumLocalId["a2"] = [asset("y", "Y.JPG", index: 2)]
    library.assetsByAlbumLocalId["a3"] = [
      asset("z", "Z.JPG", index: 3), asset("y", "Y.JPG", index: 2),
    ]
    let result = try await match(
      [
        F.directory(.albums, ["Trip"], [F.file("X.JPG", date: F.date(1))]),
        F.directory(.albums, ["Trip_2"], [F.file("Y.JPG", date: F.date(2))]),
        F.directory(.albums, ["Trip_3"], [F.file("Z.JPG", date: F.date(3))]),
      ], tree: tree)
    #expect(
      adoptedPaths(result) == [
        "a1": "Collections/Albums/Trip/", "a2": "Collections/Albums/Trip_2/",
        "a3": "Collections/Albums/Trip_3/",
      ])
  }

  // MARK: - Renamed, moved and saved placements

  @Test func renamedAlbumDoesNotAdoptItsOldFolder() async throws {
    let tree = [F.album("a1", "Holiday")]
    library.assetsByAlbumLocalId["a1"] = [asset("x", "X.JPG", index: 1)]
    let result = try await match(
      [F.directory(.albums, ["Trip"], [F.file("X.JPG", date: F.date(1))])], tree: tree)
    #expect(result.adoptions.isEmpty)
    #expect(result.unrecognizedFolders == ["Collections/Albums/Trip/"])
  }

  @Test func movedAlbumDoesNotAdoptItsOldFolder() async throws {
    let tree = [F.folder("f", "2024", children: [F.album("a1", "Trip", in: ["2024"])])]
    library.assetsByAlbumLocalId["a1"] = [asset("x", "X.JPG", index: 1)]
    let result = try await match(
      [F.directory(.albums, ["Trip"], [F.file("X.JPG", date: F.date(1))])], tree: tree)
    #expect(result.adoptions.isEmpty)
    #expect(result.unrecognizedFolders == ["Collections/Albums/Trip/"])
  }

  @Test func savedPlacementClaimsItsFolder() async throws {
    let tree = [F.album("a1", "Trip"), F.album("a2", "Trip")]
    let saved = try ExportPlacementResolver().placement(
      for: .album(collectionId: "a2"), collections: tree, existingPlacements: [])
    let savedAtBare = ExportPlacement(
      kind: .album, id: saved.id, displayName: saved.displayName,
      collectionLocalIdentifier: "a2", relativePath: "Collections/Albums/Trip/",
      createdAt: Date(timeIntervalSince1970: 1))
    library.assetsByAlbumLocalId["a1"] = [
      asset("x", "X.JPG", index: 1), asset("y", "Y.JPG", index: 2),
    ]
    library.assetsByAlbumLocalId["a2"] = [asset("y", "Y.JPG", index: 2)]
    let result = try await match(
      [
        F.directory(
          .albums, ["Trip"], [F.file("X.JPG", date: F.date(1)), F.file("Y.JPG", date: F.date(2))]),
        F.directory(.albums, ["Trip_2"], [F.file("Y.JPG", date: F.date(2))]),
      ], tree: tree, existing: [savedAtBare])

    let byAlbum = Dictionary(
      uniqueKeysWithValues: result.adoptions.map { ($0.placement.collectionLocalIdentifier!, $0) })
    #expect(byAlbum["a2"]?.placement.relativePath == "Collections/Albums/Trip/")
    #expect(
      byAlbum["a2"]?.placement.createdAt == savedAtBare.createdAt, "the saved placement is kept")
    #expect(byAlbum["a1"]?.placement.relativePath == "Collections/Albums/Trip_2/")
  }

  @Test func stalePlacementOfARenamedAlbumKeepsItsFolderFromANewAlbum() async throws {
    let stale = ExportPlacement(
      kind: .album, id: "collections:album:0000000000000000:00000000", displayName: "Old",
      collectionLocalIdentifier: "renamed", relativePath: "Collections/Albums/Trip/",
      createdAt: Date(timeIntervalSince1970: 1))
    let tree = [F.album("a1", "Trip")]
    library.assetsByAlbumLocalId["a1"] = [asset("x", "X.JPG", index: 1)]
    let result = try await match(
      [F.directory(.albums, ["Trip"], [F.file("X.JPG", date: F.date(1))])], tree: tree,
      existing: [stale])
    #expect(result.adoptions.isEmpty)
  }

  // MARK: - videos/ subfolders

  @Test func videosFolderIsTheAlbumsVideosOrANestedAlbumByContent() async throws {
    let tree = [
      F.album("trip", "Trip"),
      F.folder("tripFolder", "Trip", children: [F.album("nested", "videos", in: ["Trip"])]),
    ]
    library.assetsByAlbumLocalId["trip"] = [
      asset("still", "STILL.JPG", index: 1), asset("clip", "CLIP.MOV", index: 2, mediaType: .video),
    ]
    library.assetsByAlbumLocalId["nested"] = [asset("other", "OTHER.JPG", index: 3)]
    let result = try await match(
      [
        F.directory(.albums, ["Trip"], [F.file("STILL.JPG", date: F.date(1))]),
        F.directory(
          .albums, ["Trip", "videos"],
          [F.file("CLIP.MOV", date: F.date(2)), F.file("OTHER.JPG", date: F.date(3))]),
      ], tree: tree)

    let byAlbum = Dictionary(
      uniqueKeysWithValues: result.adoptions.map { ($0.placement.collectionLocalIdentifier!, $0) })
    let trip = try #require(byAlbum["trip"])
    #expect(trip.placement.relativePath == "Collections/Albums/Trip/")
    #expect(
      Set(trip.matched.map { "\($0.file.subfolder ?? "-")/\($0.file.filename)" })
        == ["-/STILL.JPG", "videos/CLIP.MOV"])
    let nested = try #require(byAlbum["nested"])
    #expect(nested.placement.relativePath == "Collections/Albums/Trip/videos/")
    #expect(nested.matched.map(\.file.filename) == ["OTHER.JPG"])
    #expect(nested.matched.allSatisfy { $0.file.subfolder == nil })
  }

  // MARK: - Shared albums and Favorites

  @Test func sharedAlbumsAndAlbumsWithTheSameTitleAreScopedSeparately() async throws {
    let tree = [F.album("a1", "Trip"), F.sharedAlbum("s1", "Trip")]
    library.assetsByAlbumLocalId["a1"] = [asset("x", "X.JPG", index: 1)]
    library.assetsBySharedAlbumLocalId["s1"] = [asset("s", "S.JPG", index: 2)]
    let result = try await match(
      [
        F.directory(.albums, ["Trip"], [F.file("X.JPG", date: F.date(1))]),
        F.directory(.sharedAlbums, ["Trip"], [F.file("S.JPG", date: F.date(2))]),
      ], tree: tree)

    #expect(
      adoptedPaths(result) == [
        "a1": "Collections/Albums/Trip/", "s1": "Collections/Shared Albums/Trip/",
      ])
    let shared = try #require(result.adoptions.first { $0.placement.kind == .sharedAlbum })
    #expect(shared.placement.id == (try resolvedId(.sharedAlbum(collectionId: "s1"), tree: tree)))
    #expect(shared.matched.map(\.asset.id) == ["s"])
  }

  /// A shared album holds one resource per asset, so only its originals are adopted.
  @Test func sharedAlbumAdoptsOriginalsOnly() async throws {
    let tree = [F.sharedAlbum("s1", "Party")]
    let adjusted = asset("s", "S.JPG", index: 2, adjusted: true)
    library.resourcesByAssetId["s"]?.append(
      TestAssetFactory.makeResource(type: .fullSizePhoto, originalFilename: "FullSizeRender.JPG"))
    library.assetsBySharedAlbumLocalId["s1"] = [adjusted]
    let result = try await match(
      [
        F.directory(
          .sharedAlbums, ["Party"],
          [F.file("S.JPG", date: F.date(2)), F.file("S_orig.JPG", date: F.date(2))])
      ], tree: tree)
    let shared = try #require(result.adoptions.first)
    #expect(shared.matched.map(\.variant) == [.original])
    #expect(shared.matched.map(\.file.filename) == ["S.JPG"])
  }

  @Test func favoritesFolderIsAdoptedAsTheFavoritesPlacement() async throws {
    library.favoritesAssets = [asset("f", "F.JPG", index: 4)]
    let result = try await match(
      [F.directory(.favorites, [], [F.file("F.JPG", date: F.date(4))])], tree: [F.favorites])
    let favorites = try #require(result.adoptions.first)
    #expect(favorites.placement.id == ExportPlacement.favorites().id)
    #expect(favorites.placement.relativePath == "Collections/Favorites/")
  }

  // MARK: - Spelling

  @Test func decomposedAndCaseVariantFolderNamesMatchAndStoreTheResolverSpelling() async throws {
    let tree = [F.album("cafe", "Caf\u{E9}"), F.album("trip", "trip")]
    library.assetsByAlbumLocalId["cafe"] = [asset("c", "C.JPG", index: 1)]
    library.assetsByAlbumLocalId["trip"] = [asset("t", "T.JPG", index: 2)]
    let result = try await match(
      [
        F.directory(.albums, ["Cafe\u{301}"], [F.file("C.JPG", date: F.date(1))]),
        F.directory(.albums, ["TRIP"], [F.file("T.JPG", date: F.date(2))]),
      ], tree: tree)
    #expect(
      adoptedPaths(result) == [
        "cafe": "Collections/Albums/Caf\u{E9}/", "trip": "Collections/Albums/trip/",
      ])
  }

  // MARK: - Evidence

  /// The folder the album exports to, with nothing in it matching — for example an album
  /// deleted and recreated under the same title: not adopted, and reported.
  @Test func folderWithoutMatchingFilesIsNotAdopted() async throws {
    let tree = [F.album("a1", "Trip")]
    library.assetsByAlbumLocalId["a1"] = [asset("x", "X.JPG", index: 1)]
    let result = try await match(
      [F.directory(.albums, ["Trip"], [F.file("UNKNOWN.JPG", date: F.date(7))])], tree: tree)
    #expect(result.adoptions.isEmpty)
    #expect(result.unrecognizedFolders == ["Collections/Albums/Trip/"])
  }

  /// A leftover suffixed folder that matches nothing doesn't make the album's own folder
  /// contested.
  @Test func rivalFolderWithoutMatchesDoesNotContestTheAlbumsFolder() async throws {
    let tree = [F.album("a1", "Trip")]
    library.assetsByAlbumLocalId["a1"] = [
      asset("x", "X.JPG", index: 1), asset("y", "Y.JPG", index: 2),
    ]
    let others = (3...10).map { F.file("O\($0).JPG", date: F.date(20 + $0)) }
    let result = try await match(
      [
        F.directory(
          .albums, ["Trip"],
          [F.file("X.JPG", date: F.date(1)), F.file("Y.JPG", date: F.date(2))] + others),
        F.directory(.albums, ["Trip_2"], [F.file("GONE.JPG", date: F.date(40))]),
      ], tree: tree)
    #expect(adoptedPaths(result) == ["a1": "Collections/Albums/Trip/"])
    #expect(result.unrecognizedFolders == ["Collections/Albums/Trip_2/"])
  }

  /// The album would export to its bare name today, so a suffixed folder is not its own: one
  /// match of four is not enough, and the folder is reported.
  @Test func suffixedFolderOfALoneAlbumNeedsMostOfItsFilesToMatch() async throws {
    let tree = [F.album("a2", "Trip")]
    library.assetsByAlbumLocalId["a2"] = [asset("y", "Y.JPG", index: 2)]
    let result = try await match(
      [
        F.directory(
          .albums, ["Trip_2"],
          [
            F.file("Y.JPG", date: F.date(2)), F.file("O1.JPG", date: F.date(5)),
            F.file("O2.JPG", date: F.date(6)), F.file("O3.JPG", date: F.date(7)),
          ])
      ], tree: tree)
    #expect(result.adoptions.isEmpty)
    #expect(result.unrecognizedFolders == ["Collections/Albums/Trip_2/"])
  }

  /// Nothing else could claim the folder the album exports to, so one match is enough: an
  /// album whose photos were mostly removed since the export keeps the folder.
  @Test func uncontestedFolderIsAdoptedOnAnyMatch() async throws {
    let tree = [F.album("a1", "Trip")]
    library.assetsByAlbumLocalId["a1"] = [asset("x", "X.JPG", index: 1)]
    let result = try await match(
      [
        F.directory(
          .albums, ["Trip"],
          [
            F.file("X.JPG", date: F.date(1)), F.file("O1.JPG", date: F.date(5)),
            F.file("O2.JPG", date: F.date(6)), F.file("O3.JPG", date: F.date(7)),
          ])
      ], tree: tree)
    #expect(adoptedPaths(result) == ["a1": "Collections/Albums/Trip/"])
    #expect(result.unrecognizedFolders.isEmpty)
  }

  /// When both colliding albums have matches in a folder, it must be mostly one album's files.
  @Test func contestedFolderNeedsMostOfItsFilesToMatch() async throws {
    let tree = [F.album("a1", "Trip"), F.album("a2", "Trip")]
    library.assetsByAlbumLocalId["a1"] = [
      asset("x", "X.JPG", index: 1), asset("o1", "O1.JPG", index: 5),
    ]
    library.assetsByAlbumLocalId["a2"] = [asset("y", "Y.JPG", index: 2)]
    let result = try await match(
      [
        F.directory(.albums, ["Trip"], [F.file("X.JPG", date: F.date(1))]),
        F.directory(
          .albums, ["Trip_2"],
          [
            F.file("Y.JPG", date: F.date(2)), F.file("O1.JPG", date: F.date(5)),
            F.file("O2.JPG", date: F.date(6)), F.file("O3.JPG", date: F.date(7)),
          ]),
      ], tree: tree)
    #expect(adoptedPaths(result) == ["a1": "Collections/Albums/Trip/"])
    #expect(result.unrecognizedFolders == ["Collections/Albums/Trip_2/"])
  }

  /// Both albums hold the same photo and both folders the same file, so either assignment
  /// writes nothing: the resolver's order decides.
  @Test func tiedClaimsWithTheSameFilesFollowTheResolversOrder() async throws {
    let tree = [F.album("a1", "Trip"), F.album("a2", "Trip")]
    let shared = asset("x", "X.JPG", index: 1)
    library.assetsByAlbumLocalId["a1"] = [shared]
    library.assetsByAlbumLocalId["a2"] = [shared]
    let result = try await match(
      [
        F.directory(.albums, ["Trip"], [F.file("X.JPG", date: F.date(1), size: 9)]),
        F.directory(.albums, ["Trip_2"], [F.file("X.JPG", date: F.date(1), size: 9)]),
      ], tree: tree)
    #expect(result.adoptions.count == 2)
    #expect(
      adoptedPaths(result) == [
        "a1": "Collections/Albums/Trip/", "a2": "Collections/Albums/Trip_2/",
      ])
    #expect(result.unrecognizedFolders.isEmpty)
  }

  enum TiedSizes: CaseIterable, Sendable {
    case different, unknown
    var sizes: (UInt64?, UInt64?) { self == .different ? (9, 10) : (nil, nil) }
  }

  /// Same names but different sizes (or unknown sizes) are not the same files: abstain.
  @Test(arguments: TiedSizes.allCases)
  func tiedClaimsWithDifferentSizesLeaveTheFoldersUnrecognized(_ tied: TiedSizes) async throws {
    let sizes = tied.sizes
    let tree = [F.album("a1", "Trip"), F.album("a2", "Trip")]
    let shared = asset("x", "X.JPG", index: 1)
    library.assetsByAlbumLocalId["a1"] = [shared]
    library.assetsByAlbumLocalId["a2"] = [shared]
    let result = try await match(
      [
        F.directory(.albums, ["Trip"], [F.file("X.JPG", date: F.date(1), size: sizes.0)]),
        F.directory(.albums, ["Trip_2"], [F.file("X.JPG", date: F.date(1), size: sizes.1)]),
      ], tree: tree)
    #expect(result.adoptions.isEmpty)
    #expect(
      result.unrecognizedFolders == ["Collections/Albums/Trip/", "Collections/Albums/Trip_2/"])
  }

  /// On a case-sensitive volume a folder spelled in another case than the resolver's is not
  /// the one exports use, so it is not adopted.
  /// On a case-sensitive volume a saved placement owns only the folder spelled as its path:
  /// `trip/` is neither the saved `Trip/` nor taken by it, so it is reported.
  @Test func savedPlacementOnACaseSensitiveVolumeOwnsOnlyItsExactSpelling() async throws {
    let tree = [F.album("a1", "Trip")]
    library.assetsByAlbumLocalId["a1"] = [asset("x", "X.JPG", index: 1)]
    let resolved = try ExportPlacementResolver().placement(
      for: .album(collectionId: "a1"), collections: tree, existingPlacements: [])
    let directories = [F.directory(.albums, ["trip"], [F.file("X.JPG", date: F.date(1))])]

    let sensitive = try await match(
      directories, tree: tree, existing: [resolved], caseSensitiveVolume: true)
    #expect(sensitive.adoptions.isEmpty)
    #expect(sensitive.unrecognizedFolders == ["Collections/Albums/trip/"])
    let insensitive = try await match(directories, tree: tree, existing: [resolved])
    #expect(insensitive.adoptions.map(\.placement.relativePath) == ["Collections/Albums/Trip/"])
  }

  /// On a case-sensitive volume `Trip/` and `trip/` are two folders: the one spelled as exports
  /// spell it is adopted and the other is reported.
  @Test func bothSpellingsOnACaseSensitiveVolumeAdoptTheExactOne() async throws {
    let tree = [F.album("a1", "Trip")]
    library.assetsByAlbumLocalId["a1"] = [asset("x", "X.JPG", index: 1)]
    let result = try await match(
      [
        F.directory(.albums, ["Trip"], [F.file("X.JPG", date: F.date(1))]),
        F.directory(.albums, ["trip"], [F.file("X.JPG", date: F.date(1))]),
      ], tree: tree, caseSensitiveVolume: true)
    #expect(adoptedPaths(result) == ["a1": "Collections/Albums/Trip/"])
    #expect(result.unrecognizedFolders == ["Collections/Albums/trip/"])
  }

  /// One album with matches in two folders competes with itself: its own folder, mostly other
  /// files, must clear the floor, so the suffixed folder whose files all match is adopted.
  @Test func albumWithMatchesInTwoFoldersAppliesTheFloorToItsOwnFolder() async throws {
    let tree = [F.album("a1", "Trip")]
    library.assetsByAlbumLocalId["a1"] =
      (1...3).map { asset("x\($0)", "X\($0).JPG", index: $0) }
      + (4...5).map { asset("y\($0)", "Y\($0).JPG", index: $0) }
    let others = (6...14).map { F.file("O\($0).JPG", date: F.date(20 + $0)) }
    let result = try await match(
      [
        F.directory(
          .albums, ["Trip"], (1...3).map { F.file("X\($0).JPG", date: F.date($0)) } + others),
        F.directory(
          .albums, ["Trip_2"], (4...5).map { F.file("Y\($0).JPG", date: F.date($0)) }),
      ], tree: tree)
    #expect(adoptedPaths(result) == ["a1": "Collections/Albums/Trip_2/"])
    #expect(result.unrecognizedFolders == ["Collections/Albums/Trip/"])
  }

  @Test func caseVariantFolderOnACaseSensitiveVolumeIsNotAdopted() async throws {
    let tree = [F.album("trip", "trip")]
    library.assetsByAlbumLocalId["trip"] = [asset("t", "T.JPG", index: 2)]
    let directories = [F.directory(.albums, ["TRIP"], [F.file("T.JPG", date: F.date(2))])]

    let sensitive = try await match(directories, tree: tree, caseSensitiveVolume: true)
    #expect(sensitive.adoptions.isEmpty)
    #expect(sensitive.unrecognizedFolders == ["Collections/Albums/TRIP/"])
    let insensitive = try await match(directories, tree: tree)
    #expect(adoptedPaths(insensitive) == ["trip": "Collections/Albums/trip/"])
  }

  @Test func tiedClaimsWithDifferentFilesLeaveTheFoldersUnrecognized() async throws {
    let tree = [F.album("a1", "Trip"), F.album("a2", "Trip")]
    let x = asset("x", "X.JPG", index: 1)
    let y = asset("y", "Y.JPG", index: 2)
    library.assetsByAlbumLocalId["a1"] = [x, y]
    library.assetsByAlbumLocalId["a2"] = [x, y]
    let result = try await match(
      [
        F.directory(.albums, ["Trip"], [F.file("X.JPG", date: F.date(1), size: 9)]),
        F.directory(.albums, ["Trip_2"], [F.file("Y.JPG", date: F.date(2), size: 9)]),
      ], tree: tree)
    #expect(result.adoptions.isEmpty)
    #expect(
      result.unrecognizedFolders == ["Collections/Albums/Trip/", "Collections/Albums/Trip_2/"])
  }

  /// On a case-sensitive volume "Trip" and "trip" are two folders; neither is adopted rather
  /// than guessing which one an export wrote.
  @Test func foldersDifferingOnlyByCaseAreNotAdopted() async throws {
    let tree = [F.album("a1", "Trip")]
    library.assetsByAlbumLocalId["a1"] = [asset("x", "X.JPG", index: 1)]
    let result = try await match(
      [
        F.directory(.albums, ["Trip"], [F.file("X.JPG", date: F.date(1))]),
        F.directory(.albums, ["trip"], [F.file("X.JPG", date: F.date(1))]),
      ], tree: tree)
    #expect(result.adoptions.isEmpty)
    #expect(
      result.unrecognizedFolders == ["Collections/Albums/Trip/", "Collections/Albums/trip/"])
  }

  @Test func albumsWithoutFoldersOnDiskAreNotFetched() async throws {
    let tree = [F.album("a1", "Trip"), F.album("a2", "Paris")]
    library.assetsByAlbumLocalId["a1"] = [asset("x", "X.JPG", index: 1)]
    _ = try await match(
      [F.directory(.albums, ["Trip"], [F.file("X.JPG", date: F.date(1))])], tree: tree)
    #expect(library.scopeFetchCalls == [.album(collectionId: "a1")])
  }

  /// Superseded between two albums (the check before the second album's fetch fails): the
  /// second album is not read.
  @Test func supersededMatchReadsNoFurtherAlbum() async throws {
    let tree = [F.album("a1", "Trip"), F.album("a2", "Paris")]
    library.assetsByAlbumLocalId["a1"] = [asset("x", "X.JPG", index: 1)]
    library.assetsByAlbumLocalId["a2"] = [asset("y", "Y.JPG", index: 2)]
    library.collectionTree = tree
    var checks = 0
    // Before and after the first album's fetch the caller is current; from then on it is not.
    let isCurrent: @MainActor () -> Bool = {
      checks += 1
      return checks <= 2
    }
    await #expect(throws: CancellationError.self) {
      _ = try await BackupScanner.matchCollectionFolders(
        ScannedCollections(
          directories: [
            F.directory(.albums, ["Trip"], [F.file("X.JPG", date: F.date(1))]),
            F.directory(.albums, ["Paris"], [F.file("Y.JPG", date: F.date(2))]),
          ], isCaseSensitiveVolume: false),
        collections: tree, existingPlacements: [], photoLibraryService: library,
        fingerprintCache: BackupScanner.FingerprintCache(), isCurrent: isCurrent,
        progress: { _ in })
    }
    #expect(library.scopeFetchCalls == [.album(collectionId: "a1")])
    #expect(library.resourcesCallCounts["y"] == nil)
  }

  @Test func albumFetchFailureFailsTheMatch() async throws {
    let tree = [F.album("a1", "Trip")]
    library.fetchAssetsErrorByAlbumId["a1"] = CocoaError(.fileReadUnknown)
    await #expect(throws: CocoaError.self) {
      _ = try await match(
        [F.directory(.albums, ["Trip"], [F.file("X.JPG", date: F.date(1))])], tree: tree)
    }
  }
}
