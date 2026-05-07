import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Pipeline tests for the new edited-video render path. Drive
/// `ExportManager` end-to-end with `FakeMediaRenderer` injected so we can
/// assert what byte source the pipeline reaches for, what the cancel
/// contract guarantees, and how the render path interacts with paired
/// `_orig` companions and collision suffixing.
@MainActor
struct ExportManagerVideoRenderTests {
  // MARK: - Test harness

  private struct Harness {
    let manager: ExportManager
    let photoLib: FakePhotoLibraryService
    let dest: FakeExportDestination
    let writer: FakeAssetResourceWriter
    let renderer: FakeMediaRenderer
    let fileSystem: FakeFileSystem
    let store: ExportRecordStore
  }

  private func makeHarness() -> Harness {
    let photoLib = FakePhotoLibraryService()
    let dest = FakeExportDestination()
    let writer = FakeAssetResourceWriter()
    let renderer = FakeMediaRenderer()
    let fileSystem = FakeFileSystem()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("VideoRenderTest-\(UUID().uuidString)", isDirectory: true)
    let store = ExportRecordStore(baseDirectoryURL: tempDir)
    store.configure(for: "test")

    let defaults = UserDefaults(
      suiteName: "test-VideoRender-\(UUID().uuidString)")!

    let manager = ExportManager(
      photoLibraryService: photoLib,
      exportDestination: dest,
      exportRecordStore: store,
      assetResourceWriter: writer,
      mediaRenderer: renderer,
      fileSystem: fileSystem,
      userDefaults: defaults
    )
    return Harness(
      manager: manager, photoLib: photoLib, dest: dest, writer: writer,
      renderer: renderer, fileSystem: fileSystem, store: store)
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

  private func adjustedVideo(
    id: String = "edited-video",
    filename: String = "IMG_1234.MOV"
  ) -> (asset: AssetDescriptor, resources: [ResourceDescriptor]) {
    let asset = TestAssetFactory.makeAsset(
      id: id, mediaType: .video, hasAdjustments: true)
    let resources = [TestAssetFactory.makeResource(type: .video, originalFilename: filename)]
    return (asset, resources)
  }

  // MARK: - 1. Render path takes over when no .fullSizeVideo resource exists

  @Test func adjustedVideoWithOnlyOriginalResourceGoesThroughRenderer() async throws {
    let h = makeHarness()
    defer { h.dest.cleanup() }
    h.manager.versionSelection = .edited

    let (asset, resources) = adjustedVideo()
    h.photoLib.assetsByYearMonth["2025-3"] = [asset]
    h.photoLib.resourcesByAssetId[asset.id] = resources

    h.manager.startExportMonth(year: 2025, month: 3)
    await waitForQueueDrained(h.manager)

    let record = h.store.exportInfo(assetId: asset.id)
    #expect(record?.variants[.edited]?.status == .done)
    #expect(record?.variants[.edited]?.filename == "IMG_1234.MOV")
    #expect(h.renderer.renderCalls.count == 1)
    #expect(h.renderer.renderCalls.first?.request.assetId == asset.id)
    #expect(h.renderer.renderCalls.first?.request.originalFilename == "IMG_1234.MOV")
    // Resource writer must NOT have been called for the edited variant.
    #expect(h.writer.writeCalls.allSatisfy { $0.assetId != asset.id })
  }

  // MARK: - 2. Fast path when .fullSizeVideo IS present (rare but real)

  @Test func adjustedVideoWithFullSizeVideoUsesResourceWriter() async throws {
    let h = makeHarness()
    defer { h.dest.cleanup() }
    h.manager.versionSelection = .edited

    let asset = TestAssetFactory.makeAsset(
      id: "rare-edit", mediaType: .video, hasAdjustments: true)
    h.photoLib.assetsByYearMonth["2025-4"] = [asset]
    h.photoLib.resourcesByAssetId[asset.id] = [
      TestAssetFactory.makeResource(type: .video, originalFilename: "IMG_5555.MOV"),
      TestAssetFactory.makeResource(type: .fullSizeVideo, originalFilename: "rendered.MOV"),
    ]

    h.manager.startExportMonth(year: 2025, month: 4)
    await waitForQueueDrained(h.manager)

    let record = h.store.exportInfo(assetId: asset.id)
    #expect(record?.variants[.edited]?.status == .done)
    // Renderer must NOT be called when the static resource exists.
    #expect(h.renderer.renderCalls.isEmpty)
    #expect(h.writer.writeCalls.contains { $0.assetId == asset.id })
  }

  // MARK: - 3. Render failure → recoverable .failed, then fallback covers it

  @Test func renderFailureRecordsRecoverableEditedFailure() async throws {
    let h = makeHarness()
    defer { h.dest.cleanup() }
    h.manager.versionSelection = .edited

    h.renderer.renderError = NSError(
      domain: "MediaRenderer", code: 42,
      userInfo: [NSLocalizedDescriptionKey: "AVFoundation oh no"])

    let (asset, resources) = adjustedVideo(id: "render-fail")
    h.photoLib.assetsByYearMonth["2025-5"] = [asset]
    h.photoLib.resourcesByAssetId[asset.id] = resources

    h.manager.startExportMonth(year: 2025, month: 5)
    await waitForQueueDrained(h.manager)

    // Render failure marks `.edited` as recoverable with the generic
    // sentinel; the issue #22 fallback then writes the original as `_orig`
    // and rewrites `.edited.lastError` to the explicit fallback-covered
    // sentinel. Both messages are `isRecoverable`.
    let record = h.store.exportInfo(assetId: asset.id)
    #expect(record?.variants[.edited]?.status == .failed)
    #expect(
      record?.variants[.edited]?.lastError
        == ExportVariantRecovery.editedUnavailableOriginalBackedUpMessage)
    #expect(ExportVariantRecovery.isRecoverable(record?.variants[.edited]?.lastError))
    #expect(record?.variants[.original]?.status == .done)
    // Render activity must be cleared even on failure.
    #expect(h.manager.renderActivity == nil)
  }

  // MARK: - 4. No edited-side bytes available at all

  @Test func adjustedVideoWithNoResourcesFailsRecoverably() async throws {
    let h = makeHarness()
    defer { h.dest.cleanup() }
    h.manager.versionSelection = .edited

    let asset = TestAssetFactory.makeAsset(
      id: "no-resources", mediaType: .video, hasAdjustments: true)
    h.photoLib.assetsByYearMonth["2025-6"] = [asset]
    h.photoLib.resourcesByAssetId[asset.id] = []  // no .video, no .fullSizeVideo

    h.manager.startExportMonth(year: 2025, month: 6)
    await waitForQueueDrained(h.manager)

    let record = h.store.exportInfo(assetId: asset.id)
    #expect(record?.variants[.edited]?.status == .failed)
    #expect(
      record?.variants[.edited]?.lastError
        == ExportVariantRecovery.editedResourceUnavailableMessage)
    #expect(h.renderer.renderCalls.isEmpty)
  }

  // MARK: - 5. editedWithOriginals: edited via renderer, original via writer

  @Test func editedWithOriginalsModeUsesRendererPlusWriterForVideo() async throws {
    let h = makeHarness()
    defer { h.dest.cleanup() }
    h.manager.versionSelection = .editedWithOriginals

    let (asset, resources) = adjustedVideo(id: "pair", filename: "IMG_9000.MOV")
    h.photoLib.assetsByYearMonth["2025-7"] = [asset]
    h.photoLib.resourcesByAssetId[asset.id] = resources

    h.manager.startExportMonth(year: 2025, month: 7)
    await waitForQueueDrained(h.manager)

    let record = h.store.exportInfo(assetId: asset.id)
    #expect(record?.variants[.edited]?.status == .done)
    #expect(record?.variants[.original]?.status == .done)
    #expect(record?.variants[.edited]?.filename == "IMG_9000.MOV")
    #expect(record?.variants[.original]?.filename == "IMG_9000_orig.MOV")
    #expect(h.renderer.renderCalls.count == 1)
    // Writer must have been called for the .original variant.
    #expect(h.writer.writeCalls.contains { $0.assetId == asset.id })
  }

  // MARK: - 6. Cancel during render

  @Test func cancelDuringRenderRemovesInProgressRecord() async throws {
    let h = makeHarness()
    defer { h.dest.cleanup() }
    h.manager.versionSelection = .edited

    // Park the render at a latch and arm a one-shot "entered" signal
    // so we can deterministically know the pipeline has reached the
    // render call (and therefore set `inFlight` and marked the variant
    // in-progress) before we trigger cancel.
    let latch = AsyncSemaphore()
    let entered = AsyncSemaphore()
    h.renderer.arm(latch: latch)
    h.renderer.arm(enteredSignal: entered)

    let (asset, resources) = adjustedVideo(id: "cancel-me")
    h.photoLib.assetsByYearMonth["2025-8"] = [asset]
    h.photoLib.resourcesByAssetId[asset.id] = resources

    h.manager.startExportMonth(year: 2025, month: 8)

    await entered.wait()
    h.manager.cancelAndClear()
    latch.signal()
    await waitForQueueDrained(h.manager)

    let record = h.store.exportInfo(assetId: asset.id)
    #expect(record?.variants[.edited]?.status != .failed)
    // The in-progress record for the cancelled variant must be removed.
    if let v = record?.variants[.edited] {
      #expect(v.status != .inProgress)
    }
    // Render activity must be cleared on cancel.
    #expect(h.manager.renderActivity == nil)
    // No final file at finalURL.
    let monthDir = h.dest.rootURL.appendingPathComponent("2025/08")
    let candidate = monthDir.appendingPathComponent("IMG_1234.MOV")
    #expect(!FileManager.default.fileExists(atPath: candidate.path))
  }

  // MARK: - 7. Stale .tmp from a prior render run is cleared

  @Test func staleTempFileFromPriorRenderIsRemovedBeforeWrite() async throws {
    let h = makeHarness()
    defer { h.dest.cleanup() }
    h.manager.versionSelection = .edited

    let (asset, resources) = adjustedVideo(id: "stale", filename: "IMG_3210.MOV")
    h.photoLib.assetsByYearMonth["2025-9"] = [asset]
    h.photoLib.resourcesByAssetId[asset.id] = resources

    let monthDir = h.dest.rootURL.appendingPathComponent("2025/09")
    try FileManager.default.createDirectory(
      at: monthDir, withIntermediateDirectories: true)
    let staleTmp = monthDir.appendingPathComponent("IMG_3210.MOV.tmp")
    FileManager.default.createFile(atPath: staleTmp.path, contents: Data("stale".utf8))

    h.manager.startExportMonth(year: 2025, month: 9)
    await waitForQueueDrained(h.manager)

    let record = h.store.exportInfo(assetId: asset.id)
    #expect(record?.variants[.edited]?.status == .done)
    #expect(!FileManager.default.fileExists(atPath: staleTmp.path))
  }

  // MARK: - 8. Move failure after a successful render cleans up tmp

  @Test func moveFailureAfterRenderCleansTempAndMarksFailed() async throws {
    let h = makeHarness()
    defer { h.dest.cleanup() }
    h.manager.versionSelection = .edited
    h.fileSystem.moveError = NSError(
      domain: "FS", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "disk full"])

    let (asset, resources) = adjustedVideo(id: "move-fail", filename: "IMG_4321.MOV")
    h.photoLib.assetsByYearMonth["2025-10"] = [asset]
    h.photoLib.resourcesByAssetId[asset.id] = resources

    h.manager.startExportMonth(year: 2025, month: 10)
    await waitForQueueDrained(h.manager)

    let record = h.store.exportInfo(assetId: asset.id)
    #expect(record?.variants[.edited]?.status == .failed)
    let monthDir = h.dest.rootURL.appendingPathComponent("2025/10")
    let staleTmp = monthDir.appendingPathComponent("IMG_4321.MOV.tmp")
    #expect(!FileManager.default.fileExists(atPath: staleTmp.path))
  }

  // MARK: - 9. Re-edit after successful export lands at (1) suffix

  @Test func reEditedVideoLandsAtCollisionSuffix() async throws {
    let h = makeHarness()
    defer { h.dest.cleanup() }
    h.manager.versionSelection = .edited

    // First export: unedited video → writer path lands at IMG_7777.MOV
    var asset = TestAssetFactory.makeAsset(
      id: "re-edit", mediaType: .video, hasAdjustments: false)
    h.photoLib.assetsByYearMonth["2025-11"] = [asset]
    h.photoLib.resourcesByAssetId[asset.id] = [
      TestAssetFactory.makeResource(type: .video, originalFilename: "IMG_7777.MOV")
    ]
    h.manager.startExportMonth(year: 2025, month: 11)
    await waitForQueueDrained(h.manager)

    // User edits in Photos. hasAdjustments flips to true.
    asset = TestAssetFactory.makeAsset(
      id: "re-edit", mediaType: .video, hasAdjustments: true)
    h.photoLib.assetsByYearMonth["2025-11"] = [asset]
    h.manager.startExportMonth(year: 2025, month: 11)
    await waitForQueueDrained(h.manager)

    let record = h.store.exportInfo(assetId: asset.id)
    #expect(record?.variants[.edited]?.status == .done)
    #expect(record?.variants[.edited]?.filename == "IMG_7777 (1).MOV")
    #expect(h.renderer.renderCalls.count == 1)
  }

  // MARK: - 10. Unedited video keeps using the writer

  @Test func uneditedVideoNeverReachesRenderer() async throws {
    let h = makeHarness()
    defer { h.dest.cleanup() }
    h.manager.versionSelection = .edited

    let asset = TestAssetFactory.makeAsset(
      id: "plain-video", mediaType: .video, hasAdjustments: false)
    h.photoLib.assetsByYearMonth["2025-12"] = [asset]
    h.photoLib.resourcesByAssetId[asset.id] = [
      TestAssetFactory.makeResource(type: .video, originalFilename: "IMG_0042.MOV")
    ]

    h.manager.startExportMonth(year: 2025, month: 12)
    await waitForQueueDrained(h.manager)

    let record = h.store.exportInfo(assetId: asset.id)
    #expect(record?.variants[.original]?.status == .done)
    #expect(h.renderer.renderCalls.isEmpty)
  }

  // MARK: - 11. Render-activity defer clears state on success

  @Test func renderActivityClearsAfterSuccessfulRender() async throws {
    let h = makeHarness()
    defer { h.dest.cleanup() }
    h.manager.versionSelection = .edited

    let (asset, resources) = adjustedVideo(id: "activity-clear")
    h.photoLib.assetsByYearMonth["2025-1"] = [asset]
    h.photoLib.resourcesByAssetId[asset.id] = resources

    h.manager.startExportMonth(year: 2025, month: 1)
    await waitForQueueDrained(h.manager)

    #expect(h.manager.renderActivity == nil)
  }

  // MARK: - 12. Renderer reports success but writes a zero-byte file

  @Test func zeroByteRenderSuccessStillCompletesPipeline() async throws {
    let h = makeHarness()
    defer { h.dest.cleanup() }
    h.manager.versionSelection = .edited

    h.renderer.fileWriter = { url in
      FileManager.default.createFile(atPath: url.path, contents: Data())
    }

    let (asset, resources) = adjustedVideo(id: "zero-byte")
    h.photoLib.assetsByYearMonth["2025-2"] = [asset]
    h.photoLib.resourcesByAssetId[asset.id] = resources

    h.manager.startExportMonth(year: 2025, month: 2)
    await waitForQueueDrained(h.manager)

    // Pipeline does not size-sanity-check the renderer's output. The
    // record completes. Documenting this as known-acceptable behaviour:
    // renderer success means renderer success, even if the bytes are
    // empty — downstream readers detect zero-byte files.
    let record = h.store.exportInfo(assetId: asset.id)
    #expect(record?.variants[.edited]?.status == .done)
  }
}
