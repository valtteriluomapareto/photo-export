import Foundation
import Testing
import os

@testable import Photo_Export

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct PreparedFilenameClaimsTests {
  private let logger = Logger(subsystem: TestLogging.subsystem, category: "PreparedClaims")

  @Test func preparedClaimsIncludeDeepCollisionAndKeepOwnExclusions() async throws {
    let log = logger
    let prepared = await Task.detached {
      var records: [String: ExportRecord] = [:]
      for index in 0..<500_000 {
        let id = "asset-\(index)"
        records[id] = ExportRecord(
          id: id, year: 2026, month: 10, relPath: "2026/10/",
          variants: [.original: ExportVariantRecord(
            filename: index == 499_999 ? "Caf\u{e9}.JPG" : "\(index).JPG",
            status: .done, exportDate: nil, lastError: nil)])
      }
      let loaded = ExportRecordStore.RecordFile.LoadResult(
        snapshot: records, snapshotStatus: .loaded, ops: [], malformedLineCount: 0,
        ioFailure: nil, needsLogSeparator: false)
      return (ExportRecordStore.prepare(loaded), Thread.isMainThread)
    }.value
    #expect(!prepared.1)
    guard case .loaded(let history) = prepared.0 else { Issue.record("Missing history"); return }
    let folder = ExportRecordStore.ClaimFolder(year: 2026, month: 10, subfolder: nil)
    #expect(history.claims.count("CAFE\u{301}.jpg", in: folder) == 1)
    #expect(history.claims.count("Cafe\u{301}.jpg", in: folder, excluding: [
      (filename: "Caf\u{e9}.JPG", folder: folder)
    ]) == 0)
    _ = log
  }

  @Test func seededIncrementalChangesMatchIndependentReference() async throws {
    var random: UInt64 = 0x455
    func next() -> UInt64 { random = random &* 6364136223846793005 &+ 1; return random }
    let root = TestScratch.directory("PreparedClaimsEquivalence")
    let timeline = ExportRecordStore(baseDirectoryURL: root)
    let collections = CollectionExportRecordStore(baseDirectoryURL: root)
    timeline.configure(for: "A")
    collections.configure(for: "A")
    let placement = ExportPlacement.favorites()
    collections.upsertPlacement(placement)
    var expected: [String: String] = [:]
    let names = ["A.JPG", "a.jpg", "Caf\u{e9}.JPG", "CAFE\u{301}.jpg", "other.JPG"]
    for _ in 0..<300 {
      let id = "asset-\(next() % 17)"
      if next() % 4 == 0 {
        timeline.removeVariant(assetId: id, variant: .original)
        collections.removeVariant(assetId: id, placement: placement, variant: .original)
        expected.removeValue(forKey: id)
      } else {
        let name = names[Int(next() % UInt64(names.count))]
        expected[id] = name
        timeline.markVariantInProgress(
          assetId: id, variant: .original, year: 2026, month: 10, relPath: "2026/10/", filename: name)
        collections.markVariantInProgress(
          assetId: id, placement: placement, variant: .original, filename: name)
      }
      for name in names {
        let own = "asset-0"
        let wanted = expected.contains { id, value in
          id != own && value.precomposedStringWithCanonicalMapping.lowercased()
            == name.precomposedStringWithCanonicalMapping.lowercased()
        }
        #expect(timeline.isFilenameClaimed(
          name, year: 2026, month: 10, subfolder: nil, exceptAsset: own) == wanted)
        #expect(collections.isFilenameClaimed(
          name, placement: placement, subfolder: nil, exceptAsset: own) == wanted)
      }
    }
    try await timeline.flush()
    try await collections.flush()
    timeline.beginConfigure(for: "A")
    collections.beginConfigure(for: "A")
    await timeline.waitUntilSettled()
    await collections.waitUntilSettled()
    #expect(timeline.claimsEpoch == timeline.recordsEpoch)
    #expect(collections.claimsEpoch == collections.recordsEpoch)
    timeline.drainSynchronously()
    collections.drainSynchronously()
    try? FileManager.default.removeItem(at: root)
  }

  @Test(arguments: [false, true])
  func preparedIndexLoadsOffMainAndCannotOutliveNewHistory(collection: Bool) async throws {
    let root = TestScratch.directory("PreparedClaimsOwnership")
    let gate = AsyncCheckpoint()
    let threads = LockedBox<[Bool]>([])
    let timeline = ExportRecordStore(baseDirectoryURL: root)
    let collections = CollectionExportRecordStore(baseDirectoryURL: root)
    if collection {
      collections.preparationCheckpoint = { threads.mutate { $0.append(Thread.isMainThread) }; await gate.enter() }
      collections.beginConfigure(for: "A")
    } else {
      timeline.preparationCheckpoint = { threads.mutate { $0.append(Thread.isMainThread) }; await gate.enter() }
      timeline.beginConfigure(for: "A")
    }
    await gate.waitForEnter(count: 1)
    #expect((collection ? collections.state : timeline.state) == .loading)
    if collection {
      collections.configure(for: nil)
    } else {
      timeline.configure(for: nil)
    }
    await gate.releaseAll()
    try #require(await eventually("obsolete preparation discarded") {
      collection ? collections.finishedLoadCount > 0 : timeline.finishedLoadCount > 0
    })
    #expect(threads.value == [false])
    #expect((collection ? collections.state : timeline.state) == .unconfigured)
    #expect(collection ? collections.claimsEpoch == collections.recordsEpoch : timeline.claimsEpoch == timeline.recordsEpoch)
    try? FileManager.default.removeItem(at: root)
  }
}
