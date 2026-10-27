import Foundation
import Synchronization
import Testing

@testable import Photo_Export

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct ExportMeasurementsTests {
  private final class Clock: Sendable {
    private let value = Mutex<UInt64>(1)
    nonisolated func now() -> UInt64 { value.withLock { $0 } }
    nonisolated func advance(_ amount: UInt64) { value.withLock { $0 += amount } }
  }
  @MainActor
  private final class Capture {
    let clock = Clock()
    var events: [[String: Any]] = []
    lazy var measurements = ExportMeasurements(
      session: UUID().uuidString, now: { [clock] in clock.now() },
      emit: { [weak self] message in
        let data = Data(message.dropFirst("MEASURE ".count).utf8)
        self?.events.append(try! JSONSerialization.jsonObject(with: data) as! [String: Any])
      })
    func rows(_ type: String) -> [[String: Any]] { events.filter { $0["type"] as? String == type } }
  }

  @Test func sealedRunIncludesLastJobAndDeduplicatesAssetOrdinals() throws {
    let c = Capture()
    let m = c.measurements
    m.beginRun()
    m.enqueued(2)
    let first = try #require(m.beginJob(assetId: "private-asset"))
    let stage = first.beginStage()
    c.clock.advance(60)
    stage?.finish()
    first.committed()
    first.committed()
    c.clock.advance(40)
    m.endJob(first)
    let second = try #require(m.beginJob(assetId: "private-asset"))
    c.clock.advance(100)
    second.committed()
    m.endJob(second)
    m.endRun()
    let jobs = c.rows("jobEnd")
    #expect(jobs.count == 2)
    #expect(jobs[0]["stageNs"] as? UInt64 == 60)
    #expect(jobs[0]["wallNs"] as? UInt64 == 100)
    #expect(jobs[1]["stageNs"] as? UInt64 == 0)
    #expect(Set(c.rows("completion").compactMap { $0["asset"] as? Int }).count == 1)
    #expect(c.rows("runEnd").last?["valid"] as? Bool == true)
    let sequence = c.events.compactMap { $0["seq"] as? Int }
    #expect(sequence == Array(1...sequence.count))
    #expect(!String(describing: c.events).contains("private-asset"))
  }

  @Test(arguments: ["paused", "pending-cleared", "cancelled", "scan-failed", "variant-failed"])
  func invalidationIsStickyAcrossBalancedCounters(reason: String) throws {
    let c = Capture()
    let m = c.measurements
    m.beginRun()
    m.enqueued(1)
    let job = try #require(m.beginJob(assetId: "A"))
    m.invalidate(reason)
    c.clock.advance(100)
    job.committed()
    m.endJob(job)
    m.endRun()
    #expect(c.rows("runEnd").last?["valid"] as? Bool == false)
    #expect(c.rows("runEnd").last?["reason"] as? String == reason)
  }

  @Test func lateOldTokensCannotWriteIntoReplacementRun() throws {
    let c = Capture()
    let m = c.measurements
    m.beginRun()
    m.enqueued(1)
    let old = try #require(m.beginJob(assetId: "old"))
    let stage = old.beginStage()
    m.invalidate("cancelled")
    m.endRun()
    m.beginRun()
    m.enqueued(1)
    let current = try #require(m.beginJob(assetId: "current"))
    let baseline = c.events.count
    c.clock.advance(100)
    stage?.finish()
    old.committed()
    m.endJob(old)
    #expect(c.events.count == baseline)
    current.committed()
    m.endJob(current)
    m.endRun()
    #expect(c.rows("completion").count == 1)
    #expect(c.rows("runEnd").last?["valid"] as? Bool == true)
  }

  @Test func noSessionMeansNoRecorderOrClockOrSink() {
    #expect(ExportMeasurements.session(arguments: []) == nil)
    #expect(ExportMeasurements.session(arguments: ["--export-measurements", "garbage"]) == nil)
    let id = UUID().uuidString
    #expect(ExportMeasurements.session(arguments: ["--export-measurements", id]) == id)
    #expect(ExportMeasurements.fromArguments([]) == nil)
  }

  @Test func actualExportTimesWriterAndExcludesFinalTimestampWork() async throws {
    let c = Capture()
    let defaults = TestScratch.defaults("ExportMeasurements")
    let photoLib = FakePhotoLibraryService()
    let asset = TestAssetFactory.makeAsset(
      id: "measurement-asset",
      creationDate: Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 15)))
    photoLib.assetsByYearMonth["2026-1"] = [asset]
    photoLib.resourcesByAssetId[asset.id] = [
      ResourceDescriptor(type: .photo, originalFilename: "photo.JPG", fileSize: 12)
    ]
    let writer = FakeAssetResourceWriter()
    let clock = c.clock
    writer.writeHook = { _ in clock.advance(60) }
    let fs = FakeFileSystem()
    fs.afterTimestampsHook = { _ in clock.advance(40) }
    let h = ExportManagerHarness(
      label: "ExportMeasurements", userDefaults: defaults, photoLib: photoLib,
      writer: writer, fileSystem: fs, exportMeasurements: c.measurements)
    defer {
      h.manager.cancelAndClear()
      h.store.drainSynchronously()
      h.collectionStore.drainSynchronously()
      h.dest.cleanup()
      try? FileManager.default.removeItem(at: h.storeRoot)
    }
    h.manager.versionSelection = .edited
    h.manager.startExportMonth(year: 2026, month: 1)
    await h.manager.waitForQueueDrained()
    #expect(c.rows("jobEnd").count == 1)
    let job = try #require(c.rows("jobEnd").first)
    #expect(job["stageNs"] as? UInt64 == 60)
    #expect(job["wallNs"] as? UInt64 == 100)
    #expect(c.rows("completion").count == 1)
    #expect(c.rows("runEnd").last?["valid"] as? Bool == true)
  }
  private struct TimedConverter: ImageConverter {
    let clock: Clock
    func convertHEIC(at sourceURL: URL, to destURL: URL, quality: Double) async throws {
      clock.advance(20)
      try Data("jpeg".utf8).write(to: destURL)
    }
  }

  @Test(arguments: ["heic", "render", "reuse-fallback"])
  func actualProducerLegsAreTimedButRepairAndCleanupAreNot(route: String) async throws {
    let c = Capture()
    let clock = c.clock
    let photos = FakePhotoLibraryService()
    let date = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 15))
    let asset = TestAssetFactory.makeAsset(
      id: "producer", creationDate: date, mediaType: route == "render" ? .video : .image,
      hasAdjustments: route == "render", originalUTI: route == "heic" ? "public.heic" : nil)
    photos.assetsByYearMonth["2026-1"] = [asset]
    photos.favoritesAssets = [asset]
    photos.resourcesByAssetId[asset.id] = [
      .init(type: route == "render" ? .video : .photo,
            originalFilename: route == "heic" ? "IMG.HEIC" : "IMG.JPG", fileSize: 12)
    ]
    let writer = FakeAssetResourceWriter()
    writer.writeHook = { _ in clock.advance(60) }
    let renderer = FakeMediaRenderer()
    renderer.fileWriter = { url in
      clock.advance(70)
      try? Data("rendered".utf8).write(to: url)
    }
    let files = FakeFileSystem()
    files.afterTimestampsHook = { _ in clock.advance(40) }
    files.copyHook = { _, _ in clock.advance(20) }
    let io = RecordingDestinationIO(beforeLeaf: { _ in
      // Utility work outside producers, including directory repair and cleanup, remains job overhead.
      if route == "heic" { clock.advance(10) }
    })
    let h = ExportManagerHarness(
      label: "ProducerMeasurements", photoLib: photos, writer: writer, fileSystem: files,
      mediaRenderer: renderer, imageConverter: TimedConverter(clock: clock),
      exportMeasurements: c.measurements, destinationIOFactory: { _ in io })
    defer {
      h.manager.cancelAndClear()
      h.store.drainSynchronously()
      h.collectionStore.drainSynchronously()
      h.dest.cleanup()
      try? FileManager.default.removeItem(at: h.storeRoot)
    }
    h.manager.convertHEICToJPEG = route == "heic"
    if route == "reuse-fallback" {
      // The missing old file forces a failed copy attempt followed by resource production.
      _ = try h.dest.urlForRelativeDirectory("2026/01/", createIfNeeded: true)
      h.store.markVariantExported(
        assetId: asset.id, variant: .original, year: 2026, month: 1, relPath: "2026/01/",
        filename: "missing.JPG", exportedAt: Date())
      h.manager.startExportFavorites()
    } else {
      h.manager.startExportMonth(year: 2026, month: 1)
    }
    await h.manager.waitForQueueDrained()
    let job = try #require(c.rows("jobEnd").first)
    let expected: UInt64 = route == "render" ? 70 : 80
    #expect(job["stageNs"] as? UInt64 == expected)
    #expect((job["wallNs"] as? UInt64 ?? 0) >= expected + 40)
    #expect(c.rows("completion").count == 1)
    #expect(c.rows("runEnd").last?["valid"] as? Bool == true)
  }

}
