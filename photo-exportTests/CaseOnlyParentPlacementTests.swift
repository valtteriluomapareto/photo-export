import Foundation
import Testing

@testable import Photo_Export

@MainActor
struct CaseOnlyParentPlacementTests {
  typealias Fixture = CollectionBackupFixture

  private let resolver = ExportPlacementResolver(now: { Fixture.date(0) })

  private func resolve(
    _ id: String, tree: [PhotoCollectionDescriptor], existing: [ExportPlacement] = []
  ) throws -> ExportPlacement {
    try resolver.placement(
      for: .album(collectionId: id), collections: tree, existingPlacements: existing)
  }

  @Test(arguments: [false, true])
  func newAlbumsReserveNamesAcrossCaseOnlyParents(unicode: Bool) throws {
    let parent = unicode ? "Café" : "Trips"
    let alternate = unicode ? "CAFE\u{0301}" : "trips"
    let alternateNFC = alternate.precomposedStringWithCanonicalMapping
    let tree = [
      Fixture.album("beta", "Iceland", in: ["region", alternate]),
      Fixture.album("natural", "ICELAND_2", in: ["Region", parent]),
      Fixture.album("alpha", "Iceland", in: ["Region", parent]),
      Fixture.album("other", "Iceland", in: ["region", "Other"]),
    ]

    let alpha = try resolve("alpha", tree: tree)
    let beta = try resolve("beta", tree: tree)
    let natural = try resolve("natural", tree: tree)
    let other = try resolve("other", tree: tree)
    #expect(alpha.relativePath == "Collections/Albums/Region/\(parent)/Iceland/")
    #expect(beta.relativePath == "Collections/Albums/region/\(alternateNFC)/Iceland_3/")
    #expect(natural.relativePath == "Collections/Albums/Region/\(parent)/ICELAND_2/")
    #expect(other.relativePath == "Collections/Albums/region/Other/Iceland/")
  }

  @Test func existingClaimReservesNameAcrossCaseOnlyParentWithoutMovingHistory() throws {
    let tree = [Fixture.album("current", "Iceland", in: ["trips"])]
    let existing = ExportPlacement(
      kind: .album, id: "historical", displayName: "Trips/Iceland",
      collectionLocalIdentifier: "deleted", relativePath: "Collections/Albums/Trips/Iceland/",
      createdAt: Fixture.date(1))

    let fresh = try resolve("current", tree: tree, existing: [existing])
    #expect(fresh.relativePath == "Collections/Albums/trips/Iceland_2/")

    let saved = ExportPlacement(
      kind: fresh.kind, id: fresh.id, displayName: fresh.displayName,
      collectionLocalIdentifier: fresh.collectionLocalIdentifier,
      relativePath: "Collections/Albums/trips/Iceland/", createdAt: Fixture.date(2))
    let reused = try resolve("current", tree: tree, existing: [existing, saved])
    #expect(reused.id == saved.id)
    #expect(reused.relativePath == "Collections/Albums/trips/Iceland/")
    #expect(reused.createdAt == Fixture.date(2))
  }

  @Test func insensitiveImportDoesNotClaimAnotherAlbumsNaturalSuffix() {
    let tree = [
      Fixture.album("beta", "Iceland", in: ["region", "trips"]),
      Fixture.album("natural", "ICELAND_2", in: ["Region", "Trips"]),
    ]
    let directory = Fixture.directory(
      .albums, ["Region", "Trips", "ICELAND_2"], [Fixture.file("SHARED.JPG", date: Fixture.date(1))]
    )
    let candidates = CollectionBackupPlanner.candidates(
      directories: [directory], collections: tree, existingPlacements: [],
      caseSensitiveVolume: false)
    #expect(candidates.map(\.target) == [.album(collectionId: "natural")])
  }

  @Test func insensitiveExportWipeImportRecoversSuffixFromTheSharedParent() async throws {
    let h = await CollectionImportHarness("CaseOnlyParentImportRoundTrip")
    // This is a real filesystem round trip; the pure candidate test above is volume independent.
    guard
      try h.root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        .volumeSupportsCaseSensitiveNames == false
    else {
      await h.cleanup()
      return
    }
    h.library.collectionTree = [
      Fixture.album("alpha", "Iceland", in: ["Trips"]),
      Fixture.album("beta", "Iceland", in: ["trips"]),
    ]
    h.library.assetsByAlbumLocalId = [
      "alpha": [h.addAsset("alpha-photo", "A.JPG", date: Fixture.date(1))],
      "beta": [h.addAsset("beta-photo", "B.JPG", date: Fixture.date(2))],
    ]
    h.manager.startExportAlbums(collectionIds: ["alpha"])
    await h.manager.waitForQueueDrained()
    h.manager.startExportAlbums(collectionIds: ["beta"])
    await h.manager.waitForQueueDrained()
    let exported = h.collections.placements
    try #require(exported.count == 2)
    let listing = try Fixture.listing(of: h.root)
    try #require(
      Set(listing.keys) == [
        "/Collections/Albums/Trips/Iceland/A.JPG",
        "/Collections/Albums/Trips/Iceland_2/B.JPG",
      ])
    let writes = h.writer.writeCalls.count

    await h.wipeHistory()
    try #require(h.collections.placements.isEmpty)
    await h.importBackup()
    try #require(h.manager.importError == nil)
    #expect(
      h.collections.placements.mapValues(\.relativePath) == exported.mapValues(\.relativePath))

    h.manager.startExportAlbums(collectionIds: ["alpha", "beta"])
    await h.manager.waitForQueueDrained()
    #expect(h.writer.writeCalls.count == writes)
    #expect(try Fixture.listing(of: h.root) == listing)
    await h.cleanup()
  }

  @Test func importCanStillRecoverLegacySuffixWithAnExactParent() async throws {
    let tree = [
      Fixture.album("alpha", "Iceland", in: ["Trips"]),
      Fixture.album("beta", "Iceland", in: ["Trips"]),
      Fixture.album("natural", "Iceland_2", in: ["trips"]),
    ]
    let library = FakePhotoLibraryService()
    library.collectionTree = tree
    library.assetsByAlbumLocalId["beta"] = [
      TestAssetFactory.makeAsset(id: "B", creationDate: Fixture.date(1))
    ]
    library.resourcesByAssetId["B"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "B.JPG")
    ]
    library.assetsByAlbumLocalId["natural"] = [
      TestAssetFactory.makeAsset(id: "N", creationDate: Fixture.date(2))
    ]
    library.resourcesByAssetId["N"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "N.JPG")
    ]
    let directories = [
      Fixture.directory(
        .albums, ["Trips", "Iceland_2"], [Fixture.file("B.JPG", date: Fixture.date(1))]),
      Fixture.directory(
        .albums, ["trips", "Iceland_2"], [Fixture.file("N.JPG", date: Fixture.date(2))]),
    ]
    let plan = try await BackupScanner.matchCollectionFolders(
      ScannedCollections(directories: directories, isCaseSensitiveVolume: true),
      collections: tree, existingPlacements: [], photoLibraryService: library,
      fingerprintCache: BackupScanner.FingerprintCache(), progress: { _ in })

    #expect(plan.adoptions.count == 2)
    #expect(plan.unrecognizedFolders.isEmpty)
    let beta = try #require(
      plan.adoptions.first { $0.placement.collectionLocalIdentifier == "beta" })
    #expect(beta.placement.relativePath == "Collections/Albums/Trips/Iceland_2/")
    #expect(beta.matched.map(\.asset.id) == ["B"])
    let natural = try #require(
      plan.adoptions.first { $0.placement.collectionLocalIdentifier == "natural" })
    #expect(natural.placement.relativePath == "Collections/Albums/trips/Iceland_2/")
    #expect(natural.matched.map(\.asset.id) == ["N"])
  }
}
