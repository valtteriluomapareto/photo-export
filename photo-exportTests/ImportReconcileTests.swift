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
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct ImportReconcileTests {

  // MARK: - Filesystem helpers

  /// Creates a destination root in tmp; caller must clean it up via the returned
  /// closure. Tests that pass the URL to a reconcile method need the directory to
  /// actually exist (the reachability probe in `startImport` relies on it).
  private func makeRoot() -> (root: URL, cleanup: () -> Void) {
    let url = TestScratch.directory("ReconcileRoot")
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
    let storeRoot = TestScratch.directory("Store")
    defer { try? FileManager.default.removeItem(at: storeRoot) }
    let store = ExportRecordStore(baseDirectoryURL: storeRoot)
    await store.configureAndWait(for: "test")

    try plantFile(root: root, relPath: "2025/03/", filename: "A.HEIC")
    try plantFile(root: root, relPath: "2025/03/", filename: "B.HEIC")

    store.markVariantExported(
      assetId: "asset-A", variant: .original, year: 2025, month: 3,
      relPath: "2025/03/", filename: "A.HEIC", exportedAt: Date())
    store.markVariantExported(
      assetId: "asset-B", variant: .original, year: 2025, month: 3,
      relPath: "2025/03/", filename: "B.HEIC", exportedAt: Date())

    let summary = try await store.reconcileAgainstFilesystem(at: root)

    #expect(summary == .zero)
    #expect(store.recordsById.count == 2)
  }

  @Test func timelineReconcilePrunesDoneVariantWhenFileMissing() async throws {
    let (root, cleanup) = makeRoot()
    defer { cleanup() }
    let storeRoot = TestScratch.directory("Store")
    defer { try? FileManager.default.removeItem(at: storeRoot) }
    let store = ExportRecordStore(baseDirectoryURL: storeRoot)
    await store.configureAndWait(for: "test")

    // Record claims A is at 2025/03/A.HEIC but no such file exists.
    store.markVariantExported(
      assetId: "asset-gone", variant: .original, year: 2025, month: 3,
      relPath: "2025/03/", filename: "A.HEIC", exportedAt: Date())

    let summary = try await store.reconcileAgainstFilesystem(at: root)

    #expect(summary.prunedVariants == 1)
    #expect(summary.prunedRecords == 1)
    #expect(store.recordsById["asset-gone"] == nil)
  }

  @Test func timelineReconcileKeepsRecordWhenSomeVariantsRemain() async throws {
    let (root, cleanup) = makeRoot()
    defer { cleanup() }
    let storeRoot = TestScratch.directory("Store")
    defer { try? FileManager.default.removeItem(at: storeRoot) }
    let store = ExportRecordStore(baseDirectoryURL: storeRoot)
    await store.configureAndWait(for: "test")

    // Edited asset with both .original and .edited done — the user manually
    // deleted the _orig companion only.
    try plantFile(root: root, relPath: "2025/03/", filename: "edit.JPG")
    store.markVariantExported(
      assetId: "asset-pair", variant: .original, year: 2025, month: 3,
      relPath: "2025/03/", filename: "orig.HEIC", exportedAt: Date())
    store.markVariantExported(
      assetId: "asset-pair", variant: .edited, year: 2025, month: 3,
      relPath: "2025/03/", filename: "edit.JPG", exportedAt: Date())

    let summary = try await store.reconcileAgainstFilesystem(at: root)

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
    let storeRoot = TestScratch.directory("Store")
    defer { try? FileManager.default.removeItem(at: storeRoot) }
    let store = ExportRecordStore(baseDirectoryURL: storeRoot)
    await store.configureAndWait(for: "test")

    // .failed variant — file is missing but the failure carries signal value
    // (Save Diagnostic Report surfaces it).
    store.markVariantFailed(
      assetId: "asset-failed", variant: .original,
      error: "boom", at: Date())
    // .inProgress variant.
    store.markVariantInProgress(
      assetId: "asset-inflight", variant: .original, year: 2025, month: 3,
      relPath: "2025/03/", filename: "X.HEIC")

    let summary = try await store.reconcileAgainstFilesystem(at: root)

    #expect(summary == .zero)
    #expect(store.recordsById["asset-failed"]?.variants[.original]?.status == .failed)
    #expect(
      store.recordsById["asset-inflight"]?.variants[.original]?.status == .inProgress)
  }

  @Test func timelineReconcileRejectsDirectoryWithoutPruning() async throws {
    let (root, cleanup) = makeRoot()
    defer { cleanup() }
    let storeRoot = TestScratch.directory("Store")
    defer { try? FileManager.default.removeItem(at: storeRoot) }
    let store = ExportRecordStore(baseDirectoryURL: storeRoot)
    await store.configureAndWait(for: "test")

    // Plant a directory at the path where the file should be.
    try plantDirectory(root: root, relPath: "2025/03/", name: "X.HEIC")
    store.markVariantExported(
      assetId: "asset-dir", variant: .original, year: 2025, month: 3,
      relPath: "2025/03/", filename: "X.HEIC", exportedAt: Date())

    await #expect(throws: ReconciliationVerificationError.self) {
      try await store.reconcileAgainstFilesystem(at: root)
    }
    #expect(store.recordsById["asset-dir"]?.variants[.original]?.status == .done)
  }

  @Test func timelineReconcileSkipsWhenStateNotReady() async throws {
    let (root, cleanup) = makeRoot()
    defer { cleanup() }
    let storeRoot = TestScratch.directory("Store")
    defer { try? FileManager.default.removeItem(at: storeRoot) }
    let store = ExportRecordStore(baseDirectoryURL: storeRoot)
    // Note: NOT configured. State is .unconfigured.

    let summary = try await store.reconcileAgainstFilesystem(at: root)
    #expect(summary == .zero)
  }

  // MARK: - Collection unit tests

  @Test func collectionReconcilePrunesMissingDoneVariant() async throws {
    let (root, cleanup) = makeRoot()
    defer { cleanup() }
    let storeRoot = TestScratch.directory("CStore")
    defer { try? FileManager.default.removeItem(at: storeRoot) }
    let store = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    await store.configureAndWait(for: "test")

    let placement = ExportPlacement(
      kind: .album, id: "collections:album:abc:def",
      displayName: "Italy", collectionLocalIdentifier: "album-1",
      relativePath: "Collections/Albums/Italy/", createdAt: Date())
    store.upsertPlacement(placement)
    store.markVariantExported(
      assetId: "x1", placement: placement, variant: .original,
      filename: "X.HEIC", exportedAt: Date())

    let summary = try await store.reconcileAgainstFilesystem(at: root)
    #expect(summary.prunedVariants == 1)
    #expect(summary.prunedRecords == 1)
    #expect(store.recordBodies[placement.id]?["x1"] == nil)
  }

  @Test func collectionReconcileLeavesPresentFilesAlone() async throws {
    let (root, cleanup) = makeRoot()
    defer { cleanup() }
    let storeRoot = TestScratch.directory("CStore")
    defer { try? FileManager.default.removeItem(at: storeRoot) }
    let store = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    await store.configureAndWait(for: "test")

    let placement = ExportPlacement(
      kind: .album, id: "collections:album:abc:def",
      displayName: "Italy", collectionLocalIdentifier: "album-1",
      relativePath: "Collections/Albums/Italy/", createdAt: Date())
    store.upsertPlacement(placement)
    try plantFile(root: root, relPath: placement.relativePath, filename: "X.HEIC")
    store.markVariantExported(
      assetId: "x1", placement: placement, variant: .original,
      filename: "X.HEIC", exportedAt: Date())

    let summary = try await store.reconcileAgainstFilesystem(at: root)
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
    let h = await makeImportHarness()
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
    let h = await makeImportHarness()
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
    let h = await makeImportHarness()
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

  @Test(arguments: [false, true], [false, true])
  func adjacentMonthImportRetainsPhysicalPlacement(reverse: Bool, video: Bool) async throws {
    let h = await makeImportHarness()
    defer { h.cleanup() }
    let assetYear = reverse ? 2026 : 2025
    let assetMonth = reverse ? 1 : 12
    let fileYear = reverse ? 2025 : 2026
    let fileMonth = reverse ? 12 : 1
    let date = try #require(
      Calendar.current.date(
        from: DateComponents(
          year: assetYear, month: assetMonth, day: reverse ? 1 : 31,
          hour: reverse ? 0 : 23, minute: 30)))
    let filename = video ? "BOUNDARY.MOV" : "BOUNDARY.JPG"
    let relativePath = "\(fileYear)/" + String(format: "%02d", fileMonth) + "/"
    let directory = try h.dest.urlForRelativeDirectory(
      relativePath + (video ? "videos/" : ""), createIfNeeded: true)
    let file = directory.appendingPathComponent(filename)
    let bytes = Data("existing boundary backup".utf8)
    try bytes.write(to: file)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
    let asset = TestAssetFactory.makeAsset(
      id: "boundary", creationDate: date, mediaType: video ? .video : .image)
    h.photoLib.assetsByYearMonth["\(assetYear)-\(assetMonth)"] = [asset]
    h.photoLib.resourcesByAssetId[asset.id] = [
      TestAssetFactory.makeResource(
        type: video ? .video : .photo, originalFilename: filename)
    ]

    h.manager.startImport()
    await h.waitForImport()

    #expect(h.manager.importResult?.matchedCount == 1)
    #expect(h.manager.importResult?.prunedVariants == 0)
    let record = h.timeline.exportInfo(assetId: asset.id)
    #expect(record?.year == fileYear)
    #expect(record?.month == fileMonth)
    #expect(record?.relPath == relativePath)
    #expect(record?.variants[.original]?.status == .done)
    #expect(record?.variants[.original]?.subfolder == (video ? "videos" : nil))
    h.timeline.drainSynchronously()
    let reopened = ExportRecordStore(baseDirectoryURL: h.storeRoot)
    await reopened.configureAndWait(for: "test")
    #expect(reopened.exportInfo(assetId: asset.id)?.variants[.original]?.status == .done)
    #expect(reopened.exportInfo(assetId: asset.id)?.relPath == relativePath)
    let jobs = ExportJobPlanner.plan(
      assets: [asset], placement: .timeline(year: assetYear, month: assetMonth),
      settings: .init(selection: .edited),
      isExported: { reopened.isExported(asset: $0, selection: .edited, livePhotosPaired: false) },
      shouldSkipForRetry: { _, _, _ in false })
    #expect(jobs.isEmpty)

    h.manager.startExportMonth(year: assetYear, month: assetMonth)
    await h.manager.waitForQueueDrained()
    #expect(h.writer.writeCalls.isEmpty)
    #expect(try Data(contentsOf: file) == bytes)
    #expect(
      !FileManager.default.fileExists(
        atPath: h.dest.rootURL
          .appendingPathComponent("\(assetYear)/" + String(format: "%02d", assetMonth)).path))
    reopened.drainSynchronously()
  }

  @Test(arguments: ExportVariant.allCases, [false, true])
  func importCannotRelocateAnyCompletedVariant(done: ExportVariant, changeYear: Bool) async throws {
    let h = await makeImportHarness()
    defer { h.cleanup() }
    h.timeline.markVariantExported(
      assetId: "existing", variant: done, year: 2025, month: 12,
      relPath: "2025/12/", filename: "KEPT.JPG", exportedAt: Date(timeIntervalSince1970: 100),
      subfolder: "videos")
    let before = try #require(h.timeline.exportInfo(assetId: "existing"))
    let countBefore = h.timeline.monthSummary(year: 2025, month: 12, totalAssets: 1)
    let incomingVariant: ExportVariant = done == .edited ? .original : .edited
    h.timeline.bulkImportRecords([
      ExportRecord(
        id: "existing", year: changeYear ? 2026 : 2025, month: changeYear ? 12 : 11,
        relPath: changeYear ? "2026/12/" : "2025/11/",
        variants: [
          incomingVariant: ExportVariantRecord(
            filename: "NEW.JPG", status: .done, exportDate: Date(), lastError: nil)
        ])
    ])
    #expect(h.timeline.exportInfo(assetId: "existing") == before)
    #expect(h.timeline.monthSummary(year: 2025, month: 12, totalAssets: 1) == countBefore)
    #expect(
      h.timeline.monthSummary(
        year: changeYear ? 2026 : 2025, month: changeYear ? 12 : 11,
        totalAssets: 1
      ).exportedCount == 0)
    h.timeline.drainSynchronously()
    let reopened = ExportRecordStore(baseDirectoryURL: h.storeRoot)
    await reopened.configureAndWait(for: "test")
    #expect(reopened.exportInfo(assetId: "existing") == before)
    reopened.drainSynchronously()
  }

  @Test func sameMonthVideoImportMergesWithoutChangingCompletedPlacement() async throws {
    let h = await makeImportHarness()
    defer { h.cleanup() }
    let videos = try h.dest.urlForRelativeDirectory("2025/12/videos/", createIfNeeded: true)
    let originalFile = videos.appendingPathComponent("ORIGINAL.MOV")
    let editedFile = videos.deletingLastPathComponent().appendingPathComponent("EDITED.MOV")
    try Data("original".utf8).write(to: originalFile)
    try Data("edited".utf8).write(to: editedFile)
    h.timeline.markVariantExported(
      assetId: "video", variant: .original, year: 2025, month: 12,
      relPath: "2025/12/videos/", filename: "ORIGINAL.MOV",
      exportedAt: Date(timeIntervalSince1970: 100), subfolder: "videos")
    let original = h.timeline.exportInfo(assetId: "video")?.variants[.original]
    h.timeline.bulkImportRecords([
      ExportRecord(
        id: "video", year: 2025, month: 12, relPath: "2025/12/",
        variants: [
          .edited: ExportVariantRecord(
            filename: "EDITED.MOV", status: .done,
            exportDate: Date(timeIntervalSince1970: 200), lastError: nil)
        ])
    ])
    let summary = try await h.timeline.reconcileAgainstFilesystem(at: h.dest.rootURL)
    #expect(summary == .zero)
    let merged = try #require(h.timeline.exportInfo(assetId: "video"))
    #expect(merged.relPath == "2025/12/videos/")
    #expect(merged.variants[.original] == original)
    #expect(merged.variants[.edited]?.status == .done)
    #expect(merged.variants[.edited]?.subfolder == nil)
    #expect(try Data(contentsOf: originalFile) == Data("original".utf8))
    #expect(try Data(contentsOf: editedFile) == Data("edited".utf8))
    h.timeline.drainSynchronously()
    let reopened = ExportRecordStore(baseDirectoryURL: h.storeRoot)
    await reopened.configureAndWait(for: "test")
    #expect(reopened.exportInfo(assetId: "video") == merged)
    reopened.drainSynchronously()
  }

  // MARK: - Integration harness

  @MainActor
  private struct ImportHarness {
    let manager: ExportManager
    let photoLib: FakePhotoLibraryService
    let writer: FakeAssetResourceWriter
    let dest: FakeExportDestination
    let timeline: ExportRecordStore
    let collection: CollectionExportRecordStore
    let storeRoot: URL

    func waitForImport() async {
      await manager.waitForImportCompletion()
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
      timeline.drainSynchronously()
      collection.drainSynchronously()
      try? FileManager.default.removeItem(at: storeRoot)
      dest.cleanup()
    }
  }

  private func makeImportHarness() async -> ImportHarness {
    let photoLib = FakePhotoLibraryService()
    let dest = FakeExportDestination()
    let writer = FakeAssetResourceWriter()
    let fileSystem = FakeFileSystem()
    let storeRoot = TestScratch.directory("ImportRec")
    let timeline = ExportRecordStore(baseDirectoryURL: storeRoot)
    await timeline.configureAndWait(for: "test")
    let collection = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    await collection.configureAndWait(for: "test")
    let defaults = TestScratch.defaults("ImportReconcile")
    let manager = ExportManager(
      photoLibraryService: photoLib,
      exportDestination: dest,
      exportRecordStore: timeline,
      collectionExportRecordStore: collection,
      assetResourceWriter: writer,
      localHEICStorage: LocalHEICStorage(root: TestScratch.directory("ExportHEIC")),
      fileSystem: fileSystem,
      userDefaults: defaults
    )
    return ImportHarness(
      manager: manager, photoLib: photoLib, writer: writer, dest: dest,
      timeline: timeline, collection: collection,
      storeRoot: storeRoot)
  }
}
