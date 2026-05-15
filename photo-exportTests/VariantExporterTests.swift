import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Phase 3a unit tests for `VariantExporter`. Drives the exporter directly with a fake
/// `Host` so the host-protocol contract is pinned (rather than only being exercised
/// through `ExportManager`'s end-to-end pipeline tests). Targets specifically the two
/// host-routing invariants that a future regression could silently bypass:
///
/// 1. `Host.recordVariantFailed` (bookkeeping-aware) is the only failure-recording path.
/// 2. `Host.renderToTempURL` is invoked exactly when the producer is `.render` (and not
///    when it's `.resource`).
@MainActor
struct VariantExporterTests {

  // MARK: - Fake Host

  /// Records every Host call so the test can assert routing without spinning up
  /// `ExportManager`. The cancellation seam (`isCurrent` / `throwIfCancelledOrStale`)
  /// always returns "current" — none of the tests in this file exercise cancellation.
  private final class FakeHost: VariantExporter.Host {
    var renderCalls: [(request: MediaRenderRequest, tempURL: URL)] = []
    var failureCalls: [(assetId: String, variant: ExportVariant, message: String)] = []
    var renderError: Error?

    nonisolated func isCurrent(_ gen: Int) -> Bool { true }
    nonisolated func throwIfCancelledOrStale(_ gen: Int) throws {}

    func setCurrentAssetFilename(_ name: String?) {}
    func setCurrentJobVariant(_ variant: ExportVariant?) {}
    func clearRenderActivity() {}

    func recordVariantFailed(
      assetId: String, placement: ExportPlacement, variant: ExportVariant,
      sentinelMessage: String, category: AutoSyncFailureCategory, at: Date
    ) {
      failureCalls.append((assetId: assetId, variant: variant, message: sentinelMessage))
    }

    func renderToTempURL(request: MediaRenderRequest, tempURL: URL) async throws {
      renderCalls.append((request: request, tempURL: tempURL))
      if let renderError { throw renderError }
      // Write a stub byte so the subsequent atomic move has something to move.
      FileManager.default.createFile(atPath: tempURL.path, contents: Data("x".utf8))
    }
  }

  // MARK: - Harness

  private struct Harness {
    let exporter: VariantExporter
    let host: FakeHost
    let writer: FakeAssetResourceWriter
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
    let exporter = VariantExporter(
      host: host,
      destinationResolver: resolver,
      recordStoreRouter: router,
      assetResourceWriter: writer,
      fileSystem: fileSystem,
      exportDestination: dest)
    return Harness(exporter: exporter, host: host, writer: writer,
      destDir: destDir, storeRoot: storeRoot)
  }

  // MARK: - Tests

  /// Static-resource producer (no edits): the writer is invoked; `Host.renderToTempURL`
  /// is NOT called. Pinning this prevents a future bug where the render branch is taken
  /// for a `.resource` producer.
  @Test func staticResourceProducer_writesViaResourceWriter_doesNotRenderViaHost() async throws {
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

    #expect(h.host.renderCalls.isEmpty,
      "Host.renderToTempURL must not be called for static-resource producers")
    #expect(h.writer.writeCalls.contains { $0.assetId == "static" },
      "AssetResourceWriter must be called for static-resource producers")
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
}
