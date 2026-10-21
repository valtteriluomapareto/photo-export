import Foundation
import Testing

@testable import Photo_Export

/// `CollectionExportRecordStore.bulkImportRecords` records what Import Existing Backup found in
/// collection folders using the existing log operations: a new placement before its records,
/// completed variants left alone, and no write at all when nothing changes.
@MainActor
struct CollectionBulkImportTests {
  private let date = Date(timeIntervalSince1970: 1_700_000_000)

  private func makeStore() throws -> (URL, CollectionExportRecordStore) {
    let dir = TestScratch.directory("CollectionBulkImport")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = CollectionExportRecordStore(baseDirectoryURL: dir)
    store.configure(for: "dest")
    return (dir, store)
  }

  private func album(path: String = "Collections/Albums/Trips/Paris/", createdAt: Date? = nil)
    -> ExportPlacement
  {
    ExportPlacement(
      kind: .album, id: "collections:album:1111111111111111:22222222",
      displayName: "Trips/Paris", collectionLocalIdentifier: "paris", relativePath: path,
      createdAt: createdAt ?? date)
  }

  private func done(_ filename: String, subfolder: String? = nil) -> ExportVariantRecord {
    ExportVariantRecord(
      filename: filename, status: .done, exportDate: date, lastError: nil, subfolder: subfolder)
  }

  private func logBytes(_ dir: URL) -> Data? {
    try? Data(
      contentsOf: dir.appendingPathComponent("dest/collection-records.jsonl"))
  }

  @Test func addsPlacementBeforeItsRecords() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let placement = album()

    let batch = CollectionExportRecordStore.ImportBatch(
      placement: placement,
      records: [
        "a": [.original: done("A.JPG")], "v": [.original: done("V.MOV", subfolder: "videos")],
      ])
    store.bulkImportRecords([batch])

    #expect(store.placements.count == 1)
    #expect(store.recordedVariantCount(of: [batch]) == 2)
    #expect(store.placements[placement.id]?.relativePath == placement.relativePath)
    #expect(
      store.exportInfo(assetId: "a", placement: placement)?.variants[.original]?.status == .done)
    #expect(
      store.exportInfo(assetId: "v", placement: placement)?.variants[.original]?.subfolder
        == "videos")
    store.drainSynchronously()
    let lines = try #require(logBytes(dir)).split(separator: UInt8(ascii: "\n"))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let ops = try lines.map {
      try decoder.decode(CollectionExportRecordStore.LogOp.self, from: Data($0))
    }
    guard case .upsertPlacement(let id, _) = ops.first else {
      Issue.record("The placement must be written before its records: \(ops)")
      return
    }
    #expect(id == placement.id)
    #expect(ops.dropFirst().allSatisfy { if case .upsertRecord = $0 { true } else { false } })
  }

  @Test func skipsDoneVariantsAndOverwritesOthers() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let placement = album()
    store.upsertPlacement(placement)
    store.markVariantExported(
      assetId: "a", placement: placement, variant: .original, filename: "KEEP.JPG",
      exportedAt: date)
    store.markVariantFailed(
      assetId: "b", placement: placement, variant: .original, error: "disk", at: date)

    let batch = CollectionExportRecordStore.ImportBatch(
      placement: placement,
      records: ["a": [.original: done("OTHER.JPG")], "b": [.original: done("B.JPG")]])
    store.bulkImportRecords([batch])

    #expect(store.placements.count == 1)
    #expect(store.recordedVariantCount(of: [batch]) == 2)
    #expect(
      store.exportInfo(assetId: "a", placement: placement)?.variants[.original]?.filename
        == "KEEP.JPG")
    let b = store.exportInfo(assetId: "b", placement: placement)?.variants[.original]
    #expect(b?.status == .done)
    #expect(b?.filename == "B.JPG")
    #expect(b?.lastError == nil)
  }

  @Test func keepsASavedPlacement() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let saved = album(createdAt: Date(timeIntervalSince1970: 1))
    store.upsertPlacement(saved)

    store.bulkImportRecords([
      .init(placement: album(), records: ["a": [.original: done("A.JPG")]])
    ])

    #expect(store.placements.count == 1)
    #expect(store.exportInfo(assetId: "a", placement: saved)?.variants[.original]?.status == .done)
    #expect(store.placements[saved.id]?.createdAt == saved.createdAt)

    // A saved placement at another folder keeps its folder; files found elsewhere are not
    // recorded under it.
    let elsewhere = CollectionExportRecordStore.ImportBatch(
      placement: album(path: "Collections/Albums/Paris/"),
      records: ["b": [.original: done("B.JPG")]])
    store.bulkImportRecords([elsewhere])
    #expect(store.recordedVariantCount(of: [elsewhere]) == 0)
    #expect(store.placements[saved.id]?.relativePath == saved.relativePath)
    #expect(store.exportInfo(assetId: "b", placement: saved) == nil)
  }

  @Test func rejectsTimelinePlacements() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    store.bulkImportRecords([
      .init(
        placement: .timeline(year: 2025, month: 1), records: ["a": [.original: done("A.JPG")]])
    ])
    #expect(store.placements.isEmpty)
    #expect(store.recordBodies.isEmpty)
  }

  @Test func ignoresAStoreThatIsNotReady() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    store.configure(for: nil)
    store.bulkImportRecords([
      .init(placement: album(), records: ["a": [.original: done("A.JPG")]])
    ])
    #expect(store.placements.isEmpty)
    #expect(store.recordBodies.isEmpty)
  }

  @Test func importSurvivesAReload() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let placement = album()
    store.bulkImportRecords([
      .init(
        placement: placement,
        records: ["a": [.original: done("A.JPG"), .edited: done("A.HEIC")]])
    ])
    store.drainSynchronously()

    let reopened = CollectionExportRecordStore(baseDirectoryURL: dir)
    reopened.configure(for: "dest")
    #expect(reopened.state == .ready)
    #expect(reopened.placements[placement.id]?.relativePath == placement.relativePath)
    let variants = reopened.exportInfo(assetId: "a", placement: placement)?.variants
    #expect(variants?[.original]?.filename == "A.JPG")
    #expect(variants?[.edited]?.filename == "A.HEIC")
    reopened.drainSynchronously()
  }

  @Test func repeatedImportWritesNoBytes() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let batch = CollectionExportRecordStore.ImportBatch(
      placement: album(), records: ["a": [.original: done("A.JPG")]])
    store.bulkImportRecords([batch])
    store.drainSynchronously()
    let before = try #require(logBytes(dir))
    store.flushPendingNotifications()
    let counter = store.mutationCounter

    store.bulkImportRecords([batch])
    store.drainSynchronously()

    #expect(store.recordedVariantCount(of: [batch]) == 1)
    #expect(logBytes(dir) == before)
    store.flushPendingNotifications()
    #expect(store.mutationCounter == counter)
  }
}
