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
    let defaults = UserDefaults(
      suiteName: "test-ExportManagerImport-\(UUID().uuidString)")!
    let manager = ExportManager(
      photoLibraryService: photoLib,
      exportDestination: dest,
      exportRecordStore: store,
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
}
