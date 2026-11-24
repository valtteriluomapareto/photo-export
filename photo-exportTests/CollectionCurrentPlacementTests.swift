import Foundation
import Testing

@testable import Photo_Export

@MainActor
struct CollectionCurrentPlacementTests {
  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func currentPlacementLookupIsExactAndReadOnly(shared: Bool) async throws {
    let root = TestScratch.directory("CurrentPlacementLookup")
    let collections = CollectionExportRecordStore(baseDirectoryURL: root)
    await collections.configureAndWait(for: "A")
    defer {
      collections.drainSynchronously()
      try? FileManager.default.removeItem(at: root)
    }
    func record(_ status: ExportStatus, error: String? = nil) -> ExportVariantRecord {
      .init(filename: "FILE.JPG", status: status, exportDate: nil, lastError: error)
    }
    func set(_ placement: ExportPlacement, variants: [ExportVariant: ExportVariantRecord]) {
      collections.upsertPlacement(placement)
      collections.upsert(.init(placement: placement, assetId: "selected", variants: variants))
    }
    let kind: PhotoCollectionDescriptor.Kind = shared ? .sharedAlbum : .album
    let selection: LibrarySelection =
      shared ? .sharedAlbum(collectionId: "album") : .album(collectionId: "album")
    func album(_ title: String, parent: [String] = []) -> PhotoCollectionDescriptor {
      PhotoCollectionDescriptor(
        id: "album", localIdentifier: "album", title: title, kind: kind, pathComponents: parent,
        children: [])
    }
    let resolver = ExportPlacementResolver()
    let prior = album("Old")
    let old = try resolver.placement(
      for: selection, collections: [prior], existingPlacements: [])
    set(old, variants: [.original: record(.done)])
    try await collections.flush()
    let count = collections.mutationCounter
    let keys = Set(collections.placements.keys)
    for changed in [album("New"), album("Old", parent: shared ? [] : ["Moved"])] {
      let result = collections.currentPlacement(for: selection, collections: [changed])
      if !shared || changed.title == "New" { #expect(result == nil) }
    }
    #expect(collections.currentPlacement(for: selection, collections: []) == nil)
    #expect(collections.mutationCounter == count)
    #expect(Set(collections.placements.keys) == keys)
    let current = album("New")
    let fresh = try resolver.placement(
      for: selection, collections: [current], existingPlacements: [old])
    set(fresh, variants: [.original: record(.failed, error: "current failure")])
    let found = try #require(
      collections.currentPlacement(for: selection, collections: [current]))
    #expect(found.id == fresh.id)
    #expect(found.relativePath == fresh.relativePath)
    #expect(found.id != old.id)
    #expect(
      collections.exportInfo(assetId: "selected", placement: old)?.variants[
        .original]?.status == .done)
  }
}
