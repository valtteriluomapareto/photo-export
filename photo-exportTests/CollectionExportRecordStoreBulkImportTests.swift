import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Tests for `CollectionExportRecordStore.bulkImportRecords(placements:entries:)`.
/// Issue #106 — collection-side counterpart to `ExportRecordStore.bulkImportRecords`.
///
/// The store-level invariants (placements upserted before records, idempotent
/// per-variant merge, `.timeline` placement refusal, early-return on non-`.ready`).
@MainActor
struct CollectionExportRecordStoreBulkImportTests {

  // MARK: - Fixtures

  private func makeReadyStore() throws -> (URL, CollectionExportRecordStore) {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("CollectionBulkImport-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = CollectionExportRecordStore(baseDirectoryURL: dir)
    store.configure(for: "test")
    return (dir, store)
  }

  private let favoritesPlacement = ExportPlacement.favorites(
    createdAt: Date(timeIntervalSince1970: 1_700_000_000))

  private func albumPlacement(
    collectionId: String = "album-A",
    placementId: String = "collections:album:hash16:hash8",
    relativePath: String = "Collections/Albums/Trip/"
  ) -> ExportPlacement {
    ExportPlacement(
      kind: .album,
      id: placementId,
      displayName: "Trip",
      collectionLocalIdentifier: collectionId,
      relativePath: relativePath,
      createdAt: Date(timeIntervalSince1970: 1_700_000_001))
  }

  // MARK: - Happy path

  @Test func emptyStore_records_andPlacementsLand() throws {
    let (dir, store) = try makeReadyStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let placement = albumPlacement()
    let now = Date()
    let entries: [CollectionExportRecordStore.BulkImportEntry] = [
      .init(
        placement: placement, assetId: "asset-1", variant: .original,
        filename: "IMG_0001.JPG", exportedAt: now, subfolder: nil),
      .init(
        placement: placement, assetId: "asset-2", variant: .original,
        filename: "IMG_0002.JPG", exportedAt: now, subfolder: nil),
    ]
    store.bulkImportRecords(placements: [placement], entries: entries)
    store.flushForTesting()

    #expect(store.placements[placement.id] == placement)
    #expect(store.recordBodies[placement.id]?.count == 2)
    let body1 = store.recordBodies[placement.id]?["asset-1"]
    #expect(body1?.variants[ExportVariant.original.rawValue]?.filename == "IMG_0001.JPG")
    #expect(body1?.variants[ExportVariant.original.rawValue]?.status == .done)
  }

  @Test func mergesMultipleVariantsForSameAsset_intoOneRecordBody() throws {
    let (dir, store) = try makeReadyStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let placement = albumPlacement()
    let now = Date()
    store.bulkImportRecords(
      placements: [placement],
      entries: [
        .init(
          placement: placement, assetId: "asset-1", variant: .original,
          filename: "IMG_0001.JPG", exportedAt: now, subfolder: nil),
        .init(
          placement: placement, assetId: "asset-1", variant: .edited,
          filename: "IMG_0001.JPG", exportedAt: now, subfolder: nil),
      ])
    store.flushForTesting()

    let body = store.recordBodies[placement.id]?["asset-1"]
    #expect(body?.variants.count == 2)
    #expect(body?.variants[ExportVariant.original.rawValue]?.status == .done)
    #expect(body?.variants[ExportVariant.edited.rawValue]?.status == .done)
  }

  @Test func preservesSubfolder() throws {
    let (dir, store) = try makeReadyStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let placement = albumPlacement()
    let entry = CollectionExportRecordStore.BulkImportEntry(
      placement: placement, assetId: "v1", variant: .original,
      filename: "VID.MOV", exportedAt: Date(), subfolder: "videos")
    store.bulkImportRecords(placements: [placement], entries: [entry])
    store.flushForTesting()

    let body = store.recordBodies[placement.id]?["v1"]
    #expect(body?.variants[ExportVariant.original.rawValue]?.subfolder == "videos")
  }

  // MARK: - Idempotency

  @Test func existingDone_preserved_overIncomingDone() throws {
    let (dir, store) = try makeReadyStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let placement = albumPlacement()
    let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
    let laterDate = Date(timeIntervalSince1970: 1_800_000_000)

    store.bulkImportRecords(
      placements: [placement],
      entries: [
        .init(
          placement: placement, assetId: "asset-1", variant: .original,
          filename: "IMG_0001.JPG", exportedAt: firstDate, subfolder: nil)
      ])
    store.flushForTesting()

    // Re-import with a different exportedAt — existing .done wins.
    store.bulkImportRecords(
      placements: [placement],
      entries: [
        .init(
          placement: placement, assetId: "asset-1", variant: .original,
          filename: "IMG_0001.JPG", exportedAt: laterDate, subfolder: nil)
      ])
    store.flushForTesting()

    let body = store.recordBodies[placement.id]?["asset-1"]
    #expect(body?.variants[ExportVariant.original.rawValue]?.exportDate == firstDate)
  }

  @Test func existingFailed_replacedByIncomingDone() throws {
    let (dir, store) = try makeReadyStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let placement = albumPlacement()
    store.upsertPlacement(placement)
    store.markVariantFailed(
      assetId: "asset-1", placement: placement, variant: .original,
      error: "transient", at: Date(timeIntervalSince1970: 1_700_000_000))
    store.flushForTesting()

    let importDate = Date(timeIntervalSince1970: 1_800_000_000)
    store.bulkImportRecords(
      placements: [placement],
      entries: [
        .init(
          placement: placement, assetId: "asset-1", variant: .original,
          filename: "IMG_0001.JPG", exportedAt: importDate, subfolder: nil)
      ])
    store.flushForTesting()

    let body = store.recordBodies[placement.id]?["asset-1"]
    let original = body?.variants[ExportVariant.original.rawValue]
    #expect(original?.status == .done)
    #expect(original?.exportDate == importDate)
    #expect(original?.lastError == nil)
  }

  @Test func existingInProgress_recoveredToFailed_replacedByIncomingDone() throws {
    // `recoverInProgressVariants` runs on `configure()` and demotes any
    // `.inProgress` to `.failed` with the interrupted-message. The bulk
    // importer treats that `.failed` as weaker than the incoming `.done`,
    // so the import wins.
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("BulkInProg-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = CollectionExportRecordStore(baseDirectoryURL: dir)
    store.configure(for: "test")
    let placement = albumPlacement()
    store.upsertPlacement(placement)
    store.markVariantInProgress(
      assetId: "asset-1", placement: placement, variant: .original,
      filename: "IMG_0001.JPG")
    store.flushForTesting()

    // Simulate a fresh launch loading the same on-disk state — recover() runs
    // and the variant becomes .failed/interrupted.
    let store2 = CollectionExportRecordStore(baseDirectoryURL: dir)
    store2.configure(for: "test")
    let recovered = store2.recordBodies[placement.id]?["asset-1"]?.variants[
      ExportVariant.original.rawValue]
    #expect(recovered?.status == .failed)
    #expect(recovered?.lastError == ExportVariantRecovery.interruptedMessage)

    // Bulk-import overrides the recovered .failed with a fresh .done.
    let importDate = Date(timeIntervalSince1970: 1_800_000_000)
    store2.bulkImportRecords(
      placements: [placement],
      entries: [
        .init(
          placement: placement, assetId: "asset-1", variant: .original,
          filename: "IMG_0001.JPG", exportedAt: importDate, subfolder: nil)
      ])
    store2.flushForTesting()

    let body = store2.recordBodies[placement.id]?["asset-1"]
    let original = body?.variants[ExportVariant.original.rawValue]
    #expect(original?.status == .done)
    #expect(original?.exportDate == importDate)
  }

  // MARK: - Disjoint key space

  @Test func timelinePlacementInInput_refused() throws {
    // Defense-in-depth — `accept(_:)` should refuse a `.timeline` placement
    // even at the bulkImport entry point. The collection store must never
    // hold timeline placements.
    let (dir, store) = try makeReadyStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let timelinePlacement = ExportPlacement.timeline(year: 2025, month: 6)
    let entry = CollectionExportRecordStore.BulkImportEntry(
      placement: timelinePlacement, assetId: "asset-x", variant: .original,
      filename: "IMG.JPG", exportedAt: Date(), subfolder: nil)
    store.bulkImportRecords(placements: [timelinePlacement], entries: [entry])
    store.flushForTesting()

    #expect(store.placements[timelinePlacement.id] == nil)
    #expect(store.recordBodies[timelinePlacement.id] == nil)
  }

  @Test func entryWithoutMatchingPlacement_skipped() throws {
    // Caller-side mismatch: an entry references a placement that the caller
    // forgot to include in the `placements:` array. The bulk importer must
    // skip the entry (the `skippedNoPlacement` counter) rather than rely on
    // the in-store orphan-record guard to refuse it after the placement was
    // already accepted — otherwise the user would see "1 matched" in the
    // report despite zero records persisted. This pins the caller-mismatch
    // path; log-truncation orphans (where a corrupted log loses the
    // upsertPlacement line) are caught by the separate orphan-record guard
    // inside `apply(.upsertRecord)` during snapshot/log replay.
    let (dir, store) = try makeReadyStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let placementA = albumPlacement(
      collectionId: "A", placementId: "collections:album:A:hash", relativePath: "Collections/Albums/A/")
    let placementB = albumPlacement(
      collectionId: "B", placementId: "collections:album:B:hash", relativePath: "Collections/Albums/B/")
    let entry = CollectionExportRecordStore.BulkImportEntry(
      placement: placementB, assetId: "asset-b", variant: .original,
      filename: "IMG.JPG", exportedAt: Date(), subfolder: nil)
    store.bulkImportRecords(placements: [placementA], entries: [entry])
    store.flushForTesting()

    #expect(store.recordBodies[placementB.id] == nil)
    #expect(store.placements[placementA.id] == placementA)
  }

  // MARK: - State gates

  @Test func idempotentReimport_doesNotBloatLog() throws {
    // Re-importing the same placement+records should be log-size idempotent,
    // not just outcome-idempotent. Without the no-op check the JSONL would
    // grow on every re-import, eventually triggering compaction churn.
    let (dir, store) = try makeReadyStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let placement = albumPlacement()
    let entry = CollectionExportRecordStore.BulkImportEntry(
      placement: placement, assetId: "asset-1", variant: .original,
      filename: "IMG.JPG", exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
      subfolder: nil)
    store.bulkImportRecords(placements: [placement], entries: [entry])
    store.flushForTesting()

    let logURL = dir.appendingPathComponent("test/collection-records.jsonl")
    let firstSize = (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size]
      as? Int) ?? 0

    // Re-import identical input. The record write still appends (because the
    // `.done` check fires before the merge — same input twice is one variant
    // write the second time? actually no: the existing .done wins → 0 writes).
    // The placement upsert MUST also be skipped, which is what this test pins.
    store.bulkImportRecords(placements: [placement], entries: [entry])
    store.flushForTesting()
    let secondSize = (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size]
      as? Int) ?? 0

    #expect(firstSize == secondSize, "Re-importing identical inputs grew the log")
  }

  @Test func failedState_isNoOp() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("CollectionBulkFailed-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // Plant a corrupt snapshot to force .failed on configure.
    let storeDir = dir.appendingPathComponent("test", isDirectory: true)
    try FileManager.default.createDirectory(
      at: storeDir, withIntermediateDirectories: true)
    try Data("{not valid json".utf8).write(
      to: storeDir.appendingPathComponent("collection-records.json"))

    let store = CollectionExportRecordStore(baseDirectoryURL: dir)
    store.configure(for: "test")
    #expect(store.state == .failed)

    let placement = albumPlacement()
    store.bulkImportRecords(
      placements: [placement],
      entries: [
        .init(
          placement: placement, assetId: "x", variant: .original,
          filename: "IMG.JPG", exportedAt: Date(), subfolder: nil)
      ])
    store.flushForTesting()

    #expect(store.placements.isEmpty)
    #expect(store.recordBodies.isEmpty)
  }
}
