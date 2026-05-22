import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Closes a P0 coverage gap on the **Import Existing Backup** flow
/// (`ExportManager.swift:1280-1438`). Both `startImport` and `cancelImport` had
/// zero direct tests before this file. They are user-facing commands wired to
/// **File → Import Existing Backup…** and the kebab-menu cancel; a regression
/// here would silently drop imported records, leak generations, or strand the
/// UI in a stuck-importing state — none of which any other test would catch.
///
/// The tests use real backup folders on disk (cheap; the `BackupScanner` itself
/// is well-covered by `BackupScannerTests`) and a `FakePhotoLibraryService`
/// to stage Photos-library matches.
@MainActor
struct ExportManagerImportTests {

  // MARK: - Fixtures

  private func makeTestHarness() -> (
    ExportManager, FakePhotoLibraryService, FakeExportDestination, ExportRecordStore, URL
  ) {
    let photoLib = FakePhotoLibraryService()
    let dest = FakeExportDestination()
    let writer = FakeAssetResourceWriter()
    let fileSystem = FakeFileSystem()
    let storeRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("ExportManagerImport-\(UUID().uuidString)", isDirectory: true)
    let store = ExportRecordStore(baseDirectoryURL: storeRoot)
    store.configure(for: "test")
    // Issue #106: ImportCoordinator now gates on `collectionExportRecordStore.state ==
    // .ready` too. Production wires this via the destination-change observer in
    // photo_exportApp.swift; tests configure it explicitly so the import gate passes.
    let collectionStore = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    collectionStore.configure(for: "test")
    let defaults = UserDefaults(
      suiteName: "test-ExportManagerImport-\(UUID().uuidString)")!
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

  /// Plants a real file at `<dest.rootURL>/YYYY/MM/<filename>` with given content
  /// and modification date. The modification date is load-bearing for matching: the
  /// `BackupScanner.matchFiles` confirmation step compares `ScannedFile.modificationDate`
  /// against the candidate asset's `creationDate`. Without the date set, matching falls
  /// back to filename-only with weaker confirmation and the result is typically
  /// `ambiguous` rather than `matched`.
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

  // MARK: - cancelImport

  /// `cancelImport` when no import is running is a no-op. Mirror to the
  /// `pause`/`resume` no-op tests.
  @Test func cancelImportWhenNotImportingIsNoOp() {
    let (manager, _, _, _, storeRoot) = makeTestHarness()
    defer { try? FileManager.default.removeItem(at: storeRoot) }

    let genBefore = manager.totalJobsEnqueued  // any state we can read
    manager.cancelImport()
    #expect(!manager.isImporting)
    #expect(manager.importStage == nil)
    #expect(manager.importResult == nil)
    #expect(manager.totalJobsEnqueued == genBefore)
  }

  /// `cancelImport` while an import is in flight: clears `isImporting`,
  /// `importStage`, `importResult`, cancels the task, and bumps `generation` so
  /// any late-completing import work gates out via the `self.generation == importGen`
  /// checks scattered throughout the import task body.
  @Test func cancelImportDuringRunClearsStateAndBumpsGeneration() async throws {
    let (manager, _, dest, _, storeRoot) = makeTestHarness()
    defer { try? FileManager.default.removeItem(at: storeRoot); dest.cleanup() }

    // First call flips isImporting=true synchronously.
    manager.startImport()
    #expect(manager.isImporting)
    let genBefore = manager.generation

    // Cancel from the same actor frame, before the Task body runs to completion.
    manager.cancelImport()
    #expect(!manager.isImporting)
    #expect(manager.importStage == nil)
    #expect(manager.importResult == nil)
    #expect(manager.generation == genBefore + 1, "generation must bump")

    // No late-completion mutation must arrive after cancel.
    try? await Task.sleep(nanoseconds: 100_000_000)
    #expect(!manager.isImporting)
    #expect(manager.importStage == nil)
    #expect(manager.importResult == nil)
  }

  // MARK: - startImport guards

  /// `startImport` is no-op when `isImporting == true`. Verified synchronously: the
  /// first call flips `isImporting` to true before returning (the Task hasn't
  /// necessarily run its body yet); a second call from the same actor frame must
  /// hit the `guard !isImporting` early return.
  @Test func startImportWhenAlreadyImportingIsNoOp() async throws {
    let (manager, _, dest, _, storeRoot) = makeTestHarness()
    defer { try? FileManager.default.removeItem(at: storeRoot); dest.cleanup() }

    manager.startImport()
    #expect(manager.isImporting, "first call must flip isImporting synchronously")

    // Second call: must early-return on the guard. The state must not change in any
    // way the second call could plausibly mutate.
    let stageBefore = manager.importStage
    manager.startImport()
    #expect(manager.isImporting)
    #expect(manager.importStage == stageBefore)

    // Drain so the harness teardown is clean.
    await manager.waitForImportCompletion()
  }

  @Test func startImportWithoutDestinationIsNoOp() {
    let (manager, _, dest, _, storeRoot) = makeTestHarness()
    defer { try? FileManager.default.removeItem(at: storeRoot) }
    dest.selectedFolderURL = nil  // simulate no destination

    manager.startImport()
    #expect(!manager.isImporting)
    #expect(manager.importStage == nil)
  }

  @Test func startImportWhenStoreNotReadyIsNoOp() throws {
    let (manager, _, dest, store, storeRoot) = makeTestHarness()
    defer { try? FileManager.default.removeItem(at: storeRoot); dest.cleanup() }
    store.configure(for: nil)  // → state == .unconfigured
    #expect(store.state == .unconfigured)

    manager.startImport()
    #expect(!manager.isImporting)
    #expect(manager.importStage == nil)
  }

  // MARK: - startImport happy paths

  /// An empty backup folder produces an `ImportReport` with all zeros and the
  /// `.done` stage. Importantly, the early return after the empty-scan guard
  /// must still flip `isImporting` back to false.
  @Test func startImportWithEmptyBackupFolderProducesEmptyReport() async throws {
    let (manager, _, dest, _, storeRoot) = makeTestHarness()
    defer { try? FileManager.default.removeItem(at: storeRoot); dest.cleanup() }

    manager.startImport()
    await manager.waitForImportCompletion()

    #expect(!manager.isImporting)
    #expect(manager.importStage == .done)
    #expect(
      manager.importResult
        == ImportReport(
          matchedCount: 0, ambiguousCount: 0, unmatchedCount: 0, totalScanned: 0))
  }

  /// A backup with one file that matches a Photos-library asset must end with
  /// `bulkImportRecords` having landed a `.done` record for that asset.
  /// Verifies the scanner → matcher → bulk-import wiring end-to-end.
  @Test func startImportWithMatchableFilePersistsAndReports() async throws {
    let (manager, photoLib, dest, store, storeRoot) = makeTestHarness()
    defer { try? FileManager.default.removeItem(at: storeRoot); dest.cleanup() }

    // The matcher confirms candidates by comparing the asset's `creationDate`
    // against the file's `modificationDate`. Use a deterministic date in 2025-06
    // and stamp the planted file with the same instant so the match path is
    // taken.
    var components = DateComponents()
    components.year = 2025
    components.month = 6
    components.day = 15
    components.hour = 12
    let date = Calendar.current.date(from: components)!

    try plantBackupFile(
      in: dest, year: 2025, month: 6, filename: "IMG_0001.JPG",
      content: "photo bytes", modDate: date)

    let asset = TestAssetFactory.makeAsset(
      id: "matched-asset", creationDate: date, mediaType: .image)
    photoLib.assetsByYearMonth["2025-6"] = [asset]
    photoLib.resourcesByAssetId[asset.id] = [
      TestAssetFactory.makeResource(originalFilename: "IMG_0001.JPG")
    ]

    manager.startImport()
    await manager.waitForImportCompletion()

    // Outcome: import completed, and the matched record was persisted.
    #expect(!manager.isImporting)
    #expect(manager.importStage == .done)
    #expect(manager.importResult?.matchedCount == 1)
    #expect(manager.importResult?.unmatchedCount == 0)
    #expect(manager.importResult?.totalScanned == 1)

    // bulkImportRecords landed the `.original.done` record for the matched asset.
    let record = store.exportInfo(assetId: "matched-asset")
    #expect(record?.variants[.original]?.status == .done)
    #expect(record?.variants[.original]?.filename == "IMG_0001.JPG")
    #expect(record?.year == 2025)
    #expect(record?.month == 6)
  }

  /// Issue #38 round-trip: a backup written under the `.subfolder` layout (videos in
  /// `YYYY/MM/videos/`) must preserve the per-variant `subfolder` field on the
  /// rebuilt `ExportVariantRecord`. The full integration is tested here — scanner
  /// descent (covered in isolation by `BackupScannerVariantTests`) is one piece,
  /// but the load-bearing assignment lives in `ImportCoordinator.startImport`
  /// where the matched file's `subfolder` is copied onto the new variant record.
  /// A copy-paste bug substituting `file.filename` for `file.subfolder` would
  /// pass every other import test (which only plant files at the bare month
  /// path) and silently mis-locate every imported video on the next reuse-source
  /// or reconcile lookup.
  @Test func startImportPreservesSubfolderForVideoFilesInVideosSubdirectory() async throws {
    let (manager, photoLib, dest, store, storeRoot) = makeTestHarness()
    defer { try? FileManager.default.removeItem(at: storeRoot); dest.cleanup() }

    var components = DateComponents()
    components.year = 2025
    components.month = 3
    components.day = 14
    components.hour = 10
    let date = Calendar.current.date(from: components)!

    // Plant the video inside `2025/03/videos/` — the path the scanner emits
    // `subfolder = "videos"` for.
    let videosDir = try dest.urlForRelativeDirectory(
      "2025/03/videos/", createIfNeeded: true)
    let fileURL = videosDir.appendingPathComponent("IMG_VIDEO.MOV")
    try Data("video bytes".utf8).write(to: fileURL)
    try FileManager.default.setAttributes(
      [.modificationDate: date], ofItemAtPath: fileURL.path)

    let asset = TestAssetFactory.makeAsset(
      id: "video-subfolder", creationDate: date, mediaType: .video)
    photoLib.assetsByYearMonth["2025-3"] = [asset]
    photoLib.resourcesByAssetId[asset.id] = [
      TestAssetFactory.makeResource(type: .video, originalFilename: "IMG_VIDEO.MOV")
    ]

    manager.startImport()
    await manager.waitForImportCompletion()

    #expect(manager.importResult?.matchedCount == 1)
    #expect(manager.importResult?.unmatchedCount == 0)

    // Round-trip: the rebuilt record carries the subfolder the scanner observed.
    // Without this, reuse-source on the next export attempt would look at
    // `2025/03/IMG_VIDEO.MOV` (bare path) and find nothing — silently re-exporting
    // a file that is already on disk.
    let record = store.exportInfo(assetId: "video-subfolder")
    #expect(record?.variants[.original]?.status == .done)
    #expect(record?.variants[.original]?.subfolder == "videos",
      "ImportCoordinator must copy ScannedFile.subfolder onto the rebuilt variant record")
    #expect(record?.variants[.original]?.filename == "IMG_VIDEO.MOV")
  }

  /// A backup with a file that has no matching asset in the library produces
  /// `unmatchedCount: 1` and no `bulkImport` writes.
  @Test func startImportUnmatchedFilesReportedNotPersisted() async throws {
    let (manager, photoLib, dest, store, storeRoot) = makeTestHarness()
    defer { try? FileManager.default.removeItem(at: storeRoot); dest.cleanup() }

    try plantBackupFile(in: dest, year: 2025, month: 7, filename: "IMG_GHOST.JPG")
    // Library has assets for that month, but none with a fingerprint that matches
    // the planted file (different filename, no resources entry).
    photoLib.assetsByYearMonth["2025-7"] = [
      TestAssetFactory.makeAsset(id: "unrelated", creationDate: Date())
    ]
    photoLib.resourcesByAssetId["unrelated"] = [
      TestAssetFactory.makeResource(originalFilename: "Different.JPG")
    ]

    manager.startImport()
    await manager.waitForImportCompletion()

    #expect(manager.importResult?.matchedCount == 0)
    #expect(manager.importResult?.unmatchedCount == 1)
    #expect(manager.importResult?.totalScanned == 1)
    #expect(store.exportInfo(assetId: "unrelated") == nil)
  }

  // MARK: - Issue #106 — Collections/ import end-to-end

  /// End-to-end round-trip for `Collections/Albums/<Title>/<file>`. Plants a
  /// file under an album folder, configures the fake to expose that album in
  /// the collection tree and to return its asset list, runs the import, and
  /// asserts both a placement and a `.done` record land in the collection
  /// store. This pins the new ImportCoordinator wiring: collection scanner
  /// → placement matcher → matchCollectionFiles → collection bulkImport.
  @Test func startImportPersistsAlbumPlacementAndRecord() async throws {
    let (manager, photoLib, dest, _, storeRoot) = makeTestHarness()
    defer { try? FileManager.default.removeItem(at: storeRoot); dest.cleanup() }

    var components = DateComponents()
    components.year = 2025
    components.month = 6
    components.day = 15
    components.hour = 12
    let date = Calendar.current.date(from: components)!

    // Plant the album file at Collections/Albums/Trip/IMG_0001.JPG.
    let albumDir = try dest.urlForRelativeDirectory(
      "Collections/Albums/Trip/", createIfNeeded: true)
    let fileURL = albumDir.appendingPathComponent("IMG_0001.JPG")
    try Data("photo bytes".utf8).write(to: fileURL)
    try FileManager.default.setAttributes(
      [.modificationDate: date], ofItemAtPath: fileURL.path)

    // PhotoKit tree: one user album titled "Trip" with one asset.
    let asset = TestAssetFactory.makeAsset(
      id: "trip-asset", creationDate: date, mediaType: .image)
    let trip = PhotoCollectionDescriptor(
      id: "album:trip-id", localIdentifier: "trip-id", title: "Trip",
      kind: .album, pathComponents: [], children: [])
    photoLib.collectionTree = [trip]
    photoLib.assetsByAlbumLocalId["trip-id"] = [asset]
    photoLib.resourcesByAssetId[asset.id] = [
      TestAssetFactory.makeResource(originalFilename: "IMG_0001.JPG")
    ]

    manager.startImport()
    await manager.waitForImportCompletion()

    #expect(!manager.isImporting)
    #expect(manager.importStage == .done)
    #expect(manager.importResult?.matchedCount == 1)
    #expect(manager.importResult?.collectionMatchedCount == 1)
    #expect(manager.importResult?.unmatchedCount == 0)
    #expect(manager.importResult?.orphanCollectionFolders == 0)

    // Placement persisted in the collection store.
    let placement = manager.collectionExportRecordStore.placements.values.first {
      $0.kind == .album && $0.collectionLocalIdentifier == "trip-id"
    }
    #expect(placement != nil)
    #expect(placement?.relativePath == "Collections/Albums/Trip/")

    // Record body persisted under (placementId, assetId).
    let body = manager.collectionExportRecordStore.recordBodies[
      placement?.id ?? ""]?["trip-asset"]
    #expect(body?.variants[ExportVariant.original.rawValue]?.status == .done)
    #expect(body?.variants[ExportVariant.original.rawValue]?.filename == "IMG_0001.JPG")
  }

  /// Orphan-folder counter for the result sheet: a `Collections/Albums/`
  /// leaf with no PhotoKit match contributes its files to `unmatchedCount`
  /// and increments `orphanCollectionFolders`. The italic disclosure in
  /// `ImportView` reads from that field.
  @Test func startImportOrphanFolderIncrementsCounter() async throws {
    let (manager, photoLib, dest, _, storeRoot) = makeTestHarness()
    defer { try? FileManager.default.removeItem(at: storeRoot); dest.cleanup() }

    // Plant two files under an album that does NOT exist in PhotoKit.
    let dir = try dest.urlForRelativeDirectory(
      "Collections/Albums/DeletedAlbum/", createIfNeeded: true)
    try Data("a".utf8).write(to: dir.appendingPathComponent("A.JPG"))
    try Data("b".utf8).write(to: dir.appendingPathComponent("B.JPG"))

    // PhotoKit returns an empty collection tree.
    photoLib.collectionTree = []

    manager.startImport()
    await manager.waitForImportCompletion()

    #expect(manager.importResult?.matchedCount == 0)
    #expect(manager.importResult?.collectionMatchedCount == 0)
    #expect(manager.importResult?.unmatchedCount == 2)
    #expect(manager.importResult?.orphanCollectionFolders == 1)
  }

  /// Coordinator-level disjoint-key-space invariant. The plan's Phase F
  /// calls this out: the timeline store's `bulkImportRecords` has no kind
  /// gate (because `ExportRecord` carries no kind field), so the disjoint
  /// invariant on the import path lives in `ImportCoordinator`'s
  /// input-splitting code. This test plants both a timeline file and an
  /// album file with PhotoKit setup for each, runs import, and asserts
  /// that timeline records ONLY land in the timeline store and album
  /// records ONLY land in the collection store.
  @Test func startImportRoutesTimelineAndCollectionRecordsToCorrectStores() async throws {
    let (manager, photoLib, dest, timelineStore, storeRoot) = makeTestHarness()
    defer { try? FileManager.default.removeItem(at: storeRoot); dest.cleanup() }

    var components = DateComponents()
    components.year = 2025
    components.month = 6
    components.day = 15
    components.hour = 12
    let date = Calendar.current.date(from: components)!

    // Plant a timeline file and an album file.
    try plantBackupFile(
      in: dest, year: 2025, month: 6, filename: "TIMELINE.JPG",
      content: "x", modDate: date)
    let albumDir = try dest.urlForRelativeDirectory(
      "Collections/Albums/Trip/", createIfNeeded: true)
    let albumFile = albumDir.appendingPathComponent("ALBUM.JPG")
    try Data("y".utf8).write(to: albumFile)
    try FileManager.default.setAttributes(
      [.modificationDate: date], ofItemAtPath: albumFile.path)

    // PhotoKit: one timeline asset, one album asset (distinct identifiers).
    let timelineAsset = TestAssetFactory.makeAsset(
      id: "tl-asset", creationDate: date, mediaType: .image)
    let albumAsset = TestAssetFactory.makeAsset(
      id: "album-asset", creationDate: date, mediaType: .image)
    photoLib.assetsByYearMonth["2025-6"] = [timelineAsset]
    photoLib.resourcesByAssetId[timelineAsset.id] = [
      TestAssetFactory.makeResource(originalFilename: "TIMELINE.JPG")
    ]
    let trip = PhotoCollectionDescriptor(
      id: "album:trip-id", localIdentifier: "trip-id", title: "Trip",
      kind: .album, pathComponents: [], children: [])
    photoLib.collectionTree = [trip]
    photoLib.assetsByAlbumLocalId["trip-id"] = [albumAsset]
    photoLib.resourcesByAssetId[albumAsset.id] = [
      TestAssetFactory.makeResource(originalFilename: "ALBUM.JPG")
    ]

    manager.startImport()
    await manager.waitForImportCompletion()

    #expect(manager.importResult?.matchedCount == 2)
    #expect(manager.importResult?.collectionMatchedCount == 1)

    // Timeline store has the timeline asset, NOT the album asset.
    #expect(timelineStore.exportInfo(assetId: "tl-asset")?.variants[.original]?.status == .done)
    #expect(timelineStore.exportInfo(assetId: "album-asset") == nil)

    // Collection store has the album asset under the Trip placement, NOT the
    // timeline asset.
    let tripPlacement = manager.collectionExportRecordStore.placements.values.first {
      $0.kind == .album && $0.collectionLocalIdentifier == "trip-id"
    }
    #expect(tripPlacement != nil)
    let albumBody = manager.collectionExportRecordStore.recordBodies[
      tripPlacement?.id ?? ""]?["album-asset"]
    #expect(albumBody?.variants[ExportVariant.original.rawValue]?.status == .done)
    // Timeline asset must NOT have leaked into any collection placement.
    for byAsset in manager.collectionExportRecordStore.recordBodies.values {
      #expect(byAsset["tl-asset"] == nil)
    }
  }

  /// Collection store in `.failed` state — the symmetric gate in
  /// `ImportCoordinator.startImport` refuses the whole import and both
  /// stores stay untouched. Plan §7 + HIG: be honest about errors.
  @Test func startImportRefusedWhenCollectionStoreFailed() async throws {
    let (manager, photoLib, dest, store, storeRoot) = makeTestHarness()
    defer { try? FileManager.default.removeItem(at: storeRoot); dest.cleanup() }

    // Plant a corrupt collection-store snapshot so the next configure() forces .failed.
    let collectionDestDir = manager.collectionExportRecordStore.storeRootURL
      .appendingPathComponent("forced-failed", isDirectory: true)
    try FileManager.default.createDirectory(
      at: collectionDestDir, withIntermediateDirectories: true)
    try Data("{not valid".utf8).write(
      to: collectionDestDir.appendingPathComponent("collection-records.json"))
    manager.collectionExportRecordStore.configure(for: "forced-failed")
    #expect(manager.collectionExportRecordStore.state == .failed)

    // Plant a timeline file that would normally be matched.
    let date = Calendar.current.date(from: DateComponents(year: 2025, month: 6, day: 15))!
    try plantBackupFile(
      in: dest, year: 2025, month: 6, filename: "IMG.JPG", modDate: date)
    photoLib.assetsByYearMonth["2025-6"] = [
      TestAssetFactory.makeAsset(id: "x", creationDate: date)
    ]
    photoLib.resourcesByAssetId["x"] = [
      TestAssetFactory.makeResource(originalFilename: "IMG.JPG")
    ]

    manager.startImport()
    // Import was refused synchronously — no task to await.
    #expect(!manager.isImporting)
    #expect(manager.importStage == nil)
    #expect(manager.importResult == nil)
    // Neither store mutated.
    #expect(store.exportInfo(assetId: "x") == nil)
  }
}
