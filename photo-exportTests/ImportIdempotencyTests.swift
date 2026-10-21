import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Regression gate for import idempotency. Imports a backup fixture twice and asserts that
/// the timeline and collection record stores, in memory and on disk, are unchanged by the
/// second import, so a user re-running an import doesn't see records drift, get rewritten,
/// duplicate, or reorder.
///
/// Existing `ExportManagerImportTests` covers the *first* import. This test covers the
/// idempotency property — load-bearing because:
///   1. Auto-export and manual import compete for the same record state; a second
///      import must not undo a fresh write.
///   2. `BackupScanner` + `bulkImportRecords` together can produce different records
///      for the same input if any step is non-deterministic (ordering, timing, retry).
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct ImportIdempotencyTests {

  // MARK: - Fixtures (mirrored from ExportManagerImportTests)

  private func makeTestHarness() -> (
    ExportManager, FakePhotoLibraryService, FakeExportDestination, ExportRecordStore, URL,
    CollectionExportRecordStore
  ) {
    let harness = ExportManagerHarness(
      label: "ImportIdempotency")
    return (
      harness.manager, harness.photoLib, harness.dest, harness.store, harness.storeRoot,
      harness.collectionStore
    )
  }

  /// The on-disk record files for one store: the append log (which a rewrite would grow)
  /// and the compacted snapshot (absent until compaction).
  private func persistedBytes(storeRoot: URL, log: String, snapshot: String) throws
    -> (log: Data, snapshot: Data?)
  {
    let dir = storeRoot.appendingPathComponent("test", isDirectory: true)
    let logData = try Data(contentsOf: dir.appendingPathComponent(log))
    let snapshotURL = dir.appendingPathComponent(snapshot)
    let snapshotData =
      FileManager.default.fileExists(atPath: snapshotURL.path)
      ? try Data(contentsOf: snapshotURL) : nil
    return (logData, snapshotData)
  }

  private func plantBackupFile(
    in dest: FakeExportDestination, year: Int, month: Int, filename: String,
    content: String = "x", modDate: Date? = nil
  ) throws {
    let dir = try dest.urlForRelativeDirectory(
      "\(year)/" + String(format: "%02d", month) + "/", createIfNeeded: true)
    let fileURL = dir.appendingPathComponent(filename)
    try Data(content.utf8).write(to: fileURL)
    if let modDate {
      try FileManager.default.setAttributes(
        [.modificationDate: modDate], ofItemAtPath: fileURL.path)
    }
  }

  private func date(year: Int, month: Int, day: Int, hour: Int = 12) -> Date {
    var c = DateComponents()
    c.year = year
    c.month = month
    c.day = day
    c.hour = hour
    return Calendar.current.date(from: c)!
  }

  /// Captures the deterministic per-asset shape needed for equality across imports.
  /// Excludes `exportDate` (wall-clock when the record was written) since two imports
  /// run at different instants — only the *deterministic* record content needs to be
  /// equal.
  private struct AssetRecordShape: Equatable {
    let assetId: String
    let year: Int
    let month: Int
    let relPath: String
    let originalStatus: ExportStatus?
    let originalFilename: String?
    let originalLastError: String?
    let editedStatus: ExportStatus?
    let editedFilename: String?
    let editedLastError: String?

    init(_ record: ExportRecord) {
      assetId = record.id
      year = record.year
      month = record.month
      relPath = record.relPath
      let originalVariant = record.variants[.original]
      originalStatus = originalVariant?.status
      originalFilename = originalVariant?.filename
      originalLastError = originalVariant?.lastError
      let editedVariant = record.variants[.edited]
      editedStatus = editedVariant?.status
      editedFilename = editedVariant?.filename
      editedLastError = editedVariant?.lastError
    }
  }

  private func snapshot(_ store: ExportRecordStore) -> [String: AssetRecordShape] {
    var result: [String: AssetRecordShape] = [:]
    for record in store.recordsById.values {
      result[record.id] = AssetRecordShape(record)
    }
    return result
  }

  // MARK: - Tests

  /// Pins the import stage-transition sequence: `.scanningBackupFolder` →
  /// `.readingPhotosLibrary` → `.rebuildingLocalState` → `.reconcilingDiskState` →
  /// `.done`. Reordering bulkImport vs reconcile, or moving the matcher around the
  /// scanner, would produce the same final record snapshot on a happy-path fixture
  /// while breaking the UI's progress story. The idempotency test below would only
  /// catch reorderings incidentally (e.g. via a different `prunedRecords` count on a
  /// ghost file); this test pins the contract directly.
  @Test func importStageSequenceMatchesContract() async throws {
    let (manager, photoLib, dest, _, storeRoot, _) = makeTestHarness()
    defer {
      try? FileManager.default.removeItem(at: storeRoot)
      dest.cleanup()
    }

    let stageDate = date(year: 2025, month: 6, day: 15)
    try plantBackupFile(
      in: dest, year: 2025, month: 6, filename: "STAGE.JPG", modDate: stageDate)
    let asset = TestAssetFactory.makeAsset(
      id: "stage-asset", creationDate: stageDate, mediaType: .image)
    photoLib.assetsByYearMonth["2025-6"] = [asset]
    photoLib.resourcesByAssetId[asset.id] = [
      TestAssetFactory.makeResource(originalFilename: "STAGE.JPG")
    ]

    var seenStages: [BackupScanner.ImportStage] = []
    let cancellable = manager.$importStage.sink { stage in
      if let stage { seenStages.append(stage) }
    }
    defer { cancellable.cancel() }

    manager.startImport()
    await manager.waitForImportCompletion()

    // Drop adjacent duplicates: matchFiles emits its own `.readingPhotosLibrary` →
    // intermediate stages → repeated `.readingPhotosLibrary` pattern. The contract is
    // about the *transition sequence* across the five named phases, not the raw count.
    var canonical: [BackupScanner.ImportStage] = []
    for stage in seenStages where canonical.last != stage {
      canonical.append(stage)
    }

    let expected: [BackupScanner.ImportStage] = [
      .scanningBackupFolder,
      .readingPhotosLibrary,
      .rebuildingLocalState,
      .reconcilingDiskState,
      .done,
    ]
    #expect(
      canonical == expected,
      """
      Import stage-sequence contract violation. Expected: \(expected) Got: \(canonical)
      """)
  }

  /// Plants three backup files (two that match library assets, one unmatched) plus a
  /// Favorites export with one file present and one missing. The first import lands the
  /// timeline records and prunes the missing Favorites record, which proves the
  /// collection store was reconciled. The second import must leave both stores' records
  /// (including `exportDate`) and their on-disk files unchanged, and report the same
  /// counts.
  @Test func bulkImportIsIdempotent() async throws {
    let (manager, photoLib, dest, store, storeRoot, collections) = makeTestHarness()
    defer {
      store.drainSynchronously()
      collections.drainSynchronously()
      try? FileManager.default.removeItem(at: storeRoot)
      dest.cleanup()
    }

    // Plant three files, two of which have library asset counterparts.
    let dateA = date(year: 2025, month: 6, day: 15)
    let dateB = date(year: 2025, month: 7, day: 2)
    try plantBackupFile(
      in: dest, year: 2025, month: 6, filename: "IMG_0001.JPG", modDate: dateA)
    try plantBackupFile(
      in: dest, year: 2025, month: 7, filename: "IMG_0002.JPG", modDate: dateB)
    try plantBackupFile(
      in: dest, year: 2025, month: 7, filename: "IMG_GHOST.JPG", modDate: dateB)

    let assetA = TestAssetFactory.makeAsset(id: "asset-A", creationDate: dateA, mediaType: .image)
    let assetB = TestAssetFactory.makeAsset(id: "asset-B", creationDate: dateB, mediaType: .image)
    photoLib.assetsByYearMonth["2025-6"] = [assetA]
    photoLib.assetsByYearMonth["2025-7"] = [assetB]
    photoLib.resourcesByAssetId[assetA.id] = [
      TestAssetFactory.makeResource(originalFilename: "IMG_0001.JPG")
    ]
    photoLib.resourcesByAssetId[assetB.id] = [
      TestAssetFactory.makeResource(originalFilename: "IMG_0002.JPG")
    ]

    let favorites = ExportPlacement.favorites()
    collections.upsertPlacement(favorites)
    for assetId in ["fav-kept", "fav-missing"] {
      collections.markVariantExported(
        assetId: assetId, placement: favorites, variant: .original,
        filename: "\(assetId).JPG", exportedAt: dateA)
    }
    let favoritesDir = try dest.urlForRelativeDirectory(
      favorites.relativePath, createIfNeeded: true)
    try Data("kept".utf8).write(to: favoritesDir.appendingPathComponent("fav-kept.JPG"))
    try #require(collections.exportInfo(assetId: "fav-missing", placement: favorites) != nil)

    // First import.
    manager.startImport()
    await manager.waitForImportCompletion()
    try #require(
      collections.exportInfo(assetId: "fav-kept", placement: favorites)?
        .variants[.original]?.status == .done,
      "the Favorites record whose file exists must survive reconcile")
    try #require(
      collections.exportInfo(assetId: "fav-missing", placement: favorites) == nil,
      "the first import must prune the Favorites record whose file is missing")
    let firstReport = manager.importResult
    #expect(firstReport?.matchedCount == 2)
    #expect(firstReport?.unmatchedCount == 1)
    #expect(firstReport?.totalScanned == 3)

    let firstSnapshot = snapshot(store)
    #expect(
      firstSnapshot.count == 2,
      "first import must land exactly 2 records (one per matched file)")
    store.drainSynchronously()
    collections.drainSynchronously()
    let firstRecords = store.recordsById
    let firstCollectionRecords = collections.recordBodies
    let firstTimelineFiles = try persistedBytes(
      storeRoot: storeRoot, log: "export-records.jsonl", snapshot: "export-records.json")
    let firstCollectionFiles = try persistedBytes(
      storeRoot: storeRoot, log: "collection-records.jsonl", snapshot: "collection-records.json")
    try #require(!firstTimelineFiles.log.isEmpty && !firstCollectionFiles.log.isEmpty)

    // Second import against the same fixture. Reset importResult to confirm the second
    // pass writes a fresh report.
    manager.importResult = nil
    manager.startImport()
    await manager.waitForImportCompletion()
    let secondReport = manager.importResult
    #expect(
      secondReport?.matchedCount == 2,
      "matched count must be identical across re-imports")
    #expect(
      secondReport?.unmatchedCount == 1,
      "unmatched count must be identical across re-imports")
    #expect(secondReport?.totalScanned == 3)

    let secondSnapshot = snapshot(store)

    // The deterministic record shape must be identical across the two imports.
    #expect(
      firstSnapshot == secondSnapshot,
      """
      Bulk-import idempotency violated.
      First:  \(firstSnapshot)
      Second: \(secondSnapshot)
      """)
    // Nothing may be rewritten either: same full records (including `exportDate`) and the
    // same bytes on disk, so the second import appended nothing.
    store.drainSynchronously()
    collections.drainSynchronously()
    #expect(store.recordsById == firstRecords)
    #expect(collections.recordBodies == firstCollectionRecords)
    let secondTimelineFiles = try persistedBytes(
      storeRoot: storeRoot, log: "export-records.jsonl", snapshot: "export-records.json")
    let secondCollectionFiles = try persistedBytes(
      storeRoot: storeRoot, log: "collection-records.jsonl", snapshot: "collection-records.json")
    #expect(secondTimelineFiles.log == firstTimelineFiles.log)
    #expect(secondTimelineFiles.snapshot == firstTimelineFiles.snapshot)
    #expect(secondCollectionFiles.log == firstCollectionFiles.log)
    #expect(secondCollectionFiles.snapshot == firstCollectionFiles.snapshot)
  }

  /// Album, shared-album and Favorites folders imported twice: the second import adopts the
  /// same placements, reports the same counts and writes no bytes to either history.
  @Test func collectionAdoptionIsIdempotent() async throws {
    let (manager, photoLib, dest, store, storeRoot, collections) = makeTestHarness()
    defer {
      store.drainSynchronously()
      collections.drainSynchronously()
      try? FileManager.default.removeItem(at: storeRoot)
      dest.cleanup()
    }
    let shotDate = date(year: 2025, month: 6, day: 15)
    let photo = TestAssetFactory.makeAsset(id: "photo", creationDate: shotDate, mediaType: .image)
    let shared = TestAssetFactory.makeAsset(
      id: "shared", creationDate: date(year: 2025, month: 6, day: 16), mediaType: .image)
    photoLib.resourcesByAssetId["photo"] = [
      TestAssetFactory.makeResource(originalFilename: "IMG_0001.JPG")
    ]
    photoLib.resourcesByAssetId["shared"] = [
      TestAssetFactory.makeResource(originalFilename: "IMG_0002.JPG")
    ]
    photoLib.collectionTree = [
      CollectionBackupFixture.folder(
        "trips", "Trips", children: [CollectionBackupFixture.album("paris", "Paris", in: ["Trips"])]
      ),
      CollectionBackupFixture.sharedAlbum("family", "Family"),
    ]
    photoLib.assetsByYearMonth["2025-6"] = [photo]
    photoLib.assetsByAlbumLocalId["paris"] = [photo]
    photoLib.favoritesAssets = [photo]
    photoLib.assetsBySharedAlbumLocalId["family"] = [shared]
    for (folder, name, fileDate) in [
      ("2025/06/", "IMG_0001.JPG", shotDate),
      ("Collections/Albums/Trips/Paris/", "IMG_0001.JPG", shotDate),
      ("Collections/Favorites/", "IMG_0001.JPG", shotDate),
      ("Collections/Shared Albums/Family/", "IMG_0002.JPG", shared.creationDate!),
      ("Collections/Albums/Old/", "OLD.JPG", shotDate),
    ] {
      try CollectionBackupFixture.plant(at: dest.rootURL, folder, name, date: fileDate)
    }

    manager.startImport()
    await manager.waitForImportCompletion()
    let first = try #require(manager.importResult)
    try #require(first.collectionMatchedCount == 3)
    store.drainSynchronously()
    collections.drainSynchronously()
    let firstPlacements = collections.placements
    let firstRecords = collections.recordBodies
    let firstTimelineFiles = try persistedBytes(
      storeRoot: storeRoot, log: "export-records.jsonl", snapshot: "export-records.json")
    let firstCollectionFiles = try persistedBytes(
      storeRoot: storeRoot, log: "collection-records.jsonl", snapshot: "collection-records.json")

    manager.importResult = nil
    manager.startImport()
    await manager.waitForImportCompletion()
    let second = try #require(manager.importResult)
    store.drainSynchronously()
    collections.drainSynchronously()

    #expect(second == first)
    #expect(
      collections.placements.mapValues(\.relativePath) == firstPlacements.mapValues(\.relativePath))
    #expect(collections.placements.mapValues(\.createdAt) == firstPlacements.mapValues(\.createdAt))
    #expect(collections.recordBodies == firstRecords)
    let secondTimelineFiles = try persistedBytes(
      storeRoot: storeRoot, log: "export-records.jsonl", snapshot: "export-records.json")
    let secondCollectionFiles = try persistedBytes(
      storeRoot: storeRoot, log: "collection-records.jsonl", snapshot: "collection-records.json")
    #expect(secondTimelineFiles.log == firstTimelineFiles.log)
    #expect(secondTimelineFiles.snapshot == firstTimelineFiles.snapshot)
    #expect(secondCollectionFiles.log == firstCollectionFiles.log)
    #expect(secondCollectionFiles.snapshot == firstCollectionFiles.snapshot)
  }
}
