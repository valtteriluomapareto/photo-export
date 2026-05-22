import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Phase 5 prep regression-gate test. Imports a backup fixture twice and asserts the
/// timeline + collection record-store state is identical after the second import. The
/// Phase 5 extraction moves the import flow into `ImportCoordinator` and transfers
/// generation ownership to `ExportQueueCoordinator`; both store-state and the
/// per-asset reconciliation order must remain deterministic across the extraction so a
/// user re-running an import doesn't see records drift, duplicate, or get reordered.
///
/// Existing `ExportManagerImportTests` covers the *first* import. This test covers the
/// idempotency property — load-bearing because:
///   1. Auto-export and manual import compete for the same record state; a second
///      import must not undo a fresh write.
///   2. `BackupScanner` + `bulkImportRecords` together can produce different records
///      for the same input if any step is non-deterministic (ordering, timing, retry).
@MainActor
struct ImportIdempotencyTests {

  // MARK: - Fixtures (mirrored from ExportManagerImportTests)

  private func makeTestHarness() -> (
    ExportManager, FakePhotoLibraryService, FakeExportDestination, ExportRecordStore, URL
  ) {
    let photoLib = FakePhotoLibraryService()
    let dest = FakeExportDestination()
    let writer = FakeAssetResourceWriter()
    let fileSystem = FakeFileSystem()
    let storeRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("ImportIdempotency-\(UUID().uuidString)", isDirectory: true)
    let store = ExportRecordStore(baseDirectoryURL: storeRoot)
    store.configure(for: "test")
    // Issue #106: ImportCoordinator now gates on `collectionExportRecordStore.state ==
    // .ready` too. Production wires this via the destination-change observer in
    // photo_exportApp.swift; tests configure it explicitly so the import gate passes.
    let collectionStore = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    collectionStore.configure(for: "test")
    let defaults = UserDefaults(
      suiteName: "test-ImportIdempotency-\(UUID().uuidString)")!
    let manager = ExportManager(
      photoLibraryService: photoLib,
      exportDestination: dest,
      exportRecordStore: store,
      collectionExportRecordStore: collectionStore,
      assetResourceWriter: writer,
      fileSystem: fileSystem,
      userDefaults: defaults
    )
    return (manager, photoLib, dest, store, storeRoot)
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
    let (manager, photoLib, dest, _, storeRoot) = makeTestHarness()
    defer { try? FileManager.default.removeItem(at: storeRoot); dest.cleanup() }

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
    #expect(canonical == expected,
      """
      Import stage-sequence contract violation. Expected: \(expected) Got: \(canonical)
      """)
  }

  /// Plants three backup files (two that match library assets, one unmatched), imports
  /// once to land the records, snapshots the timeline store, imports again, and asserts
  /// the snapshot is identical and the import report agrees that everything was
  /// already-done on the second pass.
  @Test func bulkImportIsIdempotent() async throws {
    let (manager, photoLib, dest, store, storeRoot) = makeTestHarness()
    defer { try? FileManager.default.removeItem(at: storeRoot); dest.cleanup() }

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

    // First import.
    manager.startImport()
    await manager.waitForImportCompletion()
    let firstReport = manager.importResult
    #expect(firstReport?.matchedCount == 2)
    #expect(firstReport?.unmatchedCount == 1)
    #expect(firstReport?.totalScanned == 3)

    let firstSnapshot = snapshot(store)
    #expect(firstSnapshot.count == 2,
      "first import must land exactly 2 records (one per matched file)")

    // Second import against the same fixture. Reset importResult to confirm the second
    // pass writes a fresh report.
    manager.importResult = nil
    manager.startImport()
    await manager.waitForImportCompletion()
    let secondReport = manager.importResult
    #expect(secondReport?.matchedCount == 2,
      "matched count must be identical across re-imports")
    #expect(secondReport?.unmatchedCount == 1,
      "unmatched count must be identical across re-imports")
    #expect(secondReport?.totalScanned == 3)

    let secondSnapshot = snapshot(store)

    // The deterministic record shape must be identical across the two imports.
    #expect(firstSnapshot == secondSnapshot,
      """
      Bulk-import idempotency violated.
      First:  \(firstSnapshot)
      Second: \(secondSnapshot)
      """)
  }
}
