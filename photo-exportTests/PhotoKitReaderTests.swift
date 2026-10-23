import Foundation
import Testing

@testable import Photo_Export

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct PhotoKitReaderTests {
  @Test func completedJobAvoidsMainActorMetadataServiceCalls() async throws {
    let h = ExportManagerHarness(label: "ExportPhotoKitReader")
    defer {
      h.manager.cancelAndClear()
      h.store.drainSynchronously()
      h.collectionStore.drainSynchronously()
      h.dest.cleanup()
      try? FileManager.default.removeItem(at: h.storeRoot)
    }
    let asset = TestAssetFactory.makeAsset(
      id: "reader-asset",
      creationDate: Calendar.current.date(from: DateComponents(year: 2025, month: 4, day: 15)))
    h.photoLib.assetsByYearMonth["2025-4"] = [asset]
    h.photoLib.resourcesByAssetId[asset.id] = [
      .init(type: .photo, originalFilename: "READER.JPG", fileSize: 12)
    ]
    h.manager.startExportMonth(year: 2025, month: 4)
    await h.manager.waitForQueueDrained()
    #expect(h.writer.writeCalls.count == 1, "The completed job is the positive control")
    #expect(h.store.exportInfo(assetId: asset.id)?.variants[.original]?.status == .done)
    #expect(h.photoLib.descriptorFetchCalls.isEmpty)
    #expect(h.photoLib.resourcesCallCounts.isEmpty)
  }
}
