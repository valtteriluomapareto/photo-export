import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Covers the export pipeline for the redesigned two-mode selection: filename contract,
/// collision pairing, failure propagation, and selection-aware enqueue/skip behaviour.
@MainActor
struct EditedModeExportTests {
  // MARK: - Test harness

  private func makeTestHarness() -> (
    ExportManager, FakePhotoLibraryService, FakeExportDestination, FakeAssetResourceWriter,
    FakeFileSystem, ExportRecordStore
  ) {
    let photoLib = FakePhotoLibraryService()
    let dest = FakeExportDestination()
    let writer = FakeAssetResourceWriter()
    let fileSystem = FakeFileSystem()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("EditedModeTest-\(UUID().uuidString)", isDirectory: true)
    let store = ExportRecordStore(baseDirectoryURL: tempDir)
    store.configure(for: "test")

    // Per-test UserDefaults suite isolates `versionSelection` from any other
    // suite running concurrently. Replacing the pre-existing `.standard
    // .removeObject(...)` pattern that raced across `@MainActor` test suites
    // (issue #28).
    let defaults = UserDefaults(
      suiteName: "test-EditedMode-\(UUID().uuidString)")!

    let manager = ExportManager(
      photoLibraryService: photoLib,
      exportDestination: dest,
      exportRecordStore: store,
      assetResourceWriter: writer,
      fileSystem: fileSystem,
      userDefaults: defaults
    )
    return (manager, photoLib, dest, writer, fileSystem, store)
  }

  private func waitForQueueDrained(_ manager: ExportManager, timeout: TimeInterval = 5) async {
    let deadline = Date().addingTimeInterval(timeout)
    await Task.yield()
    try? await Task.sleep(nanoseconds: 50_000_000)
    while (manager.isRunning || manager.queueCount > 0 || manager.hasActiveExportWork)
      && Date() < deadline
    {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  // MARK: - Default mode: unedited asset writes original at the natural stem

  @Test func editedDefaultExportsUneditedAtOriginalFilename() async throws {
    let (manager, photoLib, dest, writer, _, store) = makeTestHarness()
    defer { dest.cleanup() }
    manager.versionSelection = .edited

    let unedited = TestAssetFactory.makeAsset(id: "plain-asset", hasAdjustments: false)
    photoLib.assetsByYearMonth["2025-3"] = [unedited]
    photoLib.resourcesByAssetId["plain-asset"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.JPG")
    ]

    manager.startExportMonth(year: 2025, month: 3)
    await waitForQueueDrained(manager)

    #expect(writer.writeCalls.count == 1)
    #expect(writer.writeCalls.first?.resource.type == .photo)
    let record = store.exportInfo(assetId: "plain-asset")
    #expect(record?.variants[.original]?.status == .done)
    #expect(record?.variants[.original]?.filename == "IMG_0001.JPG")
    #expect(record?.variants[.edited] == nil)
  }

  // MARK: - Default mode: adjusted asset writes the edit at the natural stem

  @Test func editedDefaultWritesEditAtNaturalStem() async throws {
    let (manager, photoLib, dest, writer, _, store) = makeTestHarness()
    defer { dest.cleanup() }
    manager.versionSelection = .edited

    let asset = TestAssetFactory.makeAsset(id: "edited-asset", hasAdjustments: true)
    photoLib.assetsByYearMonth["2025-4"] = [asset]
    photoLib.resourcesByAssetId["edited-asset"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.JPG"),
      TestAssetFactory.makeResource(type: .fullSizePhoto, originalFilename: "FullRender.JPG"),
    ]

    manager.startExportMonth(year: 2025, month: 4)
    await waitForQueueDrained(manager)

    #expect(writer.writeCalls.count == 1)
    #expect(writer.writeCalls.first?.resource.type == .fullSizePhoto)
    let record = store.exportInfo(assetId: "edited-asset")
    #expect(record?.variants[.edited]?.status == .done)
    #expect(record?.variants[.edited]?.filename == "IMG_0001.JPG")
    #expect(record?.variants[.original] == nil)
  }

  // MARK: - HEIC original + JPEG edit → edit lands at IMG_0001.JPG

  @Test func heicOriginalPlusJpegEditProducesJpegAtNaturalStem() async throws {
    let (manager, photoLib, dest, writer, _, store) = makeTestHarness()
    defer { dest.cleanup() }
    manager.versionSelection = .edited

    let asset = TestAssetFactory.makeAsset(id: "heic-asset", hasAdjustments: true)
    photoLib.assetsByYearMonth["2025-5"] = [asset]
    photoLib.resourcesByAssetId["heic-asset"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.HEIC"),
      TestAssetFactory.makeResource(type: .fullSizePhoto, originalFilename: "FullRender.JPG"),
    ]

    manager.startExportMonth(year: 2025, month: 5)
    await waitForQueueDrained(manager)

    #expect(writer.writeCalls.count == 1)
    let record = store.exportInfo(assetId: "heic-asset")
    #expect(record?.variants[.edited]?.filename == "IMG_0001.JPG")
  }

  // MARK: - editedWithOriginals adjusted asset writes both files paired

  @Test func editedWithOriginalsWritesPrimaryAndOrigCompanion() async throws {
    let (manager, photoLib, dest, writer, _, store) = makeTestHarness()
    defer { dest.cleanup() }
    manager.versionSelection = .editedWithOriginals

    let asset = TestAssetFactory.makeAsset(id: "dual-asset", hasAdjustments: true)
    photoLib.assetsByYearMonth["2025-6"] = [asset]
    photoLib.resourcesByAssetId["dual-asset"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.JPG"),
      TestAssetFactory.makeResource(type: .fullSizePhoto, originalFilename: "FullRender.JPG"),
    ]

    manager.startExportMonth(year: 2025, month: 6)
    await waitForQueueDrained(manager)

    #expect(writer.writeCalls.count == 2)
    let record = store.exportInfo(assetId: "dual-asset")
    #expect(record?.variants[.original]?.status == .done)
    #expect(record?.variants[.original]?.filename == "IMG_0001_orig.JPG")
    #expect(record?.variants[.edited]?.status == .done)
    #expect(record?.variants[.edited]?.filename == "IMG_0001.JPG")
  }

  @Test func editedWithOriginalsUneditedAssetWritesOriginalOnly() async throws {
    let (manager, photoLib, dest, writer, _, store) = makeTestHarness()
    defer { dest.cleanup() }
    manager.versionSelection = .editedWithOriginals

    let unedited = TestAssetFactory.makeAsset(id: "plain", hasAdjustments: false)
    photoLib.assetsByYearMonth["2025-7"] = [unedited]
    photoLib.resourcesByAssetId["plain"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.JPG")
    ]

    manager.startExportMonth(year: 2025, month: 7)
    await waitForQueueDrained(manager)

    #expect(writer.writeCalls.count == 1)
    let record = store.exportInfo(assetId: "plain")
    #expect(record?.variants[.original]?.status == .done)
    #expect(record?.variants[.original]?.filename == "IMG_0001.JPG")
    #expect(record?.variants[.edited] == nil)
  }

  // MARK: - Default mode adjusted PHOTO with no .fullSizePhoto fails edited variant
  //
  // Boundary explicit: this asserts the photo-only branch of the
  // edited-variant contract. Adjusted videos with no `.fullSizeVideo`
  // take the render path instead — see
  // `ExportManagerVideoRenderTests.adjustedVideoWithOnlyOriginalResourceGoesThroughRenderer`.
  // Splitting the assertion along media kind prevents accidentally
  // widening the render path to images later.

  @Test func defaultModeAdjustedPhotoFailsWhenFullSizePhotoUnavailable() async throws {
    let (manager, photoLib, dest, _, _, store) = makeTestHarness()
    defer { dest.cleanup() }
    manager.versionSelection = .edited

    let asset = TestAssetFactory.makeAsset(id: "broken-edit", hasAdjustments: true)
    photoLib.assetsByYearMonth["2025-8"] = [asset]
    photoLib.resourcesByAssetId["broken-edit"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.JPG")
    ]

    manager.startExportMonth(year: 2025, month: 8)
    await waitForQueueDrained(manager)

    let record = store.exportInfo(assetId: "broken-edit")
    #expect(record?.variants[.edited]?.status == .failed)
    #expect(record?.variants[.edited]?.lastError == "Edited resource unavailable")
  }

  // MARK: - Companion follows the asset's collision-suffixed group stem

  @Test func pairedCompanionFollowsCollisionSuffix() async throws {
    let (manager, photoLib, dest, _, _, store) = makeTestHarness()
    defer { dest.cleanup() }
    manager.versionSelection = .editedWithOriginals

    let aOriginal = TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.JPG")
    let bOriginal = TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.JPG")
    let bEdited = TestAssetFactory.makeResource(
      type: .fullSizePhoto, originalFilename: "FullRender.JPG")

    let assetA = TestAssetFactory.makeAsset(id: "asset-a", hasAdjustments: false)
    let assetB = TestAssetFactory.makeAsset(id: "asset-b", hasAdjustments: true)
    photoLib.assetsByYearMonth["2025-9"] = [assetA, assetB]
    photoLib.resourcesByAssetId["asset-a"] = [aOriginal]
    photoLib.resourcesByAssetId["asset-b"] = [bOriginal, bEdited]

    manager.startExportMonth(year: 2025, month: 9)
    await waitForQueueDrained(manager)

    // Asset A goes first, gets natural-stem `IMG_0001.JPG` (unedited, no `_orig`).
    #expect(store.exportInfo(assetId: "asset-a")?.variants[.original]?.filename == "IMG_0001.JPG")

    // Asset B's pair allocates the next free stem `IMG_0001 (1)` because the natural-stem
    // edited target `IMG_0001.JPG` is taken by Asset A.
    let bRecord = store.exportInfo(assetId: "asset-b")
    #expect(bRecord?.variants[.edited]?.filename == "IMG_0001 (1).JPG")
    #expect(bRecord?.variants[.original]?.filename == "IMG_0001 (1)_orig.JPG")
  }

  // MARK: - Step-1 fail-path guard for paired `_orig` companion

  @Test func pairedCompanionFailsInsteadOfOverwritingAnotherAssetsFile() async throws {
    let (manager, photoLib, dest, _, _, store) = makeTestHarness()
    defer { dest.cleanup() }

    // Default mode for asset B first: writes the edit at the natural stem.
    manager.versionSelection = .edited
    let assetB = TestAssetFactory.makeAsset(id: "b", hasAdjustments: true)
    photoLib.assetsByYearMonth["2025-11"] = [assetB]
    photoLib.resourcesByAssetId["b"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.JPG"),
      TestAssetFactory.makeResource(type: .fullSizePhoto, originalFilename: "FullRender.JPG"),
    ]

    manager.startExportMonth(year: 2025, month: 11)
    await waitForQueueDrained(manager)
    #expect(store.exportInfo(assetId: "b")?.variants[.edited]?.filename == "IMG_0001.JPG")

    // Pre-seed `IMG_0001_orig.JPG` with another asset's bytes — asset B's later switch to
    // include-originals must fail rather than overwrite it.
    let monthDir = try dest.urlForMonth(year: 2025, month: 11, createIfNeeded: true)
    FileManager.default.createFile(
      atPath: monthDir.appendingPathComponent("IMG_0001_orig.JPG").path,
      contents: Data("other-asset".utf8))

    manager.versionSelection = .editedWithOriginals
    manager.startExportMonth(year: 2025, month: 11)
    await waitForQueueDrained(manager)

    let bRecord = store.exportInfo(assetId: "b")
    #expect(bRecord?.variants[.original]?.status == .failed)
    #expect(bRecord?.variants[.original]?.lastError?.contains("already exists") == true)
    let cData = try Data(contentsOf: monthDir.appendingPathComponent("IMG_0001_orig.JPG"))
    #expect(String(data: cData, encoding: .utf8) == "other-asset")
  }

  // MARK: - Stale .tmp cleanup

  @Test func staleTempFileIsRemovedBeforeWrite() async throws {
    let (manager, photoLib, dest, _, _, _) = makeTestHarness()
    defer { dest.cleanup() }
    manager.versionSelection = .edited

    let asset = TestAssetFactory.makeAsset(id: "stale-tmp", hasAdjustments: false)
    photoLib.assetsByYearMonth["2025-12"] = [asset]
    photoLib.resourcesByAssetId["stale-tmp"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.JPG")
    ]

    let monthDir = try dest.urlForMonth(year: 2025, month: 12, createIfNeeded: true)
    let staleTmp = monthDir.appendingPathComponent("IMG_0001.JPG.tmp")
    FileManager.default.createFile(atPath: staleTmp.path, contents: Data("leftover".utf8))
    #expect(FileManager.default.fileExists(atPath: staleTmp.path))

    manager.startExportMonth(year: 2025, month: 12)
    await waitForQueueDrained(manager)

    #expect(!FileManager.default.fileExists(atPath: staleTmp.path))
  }

  // MARK: - Switching selection enqueues only the missing variant

  @Test func switchingToIncludeOriginalsEnqueuesOnlyMissingOriginal() async throws {
    let (manager, photoLib, dest, writer, _, store) = makeTestHarness()
    defer { dest.cleanup() }

    manager.versionSelection = .edited
    let asset = TestAssetFactory.makeAsset(id: "switch-asset", hasAdjustments: true)
    photoLib.assetsByYearMonth["2025-1"] = [asset]
    photoLib.resourcesByAssetId["switch-asset"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.JPG"),
      TestAssetFactory.makeResource(type: .fullSizePhoto, originalFilename: "FullRender.JPG"),
    ]

    manager.startExportMonth(year: 2025, month: 1)
    await waitForQueueDrained(manager)
    #expect(writer.writeCalls.count == 1)
    #expect(store.exportInfo(assetId: "switch-asset")?.variants[.edited]?.status == .done)

    manager.versionSelection = .editedWithOriginals
    manager.startExportMonth(year: 2025, month: 1)
    await waitForQueueDrained(manager)

    #expect(writer.writeCalls.count == 2)
    let rec = store.exportInfo(assetId: "switch-asset")
    #expect(rec?.variants[.original]?.status == .done)
    #expect(rec?.variants[.original]?.filename == "IMG_0001_orig.JPG")
    #expect(rec?.variants[.edited]?.filename == "IMG_0001.JPG")
  }

  // MARK: - Post-edit re-export collides at natural stem with one-time `(1)` suffix

  @Test func postEditReExportLandsAtCollisionSuffixedPath() async throws {
    let (manager, photoLib, dest, _, _, store) = makeTestHarness()
    defer { dest.cleanup() }
    manager.versionSelection = .edited

    // Initial export: asset is unedited.
    var asset = TestAssetFactory.makeAsset(id: "post-edit", hasAdjustments: false)
    photoLib.assetsByYearMonth["2025-2"] = [asset]
    photoLib.resourcesByAssetId["post-edit"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.JPG"),
      TestAssetFactory.makeResource(type: .fullSizePhoto, originalFilename: "FullRender.JPG"),
    ]
    manager.startExportMonth(year: 2025, month: 2)
    await waitForQueueDrained(manager)
    #expect(store.exportInfo(assetId: "post-edit")?.variants[.original]?.filename == "IMG_0001.JPG")

    // The user later edits the photo in Photos. Re-run default export.
    asset = TestAssetFactory.makeAsset(id: "post-edit", hasAdjustments: true)
    photoLib.assetsByYearMonth["2025-2"] = [asset]
    manager.startExportMonth(year: 2025, month: 2)
    await waitForQueueDrained(manager)

    let rec = store.exportInfo(assetId: "post-edit")
    // Old `.original.done` is preserved at natural stem; new `.edited.done` lands at the
    // next available stem because the natural stem is taken.
    #expect(rec?.variants[.original]?.status == .done)
    #expect(rec?.variants[.original]?.filename == "IMG_0001.JPG")
    #expect(rec?.variants[.edited]?.status == .done)
    #expect(rec?.variants[.edited]?.filename == "IMG_0001 (1).JPG")
  }

  // MARK: - Inherited group stem with a real `_orig` user filename

  @Test func userOrigFilenameStaysOnItsGroupStemAfterAdjustment() async throws {
    let (manager, photoLib, dest, _, _, store) = makeTestHarness()
    defer { dest.cleanup() }
    manager.versionSelection = .edited

    var asset = TestAssetFactory.makeAsset(id: "user-orig", hasAdjustments: false)
    photoLib.assetsByYearMonth["2025-3"] = [asset]
    photoLib.resourcesByAssetId["user-orig"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "vacation_orig.JPG"),
      TestAssetFactory.makeResource(type: .fullSizePhoto, originalFilename: "FullRender.JPG"),
    ]
    manager.startExportMonth(year: 2025, month: 3)
    await waitForQueueDrained(manager)
    #expect(
      store.exportInfo(assetId: "user-orig")?.variants[.original]?.filename
        == "vacation_orig.JPG")

    // Asset becomes adjusted; re-run default export. The new edit should follow the user's
    // own group stem `vacation_orig`, not collapse to `vacation`.
    asset = TestAssetFactory.makeAsset(id: "user-orig", hasAdjustments: true)
    photoLib.assetsByYearMonth["2025-3"] = [asset]
    manager.startExportMonth(year: 2025, month: 3)
    await waitForQueueDrained(manager)

    let rec = store.exportInfo(assetId: "user-orig")
    #expect(rec?.variants[.edited]?.filename == "vacation_orig (1).JPG")
  }

  // MARK: - Pre-allocation: pre-seeded natural-stem file forces pair onto next stem

  @Test func freshPairAvoidsSplitWhenNaturalEditedStemIsTaken() async throws {
    let (manager, photoLib, dest, _, _, store) = makeTestHarness()
    defer { dest.cleanup() }
    manager.versionSelection = .editedWithOriginals

    // Seed a stray file at the asset's natural-stem edited filename.
    let monthDir = try dest.urlForMonth(year: 2025, month: 4, createIfNeeded: true)
    FileManager.default.createFile(
      atPath: monthDir.appendingPathComponent("IMG_0001.JPG").path,
      contents: Data("stray".utf8))

    let asset = TestAssetFactory.makeAsset(id: "fresh-pair", hasAdjustments: true)
    photoLib.assetsByYearMonth["2025-4"] = [asset]
    photoLib.resourcesByAssetId["fresh-pair"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.HEIC"),
      TestAssetFactory.makeResource(type: .fullSizePhoto, originalFilename: "FullRender.JPG"),
    ]

    manager.startExportMonth(year: 2025, month: 4)
    await waitForQueueDrained(manager)

    let rec = store.exportInfo(assetId: "fresh-pair")
    #expect(rec?.variants[.edited]?.filename == "IMG_0001 (1).JPG")
    #expect(rec?.variants[.original]?.filename == "IMG_0001 (1)_orig.HEIC")
  }

  // MARK: - Sidebar summary accuracy

  @Test func sidebarSummaryForEditedWithOriginalsAdjustedOnlyOneVariantDone() async throws {
    let (_, _, dest, _, _, store) = makeTestHarness()
    defer { dest.cleanup() }

    // Asset is adjusted; only `.edited.done` recorded (no `.original.done`).
    store.markVariantExported(
      assetId: "edited-only-asset", variant: .edited, year: 2025, month: 6,
      relPath: "2025/06/", filename: "IMG_0001.JPG", exportedAt: Date())
    store.flushForTesting()

    // Under editedWithOriginals: bothDone=0, origOnlyAtStem=0, uneditedCount=0 → 0 exported.
    let summary = store.sidebarSummary(
      year: 2025, month: 6, totalCount: 1, adjustedCount: 1,
      selection: .editedWithOriginals)
    #expect(summary?.exportedCount == 0)
    #expect(summary?.status == .notExported)
  }

  @Test func sidebarSummaryCountsBothVariantsDone() async throws {
    let (_, _, dest, _, _, store) = makeTestHarness()
    defer { dest.cleanup() }

    let now = Date()
    store.markVariantExported(
      assetId: "adj-asset", variant: .original, year: 2025, month: 7,
      relPath: "2025/07/", filename: "IMG_0001_orig.JPG", exportedAt: now)
    store.markVariantExported(
      assetId: "adj-asset", variant: .edited, year: 2025, month: 7,
      relPath: "2025/07/", filename: "IMG_0001.JPG", exportedAt: now)
    store.markExported(
      assetId: "plain-asset", year: 2025, month: 7, relPath: "2025/07/",
      filename: "IMG_0002.JPG", exportedAt: now)
    store.flushForTesting()

    let summary = store.sidebarSummary(
      year: 2025, month: 7, totalCount: 2, adjustedCount: 1,
      selection: .editedWithOriginals)
    #expect(summary?.exportedCount == 2)
    #expect(summary?.status == .complete)
  }

  // MARK: - Original succeeds and edited fails independently

  @Test func originalSucceedsEvenIfEditedFails() async throws {
    let (manager, photoLib, dest, _, _, store) = makeTestHarness()
    defer { dest.cleanup() }
    manager.versionSelection = .editedWithOriginals

    let asset = TestAssetFactory.makeAsset(id: "mixed", hasAdjustments: true)
    photoLib.assetsByYearMonth["2025-2"] = [asset]
    photoLib.resourcesByAssetId["mixed"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.JPG")
    ]

    manager.startExportMonth(year: 2025, month: 2)
    await waitForQueueDrained(manager)

    let record = store.exportInfo(assetId: "mixed")
    #expect(record?.variants[.original]?.status == .done)
    #expect(record?.variants[.edited]?.status == .failed)
  }
}
