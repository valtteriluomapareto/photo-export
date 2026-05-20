import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Phase 3a/3b unit tests for `VariantExporter`. Drives the exporter directly with a fake
/// `Host` and a fake `MediaRenderer` so the host-protocol contract and the renderer
/// dispatch are pinned (rather than only being exercised through `ExportManager`'s
/// end-to-end pipeline tests). Targets specifically the two routing invariants that a
/// future regression could silently bypass:
///
/// 1. `Host.recordVariantFailed` (bookkeeping-aware) is the only failure-recording path.
/// 2. `MediaRenderer.render` is invoked exactly when the producer is `.render` (and not
///    when it's `.resource`).
@MainActor
struct VariantExporterTests {

  // MARK: - Fake Host

  /// Records every Host call so the test can assert routing without spinning up
  /// `ExportManager`. None of the tests in this file exercise cancellation; the
  /// real `ExportQueueCoordinator` injected for the cancellation seam stays at
  /// generation 0 and `isCurrent(0)` always returns true.
  ///
  /// Post-Phase-3b the Host no longer carries the render bridge; the renderer is a
  /// direct dependency of `VariantExporter`. `FakeMediaRenderer` records `renderCalls`
  /// on its own. Post-issue-#67-item-2 the cancellation seam is no longer on the
  /// Host either — it routes through the injected `ExportQueueCoordinator`.
  private final class FakeHost: VariantExporter.Host, ExportQueueCoordinator.Host {
    var failureCalls: [(assetId: String, variant: ExportVariant, message: String)] = []
    var convertHEICToJPEG: Bool = false

    func setCurrentAssetFilename(_ name: String?) {}
    func setCurrentJobVariant(_ variant: ExportVariant?) {}
    func clearRenderActivity() {}

    func recordVariantFailed(
      assetId: String, placement: ExportPlacement, variant: ExportVariant,
      sentinelMessage: String, category: AutoSyncFailureCategory, at: Date
    ) {
      failureCalls.append((assetId: assetId, variant: variant, message: sentinelMessage))
    }

    // ExportQueueCoordinator.Host — only required so the coordinator can be
    // constructed; the tests in this file never drive the queue.
    var isEnqueueingAll: Bool { false }
    func performExport(job: ExportManager.ExportJob, generation: Int) async {}
    func didDrainQueue() {}
    func setCurrentJob(_ job: ExportManager.ExportJob) {}
    func clearCurrentJobIdentifiers() {}
  }

  // MARK: - Harness

  private struct Harness {
    let exporter: VariantExporter
    let host: FakeHost
    let writer: FakeAssetResourceWriter
    let renderer: FakeMediaRenderer
    let converter: FakeImageConverter
    let fileSystem: FakeFileSystem
    let destDir: URL
    let storeRoot: URL

    func cleanup() {
      try? FileManager.default.removeItem(at: destDir)
      try? FileManager.default.removeItem(at: storeRoot)
    }
  }

  private func makeHarness() -> Harness {
    let host = FakeHost()
    let writer = FakeAssetResourceWriter()
    let renderer = FakeMediaRenderer()
    let converter = FakeImageConverter()
    let fileSystem = FakeFileSystem()
    let dest = FakeExportDestination()
    let storeRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("VariantExporter-\(UUID().uuidString)", isDirectory: true)
    let timeline = ExportRecordStore(baseDirectoryURL: storeRoot)
    timeline.configure(for: "test")
    let collection = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    collection.configure(for: "test")
    let router = RecordStoreRouter(timelineStore: timeline, collectionStore: collection)
    let resolver = ExportDestinationResolver(fileSystem: fileSystem)
    let destDir = dest.rootURL.appendingPathComponent("2025/07/", isDirectory: true)
    try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
    let queueCoordinator = ExportQueueCoordinator(host: host)
    let exporter = VariantExporter(
      host: host,
      queueCoordinator: queueCoordinator,
      destinationResolver: resolver,
      recordStoreRouter: router,
      assetResourceWriter: writer,
      mediaRenderer: renderer,
      imageConverter: converter,
      fileSystem: fileSystem,
      exportDestination: dest)
    return Harness(
      exporter: exporter, host: host, writer: writer, renderer: renderer,
      converter: converter, fileSystem: fileSystem,
      destDir: destDir, storeRoot: storeRoot)
  }

  // MARK: - Tests

  /// Static-resource producer (no edits): the writer is invoked; the renderer is NOT
  /// called. Pinning this prevents a future bug where the render branch is taken for a
  /// `.resource` producer.
  @Test func staticResourceProducer_writesViaResourceWriter_doesNotRender() async throws {
    let h = makeHarness()
    defer { h.cleanup() }

    let asset = TestAssetFactory.makeAsset(id: "static", hasAdjustments: false)
    let resources = [TestAssetFactory.makeResource(originalFilename: "IMG.HEIC")]
    var inFlight: (assetId: String, variant: ExportVariant)?

    _ = try await h.exporter.exportSingleVariant(
      variant: .original, descriptor: asset, resources: resources,
      destDir: h.destDir, relPath: "2025/07/",
      job: ExportManager.ExportJob(
        assetLocalIdentifier: asset.id,
        placement: .timeline(year: 2025, month: 7),
        selection: .edited),
      groupStem: nil, pairOriginalWithSuffix: false,
      generation: 0, inFlight: &inFlight)

    #expect(h.renderer.renderCalls.isEmpty,
      "MediaRenderer must not be called for static-resource producers")
    #expect(h.writer.writeCalls.contains { $0.assetId == "static" },
      "AssetResourceWriter must be called for static-resource producers")
  }

  /// Rendered-media producer (Phase 3b): the renderer is invoked directly on
  /// `VariantExporter`'s own dependency, not through any `Host` bridge.
  @Test func renderedMediaProducer_invokesMediaRendererDirectly() async throws {
    let h = makeHarness()
    defer { h.cleanup() }

    // Adjusted video asset with only a `.video` resource → producer selects `.render`.
    let asset = TestAssetFactory.makeAsset(
      id: "rendered", mediaType: .video, hasAdjustments: true)
    let resources = [
      TestAssetFactory.makeResource(type: .video, originalFilename: "VID.MOV")
    ]
    var inFlight: (assetId: String, variant: ExportVariant)?

    _ = try await h.exporter.exportSingleVariant(
      variant: .edited, descriptor: asset, resources: resources,
      destDir: h.destDir, relPath: "2025/07/",
      job: ExportManager.ExportJob(
        assetLocalIdentifier: asset.id,
        placement: .timeline(year: 2025, month: 7),
        selection: .edited),
      groupStem: nil, pairOriginalWithSuffix: false,
      generation: 0, inFlight: &inFlight)

    #expect(h.renderer.renderCalls.count == 1,
      "MediaRenderer.render must be invoked exactly once for rendered-media producers; got \(h.renderer.renderCalls.count)")
    #expect(h.renderer.renderCalls.first?.request.assetId == "rendered")
  }

  /// Render-failure error translation: a non-cancellation throw from the renderer must
  /// be re-thrown as `NSError(domain: "Export", code: 9, NSLocalizedDescriptionKey:
  /// ExportVariantRecovery.editedResourceUnavailableMessage)`. The persisted `lastError`
  /// shape feeds `AutoSyncFailureCategory.classify`, the issue #22 fallback trigger, and
  /// the user-visible "could not be exported this time" copy. A future refactor that
  /// re-threw a different error type with the same localized description would silently
  /// regress AutoSync retry routing without failing the existing end-to-end tests.
  @Test func renderFailure_translatedToExportDomainCode9NSError() async {
    let h = makeHarness()
    defer { h.cleanup() }

    h.renderer.renderError = NSError(domain: "Test", code: 42, userInfo: nil)

    let asset = TestAssetFactory.makeAsset(
      id: "render-err", mediaType: .video, hasAdjustments: true)
    let resources = [
      TestAssetFactory.makeResource(type: .video, originalFilename: "VID.MOV")
    ]
    var inFlight: (assetId: String, variant: ExportVariant)?

    do {
      _ = try await h.exporter.exportSingleVariant(
        variant: .edited, descriptor: asset, resources: resources,
        destDir: h.destDir, relPath: "2025/07/",
        job: ExportManager.ExportJob(
          assetLocalIdentifier: asset.id,
          placement: .timeline(year: 2025, month: 7),
          selection: .edited),
        groupStem: nil, pairOriginalWithSuffix: false,
        generation: 0, inFlight: &inFlight)
      Issue.record("Expected throw on render failure")
    } catch {
      let nsError = error as NSError
      #expect(nsError.domain == "Export",
        "render-failure throw must be NSError domain \"Export\"; got \(nsError.domain)")
      #expect(nsError.code == 9,
        "render-failure throw must be NSError code 9; got \(nsError.code)")
      #expect(nsError.localizedDescription
        == ExportVariantRecovery.editedResourceUnavailableMessage,
        "render-failure localizedDescription must be the canonical sentinel; got \(nsError.localizedDescription)")
    }
  }

  /// "No resource" producer (e.g. video asset with no resources seeded): the exporter
  /// records the failure through `Host.recordVariantFailed` (not through
  /// `RecordStoreRouter.markVariantFailed` directly), so the bookkeeping-aware path
  /// runs and `ExportRunSummary.failedCount` can increment.
  @Test func noResourceProducer_recordsFailureThroughHost() async throws {
    let h = makeHarness()
    defer { h.cleanup() }

    // Video asset, no resources → producer.originalFilename is nil → sentinel failure.
    let asset = TestAssetFactory.makeAsset(id: "no-res", mediaType: .video)
    var inFlight: (assetId: String, variant: ExportVariant)?

    let result = try await h.exporter.exportSingleVariant(
      variant: .original, descriptor: asset, resources: [],
      destDir: h.destDir, relPath: "2025/07/",
      job: ExportManager.ExportJob(
        assetLocalIdentifier: asset.id,
        placement: .timeline(year: 2025, month: 7),
        selection: .edited),
      groupStem: nil, pairOriginalWithSuffix: false,
      generation: 0, inFlight: &inFlight)

    #expect(result == nil, "no-resource path must return nil (no chosenStem)")
    #expect(h.host.failureCalls.count == 1,
      "Host.recordVariantFailed must be called exactly once; got \(h.host.failureCalls.count)")
    #expect(h.host.failureCalls.first?.assetId == "no-res")
    #expect(h.host.failureCalls.first?.message == "No exportable resource")
  }

  // MARK: - HEIC→JPEG conversion (issue #47)

  /// HEIC original + toggle ON + unedited asset: `selectEditedProducer` returns
  /// `.convertHEIC`, so `VariantExporter` invokes `ImageConverter.convertHEIC`
  /// and the synthesized JPEG lands at `<stem>.JPG` (not `.HEIC`). The static
  /// resource writer must NOT be called — that would double-write the same
  /// bytes through the wrong path. Pins the host-accessor seam end-to-end:
  /// host returns the toggle value, exporter threads it through selection,
  /// the converter sees the call.
  @Test func heicWithToggleOnAndUneditedAsset_invokesConverterAndWritesJPEG() async throws {
    let h = makeHarness()
    defer { h.cleanup() }
    h.host.convertHEICToJPEG = true

    let asset = TestAssetFactory.makeAsset(
      id: "heic-unedited", hasAdjustments: false,
      originalUTI: "public.heic")
    let resources = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.HEIC")
    ]
    var inFlight: (assetId: String, variant: ExportVariant)?

    _ = try await h.exporter.exportSingleVariant(
      variant: .edited, descriptor: asset, resources: resources,
      destDir: h.destDir, relPath: "2025/07/",
      job: ExportManager.ExportJob(
        assetLocalIdentifier: asset.id,
        placement: .timeline(year: 2025, month: 7),
        selection: .edited),
      groupStem: nil, pairOriginalWithSuffix: false,
      generation: 0, inFlight: &inFlight)

    #expect(h.converter.convertCalls.count == 1,
      "ImageConverter.convertHEIC must be invoked once for unedited HEIC under toggle on; got \(h.converter.convertCalls.count)")
    // Convert destination is a `.tmp` file; the exporter strips `.tmp` and
    // moves to the final URL. Assert the move target ends in `.JPG`.
    let movedTo = h.fileSystem.moveCalls.last?.to.lastPathComponent ?? ""
    #expect(movedTo.uppercased().hasSuffix(".JPG"),
      "Final on-disk filename must end in .JPG; got \(movedTo)")
    // The writer IS called to materialize the source HEIC bytes for the
    // converter to read (to a `.heic-source` temp path). That's the
    // documented `EditedProducer.convertHEIC` materialization flow; assert
    // the writer's target is the temp side-file rather than the final
    // variant location.
    let writerTargetExt =
      h.writer.writeCalls.first { $0.assetId == "heic-unedited" }?.url.lastPathComponent ?? ""
    #expect(writerTargetExt.hasSuffix(".heic-source"),
      "Writer must materialize the HEIC source to a `.heic-source` temp; got \(writerTargetExt)")
  }

  /// HEIC original + toggle OFF + unedited asset: the asset has no edits and
  /// the toggle is off, so `selectEditedProducer` returns `.none` — the
  /// exporter records a sentinel failure and never invokes the converter.
  /// This is the documented "edited resource unavailable" sentinel path; the
  /// pipeline's `runEditedFallbackOriginal` then writes the original at a
  /// `_orig` companion (covered elsewhere). What this test pins is the seam:
  /// without the toggle, the converter must not be reached.
  @Test func heicWithToggleOffAndUneditedAsset_doesNotInvokeConverter() async throws {
    let h = makeHarness()
    defer { h.cleanup() }
    h.host.convertHEICToJPEG = false

    let asset = TestAssetFactory.makeAsset(
      id: "heic-untouched", hasAdjustments: false,
      originalUTI: "public.heic")
    let resources = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.HEIC")
    ]
    var inFlight: (assetId: String, variant: ExportVariant)?

    _ = try await h.exporter.exportSingleVariant(
      variant: .edited, descriptor: asset, resources: resources,
      destDir: h.destDir, relPath: "2025/07/",
      job: ExportManager.ExportJob(
        assetLocalIdentifier: asset.id,
        placement: .timeline(year: 2025, month: 7),
        selection: .edited),
      groupStem: nil, pairOriginalWithSuffix: false,
      generation: 0, inFlight: &inFlight)

    #expect(h.converter.convertCalls.isEmpty,
      "ImageConverter.convertHEIC must not be invoked when toggle is off; got \(h.converter.convertCalls.count) calls")
    #expect(h.host.failureCalls.contains { $0.assetId == "heic-untouched" },
      "Unedited HEIC under .edited selection with toggle off should record an editedResourceUnavailable failure")
  }
}
