import Foundation
import Testing

@testable import Photo_Export

@MainActor
struct CaseInsensitivePlacementTests {
  nonisolated static let kinds: [PhotoCollectionDescriptor.Kind] = [.album, .sharedAlbum]
  private let resolver = ExportPlacementResolver(now: { Date(timeIntervalSince1970: 42) })

  private func descriptor(
    _ id: String, _ title: String, kind: PhotoCollectionDescriptor.Kind
  ) -> PhotoCollectionDescriptor {
    PhotoCollectionDescriptor(
      id: id, localIdentifier: id, title: title, kind: kind,
      pathComponents: kind == .album ? ["Family"] : [], children: [])
  }

  private func prefix(_ kind: PhotoCollectionDescriptor.Kind) -> String {
    kind == .album ? "Collections/Albums/Family/" : "Collections/Shared Albums/"
  }

  private func resolve(
    _ album: PhotoCollectionDescriptor, tree: [PhotoCollectionDescriptor],
    existing: [ExportPlacement] = []
  ) throws -> ExportPlacement {
    let id = try #require(album.localIdentifier)
    return try resolver.placement(
      for: album.kind == .album ? .album(collectionId: id) : .sharedAlbum(collectionId: id),
      collections: tree, existingPlacements: existing)
  }

  private func expectUnique(_ placements: [ExportPlacement]) {
    for index in placements.indices {
      for other in placements.indices where other > index {
        // Independent of the allocator's key construction; compare complete paths.
        #expect(
          placements[index].relativePath.compare(
            placements[other].relativePath, options: .caseInsensitive,
            locale: Locale(identifier: "en_US_POSIX")) != .orderedSame)
      }
    }
  }

  private func permutations<T>(_ values: [T]) -> [[T]] {
    if values.isEmpty { return [[]] }
    return values.indices.flatMap { index in
      var rest = values
      let first = rest.remove(at: index)
      return permutations(rest).map { [first] + $0 }
    }
  }

  @Test(arguments: kinds, [false, true])
  func caseOnlyAndUnicodeSiblingsKeepSpellingAndDistinctPaths(
    kind: PhotoCollectionDescriptor.Kind, unicode: Bool
  ) throws {
    let first = unicode ? "Café" : "Trip"
    let second = unicode ? "CAFE\u{0301}" : "trip"
    let alpha = descriptor("alpha", first, kind: kind)
    let beta = descriptor("beta", second, kind: kind)
    for tree in [[alpha, beta], [beta, alpha]] {
      let a = try resolve(alpha, tree: tree)
      let b = try resolve(beta, tree: tree)
      #expect(a.relativePath == prefix(kind) + first + "/")
      #expect(b.relativePath == prefix(kind) + second.precomposedStringWithCanonicalMapping + "_2/")
      #expect(a.displayName.hasSuffix(first))
      #expect(b.displayName.hasSuffix(second))
      #expect(a.id != b.id)
      expectUnique([a, b])
    }
  }

  @Test(arguments: kinds)
  func existingCaseOnlyClaimantsAndSuffixesRemainReserved(kind: PhotoCollectionDescriptor.Kind)
    throws
  {
    let album = descriptor("new", "Trip", kind: kind)
    let placementKind: ExportPlacement.Kind = kind == .album ? .album : .sharedAlbum
    let existing = ["TRIP", "trip_2"].enumerated().map { index, leaf in
      ExportPlacement(
        kind: placementKind, id: "historical-\(index)", displayName: leaf,
        collectionLocalIdentifier: "old-\(index)", relativePath: prefix(kind) + leaf + "/",
        createdAt: Date(timeIntervalSince1970: 0))
    }
    for history in [existing, existing.reversed().map { $0 }] {
      let result = try resolve(album, tree: [album], existing: history)
      #expect(result.relativePath == prefix(kind) + "Trip_3/")
      expectUnique(existing + [result])
    }
  }

  @Test(arguments: kinds, [false, true])
  func naturalSuffixNamesStayUniqueAcrossAllAllocationOrders(
    kind: PhotoCollectionDescriptor.Kind, secondSuffixGroup: Bool
  ) throws {
    var tree = [descriptor("alpha", "Trip", kind: kind), descriptor("beta", "trip", kind: kind)]
    tree.append(descriptor("gamma", "TRIP_2", kind: kind))
    if secondSuffixGroup { tree.append(descriptor("delta", "trip_2", kind: kind)) }
    var expected = ["alpha": "Trip", "beta": "trip_3", "gamma": "TRIP_2"]
    if secondSuffixGroup {
      expected["gamma"] = "TRIP_2_2"
      expected["delta"] = "trip_2"
    }
    for traversal in [tree, Array(tree.reversed())] {
      for order in permutations(tree) {
        var saved: [ExportPlacement] = []
        for album in order {
          let withHistory = try resolve(album, tree: traversal, existing: saved)
          let withoutHistory = try resolve(album, tree: traversal)
          let id = try #require(album.localIdentifier)
          let leaf = try #require(expected[id])
          #expect(withHistory.relativePath == prefix(kind) + leaf + "/")
          #expect(withHistory.id == withoutHistory.id)
          #expect(withHistory.relativePath == withoutHistory.relativePath)
          #expect(withHistory.createdAt == withoutHistory.createdAt)
          saved.append(withHistory)
          expectUnique(saved)
        }
        for album in order {
          let stored = try resolve(album, tree: traversal, existing: saved)
          let fresh = try resolve(album, tree: traversal)
          #expect(stored.id == fresh.id)
          #expect(stored.relativePath == fresh.relativePath)
          #expect(stored.createdAt == fresh.createdAt)
        }
      }
    }
  }

  @Test(arguments: kinds)
  func persistedPathsAndCaseOnlyRenameIdentityStayCompatible(kind: PhotoCollectionDescriptor.Kind)
    async throws
  {
    let root = TestScratch.directory("CaseInsensitivePlacement")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CollectionExportRecordStore(baseDirectoryURL: root)
    await store.configureAndWait(for: "test")
    let alpha = descriptor("alpha", "Trip", kind: kind)
    let beta = descriptor("beta", "trip", kind: kind)
    let tree = [beta, alpha]
    for album in tree {
      let value = try resolve(album, tree: tree, existing: Array(store.placements.values))
      store.upsertPlacement(
        ExportPlacement(
          kind: value.kind, id: value.id, displayName: value.displayName,
          collectionLocalIdentifier: value.collectionLocalIdentifier,
          relativePath: value.relativePath,
          createdAt: Date(timeIntervalSince1970: 123)))
    }
    try await store.flush()
    let saved = store.placements
    let reopened = CollectionExportRecordStore(baseDirectoryURL: root)
    await reopened.configureAndWait(for: "test")
    for album in tree {
      let value = try resolve(album, tree: tree, existing: Array(reopened.placements.values))
      #expect(saved[value.id]?.relativePath == value.relativePath)
      #expect(saved[value.id]?.createdAt == value.createdAt)
      #expect(value.createdAt == Date(timeIntervalSince1970: 123))
    }
    let old = try resolve(alpha, tree: [alpha])
    let renamed = descriptor("alpha", "trip", kind: kind)
    let current = try resolve(renamed, tree: [renamed], existing: [old])
    #expect(current.id != old.id)
    #expect(old.relativePath == prefix(kind) + "Trip/")
    #expect(current.relativePath == prefix(kind) + "trip_2/")
    expectUnique([old, current])
    // Previously colliding persisted paths are intentionally reused exactly.
    let historical = ExportPlacement(
      kind: old.kind, id: current.id, displayName: current.displayName,
      collectionLocalIdentifier: current.collectionLocalIdentifier,
      relativePath: prefix(kind) + "trip/", createdAt: Date(timeIntervalSince1970: 1))
    let reused = try resolve(renamed, tree: [renamed], existing: [historical, old])
    #expect(reused.id == historical.id)
    #expect(reused.relativePath == historical.relativePath)
    #expect(reused.createdAt == historical.createdAt)
  }

  @Test(arguments: kinds)
  func occupiedSuffixesBeyondOldCapAreNeverReused(kind: PhotoCollectionDescriptor.Kind) throws {
    let album = descriptor("new", "Trip", kind: kind)
    let placementKind: ExportPlacement.Kind = kind == .album ? .album : .sharedAlbum
    let occupied = (1...1001).map { number in
      let leaf = number == 1 ? "TRIP" : "TRIP_\(number)"
      return ExportPlacement(
        kind: placementKind, id: "old-\(number)", displayName: leaf,
        collectionLocalIdentifier: "old-\(number)", relativePath: prefix(kind) + leaf + "/",
        createdAt: Date(timeIntervalSince1970: 0))
    }
    let result = try resolve(album, tree: [album], existing: occupied)
    #expect(result.relativePath == prefix(kind) + "Trip_1002/")
  }

  @Test(arguments: kinds)
  func resolvedDirectoriesKeepSeparateFilesOnScratchVolume(kind: PhotoCollectionDescriptor.Kind)
    throws
  {
    let root = TestScratch.directory("CaseInsensitivePlacement")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let probe = root.appendingPathComponent("CaseProbe")
    try Data("probe".utf8).write(to: probe, options: .withoutOverwriting)
    let caseInsensitive = FileManager.default.fileExists(
      atPath: root.appendingPathComponent("caseprobe").path)
    let alpha = descriptor("alpha", "Trip", kind: kind)
    let beta = descriptor("beta", "trip", kind: kind)
    let tree = [alpha, beta]
    let placements = try [resolve(alpha, tree: tree), resolve(beta, tree: tree)]
    expectUnique(placements)
    for (index, placement) in placements.enumerated() {
      let directory = root.appendingPathComponent(placement.relativePath)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data("album-\(index)".utf8).write(
        to: directory.appendingPathComponent("SAME.JPG"), options: .withoutOverwriting)
    }
    for (index, placement) in placements.enumerated() {
      let file = root.appendingPathComponent(placement.relativePath).appendingPathComponent(
        "SAME.JPG")
      #expect(try Data(contentsOf: file) == Data("album-\(index)".utf8))
    }
    // The same bytes assertions run on both formats. Case-insensitive hosts also
    // exercise the physical alias that the synthetic path oracle detects everywhere.
    if caseInsensitive {
      let paths = placements.map {
        root.appendingPathComponent($0.relativePath).appendingPathComponent("SAME.JPG")
      }
      let first = try FileManager.default.attributesOfItem(atPath: paths[0].path)
      let second = try FileManager.default.attributesOfItem(atPath: paths[1].path)
      #expect(first[.systemFileNumber] as? NSNumber != second[.systemFileNumber] as? NSNumber)
    }
  }
}
