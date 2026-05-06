import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Coverage for the issue #22 fallback: when an adjusted asset's edited
/// variant is unavailable from PhotoKit, the pipeline writes the original
/// to a `<stem>_orig.<originalExt>` slot so the user keeps bytes for that
/// asset. The asset's `isExported` check recognises the resulting record
/// shape so the queue stops re-trying every export run.
@MainActor
struct EditedFallbackTests {

  // MARK: - Harness

  @MainActor
  private struct Harness {
    let manager: ExportManager
    let photoLib: FakePhotoLibraryService
    let dest: FakeExportDestination
    let writer: FakeAssetResourceWriter
    let store: ExportRecordStore
    let collectionStore: CollectionExportRecordStore
    let storeRoot: URL
    let userDefaultsSuite: String

    func cleanup() {
      manager.cancelAndClear()
      store.flushForTesting()
      collectionStore.flushForTesting()
      try? FileManager.default.removeItem(at: storeRoot)
      dest.cleanup()
      UserDefaults().removePersistentDomain(forName: userDefaultsSuite)
    }
  }

  private func makeHarness() -> Harness {
    let photoLib = FakePhotoLibraryService()
    let dest = FakeExportDestination()
    let writer = FakeAssetResourceWriter()
    let fileSystem = FakeFileSystem()
    let storeRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("EditedFallback-\(UUID().uuidString)", isDirectory: true)
    let store = ExportRecordStore(baseDirectoryURL: storeRoot)
    store.configure(for: "test")
    let collectionStore = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    collectionStore.configure(for: "test")
    let suiteName = "test-EditedFallback-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let manager = ExportManager(
      photoLibraryService: photoLib,
      exportDestination: dest,
      exportRecordStore: store,
      collectionExportRecordStore: collectionStore,
      assetResourceWriter: writer,
      fileSystem: fileSystem,
      userDefaults: defaults
    )
    return Harness(
      manager: manager, photoLib: photoLib, dest: dest, writer: writer,
      store: store, collectionStore: collectionStore,
      storeRoot: storeRoot, userDefaultsSuite: suiteName)
  }

  private func waitForQueueDrained(_ manager: ExportManager) async {
    let deadline = Date().addingTimeInterval(5)
    await Task.yield()
    try? await Task.sleep(nanoseconds: 30_000_000)
    while manager.hasActiveExportWork && Date() < deadline {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  // MARK: - Pipeline behaviour

  @Test func editUnavailableTriggersOrigFallback() async throws {
    let h = makeHarness()
    defer { h.cleanup() }
    h.manager.versionSelection = .edited

    let asset = TestAssetFactory.makeAsset(id: "edit-gone", hasAdjustments: true)
    h.photoLib.assetsByYearMonth["2025-7"] = [asset]
    h.photoLib.resourcesByAssetId["edit-gone"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_8000.HEIC")
    ]

    h.manager.startExportMonth(year: 2025, month: 7)
    await waitForQueueDrained(h.manager)

    let record = h.store.exportInfo(assetId: "edit-gone")
    #expect(record?.variants[.edited]?.status == .failed)
    #expect(
      record?.variants[.edited]?.lastError
        == ExportVariantRecovery.editedResourceUnavailableMessage)
    #expect(record?.variants[.original]?.status == .done)
    #expect(record?.variants[.original]?.filename == "IMG_8000_orig.HEIC")

    // The asset must now count as exported under the .edited selection so a
    // subsequent Export All doesn't re-queue it forever.
    #expect(h.store.isExported(asset: asset, selection: .edited))
  }

  @Test func unedittedAssetIsUnaffectedByFallback() async throws {
    let h = makeHarness()
    defer { h.cleanup() }
    h.manager.versionSelection = .edited

    let asset = TestAssetFactory.makeAsset(id: "unedited", hasAdjustments: false)
    h.photoLib.assetsByYearMonth["2025-7"] = [asset]
    h.photoLib.resourcesByAssetId["unedited"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_PLAIN.JPG")
    ]

    h.manager.startExportMonth(year: 2025, month: 7)
    await waitForQueueDrained(h.manager)

    // Default-mode unedited assets write the original at the natural stem
    // (no `_orig` suffix). The fallback path only triggers on adjusted
    // assets whose edited variant is unavailable, so this should match the
    // pre-fallback behaviour exactly.
    let record = h.store.exportInfo(assetId: "unedited")
    #expect(record?.variants[.original]?.status == .done)
    #expect(record?.variants[.original]?.filename == "IMG_PLAIN.JPG")
    #expect(record?.variants[.edited] == nil)
  }

  @Test func includeOriginalsModeUnaffectedByFallback() async throws {
    let h = makeHarness()
    defer { h.cleanup() }
    h.manager.versionSelection = .editedWithOriginals

    let asset = TestAssetFactory.makeAsset(id: "edit-gone", hasAdjustments: true)
    h.photoLib.assetsByYearMonth["2025-7"] = [asset]
    h.photoLib.resourcesByAssetId["edit-gone"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_X.HEIC")
    ]

    h.manager.startExportMonth(year: 2025, month: 7)
    await waitForQueueDrained(h.manager)

    // Include-originals already requires `.original`, so the original is
    // written by the normal pipeline (no fallback path needed). The edited
    // variant still records the `editedResourceUnavailable` failure.
    let record = h.store.exportInfo(assetId: "edit-gone")
    #expect(record?.variants[.original]?.status == .done)
    #expect(record?.variants[.edited]?.status == .failed)
  }

  /// A second export run on an asset that already has the fallback recorded
  /// must be a no-op — `isExported` returns true and the asset isn't queued.
  @Test func reExportSkipsAssetCoveredByFallback() async throws {
    let h = makeHarness()
    defer { h.cleanup() }
    h.manager.versionSelection = .edited

    let asset = TestAssetFactory.makeAsset(id: "edit-gone", hasAdjustments: true)
    h.photoLib.assetsByYearMonth["2025-7"] = [asset]
    h.photoLib.resourcesByAssetId["edit-gone"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_X.HEIC")
    ]

    // First run: records the fallback.
    h.manager.startExportMonth(year: 2025, month: 7)
    await waitForQueueDrained(h.manager)
    let writeCountAfterFirst = h.writer.writeCalls.count

    // Second run: queue should not pick up this asset again.
    h.manager.startExportMonth(year: 2025, month: 7)
    await waitForQueueDrained(h.manager)

    #expect(h.writer.writeCalls.count == writeCountAfterFirst)
    #expect(h.manager.queueCount == 0)
  }

  // MARK: - Store-level isExported recognition

  @Test func isExportedRecognisesFallbackState() {
    let h = makeHarness()
    defer { h.cleanup() }

    let asset = TestAssetFactory.makeAsset(id: "fallback", hasAdjustments: true)

    // Compose the fallback record shape directly: original .done at _orig,
    // edited .failed with the recoverable sentinel.
    h.store.markVariantInProgress(
      assetId: asset.id, variant: .original, year: 2025, month: 7,
      relPath: "2025/07/", filename: "IMG_X_orig.HEIC")
    h.store.markVariantExported(
      assetId: asset.id, variant: .original, year: 2025, month: 7,
      relPath: "2025/07/", filename: "IMG_X_orig.HEIC", exportedAt: Date())
    h.store.markVariantFailed(
      assetId: asset.id, variant: .edited,
      error: ExportVariantRecovery.editedResourceUnavailableMessage,
      at: Date())

    #expect(h.store.isExported(asset: asset, selection: .edited))
  }

  /// The same `.failed` `.edited` variant with a *different* error message
  /// must NOT count as exported — the fallback rule is keyed on the
  /// recoverable sentinel only, so other failures still re-queue.
  @Test func isExportedRejectsFallbackWithDifferentError() {
    let h = makeHarness()
    defer { h.cleanup() }

    let asset = TestAssetFactory.makeAsset(id: "other-fail", hasAdjustments: true)
    h.store.markVariantInProgress(
      assetId: asset.id, variant: .original, year: 2025, month: 7,
      relPath: "2025/07/", filename: "IMG_X_orig.HEIC")
    h.store.markVariantExported(
      assetId: asset.id, variant: .original, year: 2025, month: 7,
      relPath: "2025/07/", filename: "IMG_X_orig.HEIC", exportedAt: Date())
    h.store.markVariantFailed(
      assetId: asset.id, variant: .edited,
      error: "Disk full", at: Date())

    #expect(!h.store.isExported(asset: asset, selection: .edited))
  }

  // MARK: - Diagnostic report

  @Test func diagnosticReportAnnotatesFallback() async throws {
    let h = makeHarness()
    defer { h.cleanup() }
    h.manager.versionSelection = .edited

    let asset = TestAssetFactory.makeAsset(id: "edit-gone", hasAdjustments: true)
    h.photoLib.assetsByYearMonth["2025-7"] = [asset]
    h.photoLib.resourcesByAssetId["edit-gone"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_X.HEIC")
    ]

    h.manager.startExportMonth(year: 2025, month: 7)
    await waitForQueueDrained(h.manager)

    let reporter = DiagnosticReporter(
      timelineStore: h.store, collectionStore: h.collectionStore,
      destinationId: "test-dest", appVersion: "1.2.2", buildNumber: "1"
    )
    let report = reporter.makeReport()

    #expect(report.contains("Edited resource unavailable"))
    #expect(report.contains("fallback: original exported as IMG_X_orig.HEIC"))
    #expect(report.contains("of which fallback-covered (original written as _orig): 1"))
  }
}
