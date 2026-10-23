import Foundation
import Testing

@testable import Photo_Export

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct ExportPreparationTests {
  private final class LeafGate: @unchecked Sendable {
    let entered = AsyncCheckpoint()
    private let semaphore = DispatchSemaphore(value: 0)
    func hold() {
      Task { await entered.enter() }
      semaphore.wait()
    }
    func release() { semaphore.signal() }
  }

  private func admit(_ h: ExportManagerHarness, paired: Bool = false) {
    let asset = TestAssetFactory.makeAsset(
      id: "prepare",
      creationDate: Calendar.current.date(from: DateComponents(year: 2025, month: 4, day: 15)),
      hasAdjustments: paired)
    h.photoLib.assetsByYearMonth["2025-4"] = [asset]
    h.photoLib.resourcesByAssetId[asset.id] =
      [
        .init(type: .photo, originalFilename: "IMG.JPG", fileSize: 12)
      ] + (paired ? [.init(type: .fullSizePhoto, originalFilename: "IMG.JPG", fileSize: 12)] : [])
    h.manager.versionSelection = paired ? .editedWithOriginals : .edited
    h.manager.startExportMonth(year: 2025, month: 4)
  }

  private func cleanup(_ h: ExportManagerHarness) {
    h.manager.cancelAndClear()
    h.store.drainSynchronously()
    h.collectionStore.drainSynchronously()
    h.dest.cleanup()
    try? FileManager.default.removeItem(at: h.storeRoot)
  }

  @Test func filenamePublicationCancellationPreventsPhysicalDispatch() async throws {
    let gate = LeafGate()
    let io = RecordingDestinationIO(beforeLeaf: { if $0 == 1 { gate.hold() } })
    let h = ExportManagerHarness(label: "CancelDuringFilename", destinationIOFactory: { _ in io })
    defer {
      gate.release()
      cleanup(h)
    }
    admit(h)
    try #require(await gate.entered.waitForEnter(count: 1))
    let old = try #require(h.manager.currentTask)
    var cancelled = false
    let probe = ObservationProbe({ _ = h.manager.currentAssetFilename }) {
      guard !cancelled else { return }
      cancelled = true
      h.manager.cancelAndClear()
    }
    defer { probe.stop() }
    gate.release()
    await old.value
    #expect(cancelled)
    #expect(h.writer.writeCalls.isEmpty)
    #expect(h.fileSystem.moveCalls.isEmpty)
    #expect(h.store.exportInfo(assetId: "prepare") == nil)
    #expect(h.dest.beginScopedAccessCount == h.dest.endScopedAccessCount)
  }

  @Test(arguments: [false, true])
  func firstMarkRefusesClaimMadeByFilenameSubscriber(paired: Bool) async throws {
    let gate = LeafGate()
    let io = RecordingDestinationIO(beforeLeaf: { if $0 == 1 { gate.hold() } })
    let h = ExportManagerHarness(label: "FirstMarkClaim", destinationIOFactory: { _ in io })
    defer {
      gate.release()
      cleanup(h)
    }
    admit(h, paired: paired)
    try #require(await gate.entered.waitForEnter(count: 1))
    var claimed = false
    let name = paired ? "IMG_orig.JPG" : "IMG.JPG"
    let probe = ObservationProbe({ _ = h.manager.currentAssetFilename }) {
      guard !claimed else { return }
      claimed = true
      h.store.markVariantExported(
        assetId: "other", variant: .original, year: 2025, month: 4,
        relPath: "2025/04/", filename: name, exportedAt: Date())
    }
    defer { probe.stop() }
    gate.release()
    await h.manager.waitForQueueDrained()
    #expect(claimed)
    #expect(!h.writer.writeCalls.contains { $0.resource.type == .photo })
    #expect(h.store.exportInfo(assetId: "other")?.variants[.original]?.filename == name)
    #expect(h.store.exportInfo(assetId: "prepare")?.variants[.original]?.status == .failed)
    #expect(h.store.exportInfo(assetId: "prepare")?.variants[.original]?.filename != name)
  }

  @Test func remappedMarkRechecksAfterFilenamePublication() async throws {
    let h = ExportManagerHarness(label: "RemappedMarkClaim")
    let written = AsyncCheckpoint()
    h.writer.afterWriteCheckpoint = written
    try await withCleanup {
      admit(h)
      try #require(await written.waitForEnter(count: 1))
      let directory = try h.dest.urlForRelativeDirectory("2025/04/", createIfNeeded: false)
      let planted = directory.appendingPathComponent("IMG.JPG")
      let bytes = Data("planted-after-probe".utf8)
      try bytes.write(to: planted)
      var claimed = false
      let probe = ObservationProbe({ _ = h.manager.currentAssetFilename }) {
        guard !claimed else { return }
        claimed = true
        h.store.markVariantExported(
          assetId: "other", variant: .original, year: 2025, month: 4,
          relPath: "2025/04/", filename: "IMG (1).JPG", exportedAt: Date())
      }
      defer { probe.stop() }
      await written.releaseAll()
      await h.manager.waitForQueueDrained()
      #expect(claimed)
      #expect(try Data(contentsOf: planted) == bytes)
      #expect(h.store.exportInfo(assetId: "other")?.variants[.original]?.filename == "IMG (1).JPG")
      #expect(
        h.store.exportInfo(assetId: "prepare")?.variants[.original]?.filename == "IMG (2).JPG")
      #expect(
        !FileManager.default.fileExists(
          atPath: directory.appendingPathComponent("IMG (1).JPG").path))
    } cleanup: {
      await written.releaseAll()
      cleanup(h)
    }
  }
}
