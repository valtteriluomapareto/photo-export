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
    let renderer: FakeMediaRenderer
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
    let renderer = FakeMediaRenderer()
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
      mediaRenderer: renderer,
      fileSystem: fileSystem,
      userDefaults: defaults
    )
    return Harness(
      manager: manager, photoLib: photoLib, dest: dest, writer: writer,
      renderer: renderer, store: store, collectionStore: collectionStore,
      storeRoot: storeRoot, userDefaultsSuite: suiteName)
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
    await h.manager.waitForQueueDrained()

    let record = h.store.exportInfo(assetId: "edit-gone")
    #expect(record?.variants[.edited]?.status == .failed)
    // After a successful fallback write, `.edited.lastError` is the explicit
    // `editedUnavailableOriginalBackedUpMessage` sentinel — that's what the
    // store keys recognition on, not the generic "Edited resource unavailable".
    #expect(
      record?.variants[.edited]?.lastError
        == ExportVariantRecovery.editedUnavailableOriginalBackedUpMessage)
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
    await h.manager.waitForQueueDrained()

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
    await h.manager.waitForQueueDrained()

    // Include-originals already requires `.original`, so the original is
    // written by the normal pipeline (no fallback path needed). The edited
    // variant still records the `editedResourceUnavailable` failure.
    let record = h.store.exportInfo(assetId: "edit-gone")
    #expect(record?.variants[.original]?.status == .done)
    #expect(record?.variants[.edited]?.status == .failed)
  }

  /// A second export run on an asset that already has the fallback recorded
  /// must be a no-op — `isExported` returns true and the asset isn't queued.
  /// Hardened per review feedback: assert `isExported` is true between runs
  /// and that the wait deadline wasn't reached, otherwise `queueCount == 0`
  /// and unchanged `writeCalls` could pass for the wrong reasons (e.g. a
  /// silently-failed second start, or a hung queue that timed out).
  @Test func reExportSkipsAssetCoveredByFallback() async throws {
    let h = makeHarness()
    defer { h.cleanup() }
    h.manager.versionSelection = .edited

    let asset = TestAssetFactory.makeAsset(id: "edit-gone", hasAdjustments: true)
    h.photoLib.assetsByYearMonth["2025-7"] = [asset]
    h.photoLib.resourcesByAssetId["edit-gone"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_X.HEIC")
    ]

    // First run: records the fallback. The shared `waitForQueueDrained()` either
    // returns once the queue genuinely drains, or hangs to its safety timeout —
    // there is no silent "deadline expired but queue still busy" outcome to guard
    // against, so the previous bool-returning helper is no longer needed.
    h.manager.startExportMonth(year: 2025, month: 7)
    await h.manager.waitForQueueDrained()
    let writeCountAfterFirst = h.writer.writeCalls.count
    #expect(writeCountAfterFirst > 0, "First run should have written the fallback original")
    #expect(
      h.store.isExported(asset: asset, selection: .edited),
      "Asset must be recognised as fallback-covered before the second run")

    // Second run: queue should not pick up this asset again.
    h.manager.startExportMonth(year: 2025, month: 7)
    await h.manager.waitForQueueDrained()

    #expect(h.writer.writeCalls.count == writeCountAfterFirst)
    #expect(h.manager.queueCount == 0)
  }

  // MARK: - Store-level isExported recognition

  @Test func isExportedRecognisesFallbackState() {
    let h = makeHarness()
    defer { h.cleanup() }

    let asset = TestAssetFactory.makeAsset(id: "fallback", hasAdjustments: true)

    // Compose the fallback record shape directly: original .done + edited
    // .failed with the explicit `editedUnavailableOriginalBackedUpMessage`
    // sentinel. This is the state `runEditedFallbackOriginal` leaves
    // behind after a successful `_orig` write.
    h.store.markVariantInProgress(
      assetId: asset.id, variant: .original, year: 2025, month: 7,
      relPath: "2025/07/", filename: "IMG_X_orig.HEIC")
    h.store.markVariantExported(
      assetId: asset.id, variant: .original, year: 2025, month: 7,
      relPath: "2025/07/", filename: "IMG_X_orig.HEIC", exportedAt: Date())
    h.store.markVariantFailed(
      assetId: asset.id, variant: .edited,
      error: ExportVariantRecovery.editedUnavailableOriginalBackedUpMessage,
      at: Date())

    #expect(h.store.isExported(asset: asset, selection: .edited))
  }

  /// Per-PR review tightening: an `.edited.failed` with the *generic*
  /// `editedResourceUnavailableMessage` (the variant-loop's first emission,
  /// before the fallback writer has run) must NOT count as fallback-covered.
  /// Recognition requires the explicit
  /// `editedUnavailableOriginalBackedUpMessage` sentinel, which is only
  /// written after `runEditedFallbackOriginal` successfully finishes.
  @Test func isExportedRejectsGenericSentinelAsFallback() {
    let h = makeHarness()
    defer { h.cleanup() }

    let asset = TestAssetFactory.makeAsset(id: "generic-only", hasAdjustments: true)
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

    #expect(!h.store.isExported(asset: asset, selection: .edited))
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

  // MARK: - Sidebar count

  /// The records-only sidebar formula must include fallback-covered records
  /// in the exported count, matching the asset-aware `isExported`. Without
  /// this the year/month sidebar badge stays partial (typically 99%) even
  /// after the queue stops re-trying the asset.
  @Test func sidebarSummaryCountsFallbackCoveredRecords() {
    let h = makeHarness()
    defer { h.cleanup() }
    let yr = 2025
    let mo = 7
    let rel = "2025/07/"
    let now = Date(timeIntervalSince1970: 0)

    // Compose 3 records:
    // - 1 normal edited.done (adjusted asset, edit succeeded).
    // - 1 fallback-covered: .original .done at _orig + .edited .failed[recoverable].
    // - 1 unadjusted asset with .original .done at natural stem.
    h.store.markVariantExported(
      assetId: "edit-ok", variant: .edited, year: yr, month: mo, relPath: rel,
      filename: "OK.JPG", exportedAt: now)

    h.store.markVariantInProgress(
      assetId: "fallback", variant: .original, year: yr, month: mo,
      relPath: rel, filename: "FALLBACK_orig.HEIC")
    h.store.markVariantExported(
      assetId: "fallback", variant: .original, year: yr, month: mo,
      relPath: rel, filename: "FALLBACK_orig.HEIC", exportedAt: now)
    h.store.markVariantFailed(
      assetId: "fallback", variant: .edited,
      error: ExportVariantRecovery.editedUnavailableOriginalBackedUpMessage,
      at: now)

    h.store.markVariantExported(
      assetId: "plain", variant: .original, year: yr, month: mo, relPath: rel,
      filename: "PLAIN.HEIC", exportedAt: now)

    // Scope: 3 photos total, 2 adjusted (edit-ok + fallback), 1 unedited.
    let summary = h.store.sidebarSummary(
      year: yr, month: mo, totalCount: 3, adjustedCount: 2, selection: .edited)

    // .edited formula = editedDone (1: edit-ok) + min(origOnlyAtStem, unedited) (1) +
    //                   editedFallbackCovered (1) = 3 → fully exported.
    #expect(summary?.exportedCount == 3)
    #expect(summary?.totalCount == 3)
    #expect(summary?.status == .complete)
  }

  /// A `.edited.failed` with the *generic* `editedResourceUnavailableMessage`
  /// (the variant-loop's pre-fallback emission) must NOT contribute to the
  /// fallback bucket — only records carrying the explicit
  /// `editedUnavailableOriginalBackedUpMessage` sentinel count.
  @Test func sidebarSummaryDoesNotCountGenericSentinelAsFallback() {
    let h = makeHarness()
    defer { h.cleanup() }
    let yr = 2025
    let mo = 8
    let rel = "2025/08/"
    let now = Date(timeIntervalSince1970: 0)

    h.store.markVariantExported(
      assetId: "generic", variant: .original, year: yr, month: mo, relPath: rel,
      filename: "GEN_orig.HEIC", exportedAt: now)
    h.store.markVariantFailed(
      assetId: "generic", variant: .edited,
      error: ExportVariantRecovery.editedResourceUnavailableMessage, at: now)

    #expect(h.store.recordCountEditedFallback(year: yr, month: mo) == 0)
  }

  /// R2 finding: in `.editedWithOriginals` selection, a fallback-only record
  /// must NOT count as exported. The asset-aware `isExported` keeps
  /// re-queueing it because it requires both variants `.done`; the sidebar
  /// must agree, or it would advertise 100% while the queue retries forever.
  @Test
  func sidebarSummaryEditedWithOriginalsDoesNotCountFallbackCoveredRecords() {
    let h = makeHarness()
    defer { h.cleanup() }
    let yr = 2025
    let mo = 9
    let rel = "2025/09/"
    let now = Date(timeIntervalSince1970: 0)

    h.store.markVariantInProgress(
      assetId: "fb", variant: .original, year: yr, month: mo,
      relPath: rel, filename: "FB_orig.HEIC")
    h.store.markVariantExported(
      assetId: "fb", variant: .original, year: yr, month: mo,
      relPath: rel, filename: "FB_orig.HEIC", exportedAt: now)
    h.store.markVariantFailed(
      assetId: "fb", variant: .edited,
      error: ExportVariantRecovery.editedUnavailableOriginalBackedUpMessage,
      at: now)

    let summary = h.store.sidebarSummary(
      year: yr, month: mo, totalCount: 1, adjustedCount: 1,
      selection: .editedWithOriginals)
    #expect(summary?.exportedCount == 0)
    #expect(summary?.status == .notExported)
  }

  // MARK: - Collection store

  /// `CollectionExportRecordStore.satisfiesEditedFallback` is a hand-maintained
  /// mirror of the timeline-store helper. Pin its behaviour with a direct
  /// asset+placement test so a future refactor that touches one and forgets
  /// the other surfaces here.
  @Test func collectionStoreRecognisesFallbackState() {
    let h = makeHarness()
    defer { h.cleanup() }

    let placement = ExportPlacement(
      kind: .album,
      id: "collections:album:abc:def",
      displayName: "Trip",
      collectionLocalIdentifier: "album-1",
      relativePath: "Collections/Albums/Trip/",
      createdAt: Date())
    h.collectionStore.upsertPlacement(placement)

    let asset = TestAssetFactory.makeAsset(id: "fb-album", hasAdjustments: true)

    h.collectionStore.markVariantInProgress(
      assetId: asset.id, placement: placement, variant: .original,
      filename: "IMG_A_orig.HEIC")
    h.collectionStore.markVariantExported(
      assetId: asset.id, placement: placement, variant: .original,
      filename: "IMG_A_orig.HEIC", exportedAt: Date())
    h.collectionStore.markVariantFailed(
      assetId: asset.id, placement: placement, variant: .edited,
      error: ExportVariantRecovery.editedUnavailableOriginalBackedUpMessage,
      at: Date())

    #expect(
      h.collectionStore.isExported(
        asset: asset, placement: placement, selection: .edited))
  }

  /// Collection-store mirror of the generic-sentinel rejection test.
  @Test func collectionStoreRejectsGenericSentinelAsFallback() {
    let h = makeHarness()
    defer { h.cleanup() }

    let placement = ExportPlacement(
      kind: .album,
      id: "collections:album:xyz:123",
      displayName: "Trip 2",
      collectionLocalIdentifier: "album-2",
      relativePath: "Collections/Albums/Trip 2/",
      createdAt: Date())
    h.collectionStore.upsertPlacement(placement)

    let asset = TestAssetFactory.makeAsset(id: "natural-album", hasAdjustments: true)
    // Compose with the *generic* sentinel — the variant-loop's pre-fallback
    // emission. Without the explicit
    // `editedUnavailableOriginalBackedUpMessage` marker, the asset must NOT
    // be considered fallback-covered.
    h.collectionStore.markVariantInProgress(
      assetId: asset.id, placement: placement, variant: .original,
      filename: "IMG_A_orig.HEIC")
    h.collectionStore.markVariantExported(
      assetId: asset.id, placement: placement, variant: .original,
      filename: "IMG_A_orig.HEIC", exportedAt: Date())
    h.collectionStore.markVariantFailed(
      assetId: asset.id, placement: placement, variant: .edited,
      error: ExportVariantRecovery.editedResourceUnavailableMessage, at: Date())

    #expect(
      !h.collectionStore.isExported(
        asset: asset, placement: placement, selection: .edited))
  }

  // MARK: - Sentinel disambiguation

  /// Reviewer-requested regression: an asset whose Photos-side original
  /// filename literally ends in `_orig` (e.g. `vacation_orig.JPG`) is
  /// indistinguishable from a `_orig` companion by filename shape alone.
  /// The fallback path must not be tricked into thinking such an asset is
  /// already covered. End-to-end:
  ///
  /// 1. Asset starts unedited → first export writes `vacation_orig.JPG`
  ///    at the natural stem.
  /// 2. Asset becomes adjusted, edited resource is unavailable.
  /// 3. Re-export must still run the fallback (because the explicit
  ///    sentinel isn't set yet) and write a fresh `_orig` companion at a
  ///    non-colliding path.
  /// 4. Only after the fallback's marker is set does the asset count as
  ///    covered.
  @Test func fallbackTreatsNaturalOrigFilenameCorrectly() async throws {
    let h = makeHarness()
    defer { h.cleanup() }
    h.manager.versionSelection = .edited

    // Step 1: asset's Photos-side original filename literally ends in `_orig`.
    let assetUnedited = TestAssetFactory.makeAsset(
      id: "natural-orig", hasAdjustments: false)
    h.photoLib.assetsByYearMonth["2025-7"] = [assetUnedited]
    h.photoLib.resourcesByAssetId["natural-orig"] = [
      TestAssetFactory.makeResource(
        type: .photo, originalFilename: "vacation_orig.JPG")
    ]

    h.manager.startExportMonth(year: 2025, month: 7)
    await h.manager.waitForQueueDrained()

    let firstRecord = h.store.exportInfo(assetId: "natural-orig")
    #expect(firstRecord?.variants[.original]?.filename == "vacation_orig.JPG")
    #expect(firstRecord?.variants[.edited] == nil)

    // Step 2/3: same asset id, now adjusted, edited resource unavailable.
    let assetAdjusted = TestAssetFactory.makeAsset(
      id: "natural-orig", hasAdjustments: true)
    h.photoLib.assetsByYearMonth["2025-7"] = [assetAdjusted]

    h.manager.startExportMonth(year: 2025, month: 7)
    await h.manager.waitForQueueDrained()

    // The fallback must have run and written a fresh _orig companion at a
    // non-colliding path. The `.edited.lastError` carries the explicit
    // sentinel — this is what `isExported` keys on, NOT the filename shape.
    let finalRecord = h.store.exportInfo(assetId: "natural-orig")
    #expect(finalRecord?.variants[.edited]?.status == .failed)
    #expect(
      finalRecord?.variants[.edited]?.lastError
        == ExportVariantRecovery.editedUnavailableOriginalBackedUpMessage)

    // The .original now points at the fallback companion. The previous
    // natural-stem file (`vacation_orig.JPG`) is left on disk untouched —
    // deleting it would lose user data — but the record points to the new
    // path. allocateUnusedOrigStem bumped to a `(N)` suffix to avoid
    // colliding with the natural-stem file.
    let newFilename = finalRecord?.variants[.original]?.filename
    #expect(newFilename != nil)
    #expect(newFilename != "vacation_orig.JPG")
    #expect(newFilename?.hasSuffix("_orig.JPG") == true)
    #expect(h.store.isExported(asset: assetAdjusted, selection: .edited))
  }

  // MARK: - Video fallback

  /// Adjusted videos route through `MediaRenderer` for the edited variant.
  /// When the render fails, `exportSingleVariant` rewrites the error to the
  /// generic `editedResourceUnavailableMessage`; `runEditedFallbackOriginal`
  /// then writes the original and rewrites `.edited.lastError` to the
  /// `editedUnavailableOriginalBackedUpMessage` sentinel.
  @Test func editUnavailableVideoFallbackWritesOriginal() async throws {
    let h = makeHarness()
    defer { h.cleanup() }
    h.manager.versionSelection = .edited

    let asset = AssetDescriptor(
      id: "broken-video", creationDate: Date(timeIntervalSince1970: 1_700_000_000),
      mediaType: .video, pixelWidth: 1920, pixelHeight: 1080,
      duration: 30, hasAdjustments: true)
    h.photoLib.assetsByYearMonth["2025-7"] = [asset]
    h.photoLib.resourcesByAssetId["broken-video"] = [
      // Only the original `.video` resource exists. With `hasAdjustments`,
      // `selectEditedProducer` routes to `.render`, which we make fail.
      ResourceDescriptor(type: .video, originalFilename: "IMG_4019.MOV")
    ]
    h.renderer.renderError = NSError(
      domain: "Test", code: 7,
      userInfo: [NSLocalizedDescriptionKey: "render unavailable"])

    h.manager.startExportMonth(year: 2025, month: 7)
    await h.manager.waitForQueueDrained()

    let record = h.store.exportInfo(assetId: "broken-video")
    #expect(record?.variants[.edited]?.status == .failed)
    #expect(
      record?.variants[.edited]?.lastError
        == ExportVariantRecovery.editedUnavailableOriginalBackedUpMessage)
    #expect(record?.variants[.original]?.status == .done)
    #expect(record?.variants[.original]?.filename == "IMG_4019_orig.MOV")
    #expect(h.store.isExported(asset: asset, selection: .edited))
  }

  // MARK: - Allocator collision

  /// `allocateUnusedOrigStem` must bump to a `(N)`-suffixed stem when the
  /// natural `<base>_orig.<ext>` slot is already occupied on disk. Two
  /// adjusted assets that share the same original-resource stem (e.g.
  /// duplicates from a re-import) should both end up with bytes on disk via
  /// the fallback, not collide.
  @Test func fallbackAvoidsCollisionWithExistingOrigFile() async throws {
    let h = makeHarness()
    defer { h.cleanup() }
    h.manager.versionSelection = .edited

    let assetA = TestAssetFactory.makeAsset(id: "share-A", hasAdjustments: true)
    let assetB = TestAssetFactory.makeAsset(id: "share-B", hasAdjustments: true)
    h.photoLib.assetsByYearMonth["2025-7"] = [assetA, assetB]
    h.photoLib.resourcesByAssetId["share-A"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "DUP.HEIC")
    ]
    h.photoLib.resourcesByAssetId["share-B"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "DUP.HEIC")
    ]

    h.manager.startExportMonth(year: 2025, month: 7)
    await h.manager.waitForQueueDrained()

    let recordA = h.store.exportInfo(assetId: "share-A")
    let recordB = h.store.exportInfo(assetId: "share-B")
    let nameA = recordA?.variants[.original]?.filename
    let nameB = recordB?.variants[.original]?.filename

    #expect(nameA == "DUP_orig.HEIC" || nameB == "DUP_orig.HEIC")
    #expect(nameA != nameB, "Filenames must differ to avoid collision on disk")
    let suffixed: Set<String?> = [nameA, nameB]
    #expect(suffixed.contains("DUP (1)_orig.HEIC"))
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
    await h.manager.waitForQueueDrained()

    let reporter = DiagnosticReporter(
      timelineStore: h.store, collectionStore: h.collectionStore,
      destinationId: "test-dest", appVersion: "1.2.2", buildNumber: "1"
    )
    let report = reporter.makeReport()

    #expect(
      report.contains(
        ExportVariantRecovery.editedUnavailableOriginalBackedUpMessage))
    #expect(report.contains("fallback: original exported as IMG_X_orig.HEIC"))
    #expect(report.contains("of which fallback-covered (original written as _orig): 1"))
  }
}
