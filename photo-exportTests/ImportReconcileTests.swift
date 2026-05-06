import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Coverage for the reconcile-against-filesystem step that Import Existing Backup
/// runs after `bulkImportRecords`. Without this step, deleting the destination
/// folder (or recreating it empty under the same name) leaves stale `.done`
/// records — the bug reported in issue #26.
///
/// Three layers of tests:
/// 1. Direct unit tests against `ExportRecordStore.reconcileAgainstFilesystem(at:)`
/// 2. Direct unit tests against `CollectionExportRecordStore.reconcileAgainstFilesystem(at:)`
/// 3. Integration tests that drive the full `startImport` flow.
///
/// `.serialized` because the integration tests poll `manager.isImporting` after
/// kicking off `startImport` — under concurrent `@MainActor` suite execution on
/// slower runners the import Task can be starved long enough that the wait
/// times out. See issue #28.
@MainActor
@Suite(.serialized)
struct ImportReconcileTests {

  // MARK: - Filesystem helpers

  /// Creates a destination root in tmp; caller must clean it up via the returned
  /// closure. Tests that pass the URL to a reconcile method need the directory to
  /// actually exist (the reachability probe in `startImport` relies on it).
  private func makeRoot() -> (root: URL, cleanup: () -> Void) {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("ReconcileRoot-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: true)
    return (url, { try? FileManager.default.removeItem(at: url) })
  }

  /// Plants a file at `root/relPath/filename` so the reconcile probe sees it.
  private func plantFile(root: URL, relPath: String, filename: String) throws {
    let dir = root.appendingPathComponent(relPath)
    try FileManager.default.createDirectory(
      at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent(filename)
    try Data("x".utf8).write(to: file)
  }

  /// Plants a directory where the reconcile probe expects a regular file. Used to
  /// verify the directory-as-file edge case.
  private func plantDirectory(root: URL, relPath: String, name: String) throws {
    let dir = root.appendingPathComponent(relPath).appendingPathComponent(name)
    try FileManager.default.createDirectory(
      at: dir, withIntermediateDirectories: true)
  }

  // MARK: - Timeline unit tests

  @Test func timelineReconcileLeavesEverythingAloneWhenAllFilesExist() async throws {
    let (root, cleanup) = makeRoot()
    defer { cleanup() }
    let storeRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("Store-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storeRoot) }
    let store = ExportRecordStore(baseDirectoryURL: storeRoot)
    store.configure(for: "test")

    try plantFile(root: root, relPath: "2025/03/", filename: "A.HEIC")
    try plantFile(root: root, relPath: "2025/03/", filename: "B.HEIC")

    store.markVariantExported(
      assetId: "asset-A", variant: .original, year: 2025, month: 3,
      relPath: "2025/03/", filename: "A.HEIC", exportedAt: Date())
    store.markVariantExported(
      assetId: "asset-B", variant: .original, year: 2025, month: 3,
      relPath: "2025/03/", filename: "B.HEIC", exportedAt: Date())

    let summary = await store.reconcileAgainstFilesystem(at: root)

    #expect(summary == .zero)
    #expect(store.recordsById.count == 2)
  }

  @Test func timelineReconcilePrunesDoneVariantWhenFileMissing() async throws {
    let (root, cleanup) = makeRoot()
    defer { cleanup() }
    let storeRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("Store-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storeRoot) }
    let store = ExportRecordStore(baseDirectoryURL: storeRoot)
    store.configure(for: "test")

    // Record claims A is at 2025/03/A.HEIC but no such file exists.
    store.markVariantExported(
      assetId: "asset-gone", variant: .original, year: 2025, month: 3,
      relPath: "2025/03/", filename: "A.HEIC", exportedAt: Date())

    let summary = await store.reconcileAgainstFilesystem(at: root)

    #expect(summary.prunedVariants == 1)
    #expect(summary.prunedRecords == 1)
    #expect(store.recordsById["asset-gone"] == nil)
  }

  @Test func timelineReconcileKeepsRecordWhenSomeVariantsRemain() async throws {
    let (root, cleanup) = makeRoot()
    defer { cleanup() }
    let storeRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("Store-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storeRoot) }
    let store = ExportRecordStore(baseDirectoryURL: storeRoot)
    store.configure(for: "test")

    // Edited asset with both .original and .edited done — the user manually
    // deleted the _orig companion only.
    try plantFile(root: root, relPath: "2025/03/", filename: "edit.JPG")
    store.markVariantExported(
      assetId: "asset-pair", variant: .original, year: 2025, month: 3,
      relPath: "2025/03/", filename: "orig.HEIC", exportedAt: Date())
    store.markVariantExported(
      assetId: "asset-pair", variant: .edited, year: 2025, month: 3,
      relPath: "2025/03/", filename: "edit.JPG", exportedAt: Date())

    let summary = await store.reconcileAgainstFilesystem(at: root)

    #expect(summary.prunedVariants == 1)
    #expect(summary.prunedRecords == 0)
    let surviving = store.recordsById["asset-pair"]
    #expect(surviving != nil)
    #expect(surviving?.variants[.original] == nil)
    #expect(surviving?.variants[.edited]?.status == .done)
  }

  @Test func timelineReconcileSkipsFailedAndInProgressVariants() async throws {
    let (root, cleanup) = makeRoot()
    defer { cleanup() }
    let storeRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("Store-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storeRoot) }
    let store = ExportRecordStore(baseDirectoryURL: storeRoot)
    store.configure(for: "test")

    // .failed variant — file is missing but the failure carries signal value
    // (Save Diagnostic Report surfaces it).
    store.markVariantFailed(
      assetId: "asset-failed", variant: .original,
      error: "boom", at: Date())
    // .inProgress variant.
    store.markVariantInProgress(
      assetId: "asset-inflight", variant: .original, year: 2025, month: 3,
      relPath: "2025/03/", filename: "X.HEIC")

    let summary = await store.reconcileAgainstFilesystem(at: root)

    #expect(summary == .zero)
    #expect(store.recordsById["asset-failed"]?.variants[.original]?.status == .failed)
    #expect(
      store.recordsById["asset-inflight"]?.variants[.original]?.status == .inProgress)
  }

  @Test func timelineReconcilePrunesWhenPathIsDirectory() async throws {
    let (root, cleanup) = makeRoot()
    defer { cleanup() }
    let storeRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("Store-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storeRoot) }
    let store = ExportRecordStore(baseDirectoryURL: storeRoot)
    store.configure(for: "test")

    // Plant a directory at the path where the file should be.
    try plantDirectory(root: root, relPath: "2025/03/", name: "X.HEIC")
    store.markVariantExported(
      assetId: "asset-dir", variant: .original, year: 2025, month: 3,
      relPath: "2025/03/", filename: "X.HEIC", exportedAt: Date())

    let summary = await store.reconcileAgainstFilesystem(at: root)

    #expect(summary.prunedVariants == 1)
    #expect(store.recordsById["asset-dir"] == nil)
  }

  @Test func timelineReconcileSkipsWhenStateNotReady() async throws {
    let (root, cleanup) = makeRoot()
    defer { cleanup() }
    let storeRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("Store-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storeRoot) }
    let store = ExportRecordStore(baseDirectoryURL: storeRoot)
    // Note: NOT configured. State is .unconfigured.

    let summary = await store.reconcileAgainstFilesystem(at: root)
    #expect(summary == .zero)
  }

  // MARK: - Collection unit tests

  @Test func collectionReconcilePrunesMissingDoneVariant() async throws {
    let (root, cleanup) = makeRoot()
    defer { cleanup() }
    let storeRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("CStore-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storeRoot) }
    let store = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    store.configure(for: "test")

    let placement = ExportPlacement(
      kind: .album, id: "collections:album:abc:def",
      displayName: "Italy", collectionLocalIdentifier: "album-1",
      relativePath: "Collections/Albums/Italy/", createdAt: Date())
    store.upsertPlacement(placement)
    store.markVariantExported(
      assetId: "x1", placement: placement, variant: .original,
      filename: "X.HEIC", exportedAt: Date())

    let summary = await store.reconcileAgainstFilesystem(at: root)
    #expect(summary.prunedVariants == 1)
    #expect(summary.prunedRecords == 1)
    #expect(store.recordBodies[placement.id]?["x1"] == nil)
  }

  @Test func collectionReconcileLeavesPresentFilesAlone() async throws {
    let (root, cleanup) = makeRoot()
    defer { cleanup() }
    let storeRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("CStore-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storeRoot) }
    let store = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    store.configure(for: "test")

    let placement = ExportPlacement(
      kind: .album, id: "collections:album:abc:def",
      displayName: "Italy", collectionLocalIdentifier: "album-1",
      relativePath: "Collections/Albums/Italy/", createdAt: Date())
    store.upsertPlacement(placement)
    try plantFile(root: root, relPath: placement.relativePath, filename: "X.HEIC")
    store.markVariantExported(
      assetId: "x1", placement: placement, variant: .original,
      filename: "X.HEIC", exportedAt: Date())

    let summary = await store.reconcileAgainstFilesystem(at: root)
    #expect(summary == .zero)
    #expect(store.recordBodies[placement.id]?["x1"]?.variants["original"]?.status == .done)
  }

  // Note: there is no test for the "orphan record body" branch (a record body
  // keyed by a placementId with no corresponding placement metadata). The store's
  // log-replay logic rejects orphan upsertRecord ops, and `deletePlacement`
  // wipes both the placement and its bodies — so the orphan state is
  // unreachable from any public API. The defensive prune branch in
  // `reconcileAgainstFilesystem` is a belt-and-braces guard for an invariant
  // that shouldn't break, kept because the cost is one cheap dictionary lookup
  // and the alternative is silently leaving garbage forever.

  // MARK: - Integration tests

  /// Reproduces issue #26: destination folder deleted, recreated empty, run import.
  /// Records must end up empty.
  @Test func importOnEmptyFolderWipesAllTimelineRecords() async throws {
    let h = makeImportHarness()
    defer { h.cleanup() }

    // Seed records pointing at files that don't exist.
    h.timeline.markVariantExported(
      assetId: "ghost-1", variant: .original, year: 2025, month: 3,
      relPath: "2025/03/", filename: "ghost1.HEIC", exportedAt: Date())
    h.timeline.markVariantExported(
      assetId: "ghost-2", variant: .original, year: 2025, month: 3,
      relPath: "2025/03/", filename: "ghost2.HEIC", exportedAt: Date())

    h.manager.startImport()
    await h.waitForImport()

    #expect(h.timeline.recordsById.isEmpty)
    let report = h.manager.importResult
    #expect(report?.prunedRecords == 2)
    #expect(report?.prunedVariants == 2)
    #expect(report?.totalScanned == 0)
  }

  @Test func importOnPartialFolderPrunesOnlyMissingRecords() async throws {
    let h = makeImportHarness()
    defer { h.cleanup() }

    // A is on disk, B is not. Both have records.
    try h.plant(year: 2025, month: 3, filename: "A.HEIC")
    h.timeline.markVariantExported(
      assetId: "asset-A", variant: .original, year: 2025, month: 3,
      relPath: "2025/03/", filename: "A.HEIC", exportedAt: Date())
    h.timeline.markVariantExported(
      assetId: "asset-B", variant: .original, year: 2025, month: 3,
      relPath: "2025/03/", filename: "B.HEIC", exportedAt: Date())

    h.manager.startImport()
    await h.waitForImport()

    #expect(h.timeline.recordsById["asset-A"] != nil)
    #expect(h.timeline.recordsById["asset-B"] == nil)
    let report = h.manager.importResult
    #expect(report?.prunedRecords == 1)
  }

  @Test func importBailsWhenRootUnreachable() async throws {
    let h = makeImportHarness()
    defer { h.cleanup() }

    // Seed a record.
    h.timeline.markVariantExported(
      assetId: "asset-X", variant: .original, year: 2025, month: 3,
      relPath: "2025/03/", filename: "X.HEIC", exportedAt: Date())

    // Point the destination's selected folder at a non-existent path. The
    // reachability probe in startImport must catch this and bail before reconcile.
    h.dest.selectedFolderURL = h.dest.rootURL.appendingPathComponent(
      "definitely-not-here-\(UUID().uuidString)", isDirectory: true)

    h.manager.startImport()
    await h.waitForImport()

    // Record preserved; importResult never set; isImporting=false.
    #expect(h.timeline.recordsById["asset-X"] != nil)
    #expect(h.manager.importResult == nil)
    #expect(!h.manager.isImporting)
  }

  // MARK: - Integration harness

  @MainActor
  private struct ImportHarness {
    let manager: ExportManager
    let photoLib: FakePhotoLibraryService
    let dest: FakeExportDestination
    let timeline: ExportRecordStore
    let collection: CollectionExportRecordStore
    let storeRoot: URL

    func waitForImport(timeout: TimeInterval = 5) async {
      let deadline = Date().addingTimeInterval(timeout)
      await Task.yield()
      try? await Task.sleep(nanoseconds: 20_000_000)
      while manager.isImporting && Date() < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
      }
    }

    func plant(year: Int, month: Int, filename: String) throws {
      let dir = try dest.urlForRelativeDirectory(
        "\(year)/" + String(format: "%02d", month) + "/", createIfNeeded: true)
      let file = dir.appendingPathComponent(filename)
      try Data("x".utf8).write(to: file)
    }

    /// Tear down in the right order: cancel any in-flight work, flush both
    /// stores' IO queues so no async append is still racing toward the temp
    /// dirs we're about to remove, then delete the dirs. Without this,
    /// `defer { removeItem }` can fire while `JSONLRecordFile` is still
    /// writing to the now-deleted `collection-records.jsonl` — the surfacing
    /// "file doesn't exist" log is benign for the test that just passed but
    /// the underlying race contributes to flake on slow runners.
    func cleanup() {
      manager.cancelAndClear()
      timeline.flushForTesting()
      collection.flushForTesting()
      try? FileManager.default.removeItem(at: storeRoot)
      dest.cleanup()
    }
  }

  private func makeImportHarness() -> ImportHarness {
    let photoLib = FakePhotoLibraryService()
    let dest = FakeExportDestination()
    let writer = FakeAssetResourceWriter()
    let fileSystem = FakeFileSystem()
    let storeRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("ImportRec-\(UUID().uuidString)", isDirectory: true)
    let timeline = ExportRecordStore(baseDirectoryURL: storeRoot)
    timeline.configure(for: "test")
    let collection = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    collection.configure(for: "test")
    UserDefaults.standard.removeObject(forKey: ExportManager.versionSelectionDefaultsKey)
    let manager = ExportManager(
      photoLibraryService: photoLib,
      exportDestination: dest,
      exportRecordStore: timeline,
      collectionExportRecordStore: collection,
      assetResourceWriter: writer,
      fileSystem: fileSystem
    )
    return ImportHarness(
      manager: manager, photoLib: photoLib, dest: dest,
      timeline: timeline, collection: collection, storeRoot: storeRoot)
  }
}
