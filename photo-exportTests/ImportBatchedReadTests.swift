import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Import Existing Backup reads months and albums that can arrive in several batches. Matching
/// sees every batch, and cancelling the import between batches leaves both histories as they
/// were.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct ImportBatchedReadTests {
  typealias Fixture = CollectionBackupFixture

  /// Two assets in one month and in the Paris album, each planted in the month folder and in
  /// the album folder.
  private struct Scenario {
    let harness: CollectionImportHarness
    let month: PhotoFetchScope
    let monthPath: String
    let assets: [AssetDescriptor]

    static let album = PhotoFetchScope.album(collectionId: "paris")
    static let albumPath = "Collections/Albums/Paris/"
  }

  private func makeScenario(_ label: String) async throws -> Scenario {
    let h = await CollectionImportHarness(label)
    h.library.collectionTree = [Fixture.album("paris", "Paris")]
    let assets = [
      h.addAsset("first", "IMG_0001.JPG", date: Fixture.date(1)),
      h.addAsset("second", "IMG_0002.JPG", date: Fixture.date(2)),
    ]
    let month = Calendar.current.dateComponents([.year, .month], from: Fixture.date(1))
    h.library.assetsByYearMonth["\(month.year!)-\(month.month!)"] = assets
    h.library.assetsByAlbumLocalId["paris"] = assets
    let monthPath = "\(month.year!)/" + String(format: "%02d", month.month!) + "/"
    for (index, asset) in assets.enumerated() {
      let filename = "IMG_000\(index + 1).JPG"
      for path in [monthPath, Scenario.albumPath] {
        try Fixture.plant(at: h.root, path, filename, date: asset.creationDate!)
      }
    }
    return Scenario(
      harness: h, month: .timeline(year: month.year!, month: month.month!),
      monthPath: monthPath, assets: assets)
  }

  /// Every adopted original as "<asset> in <folder>", from both histories.
  private func adopted(_ s: Scenario) -> Set<String> {
    let h = s.harness
    var result: Set<String> = []
    for asset in s.assets {
      if let record = h.timeline.exportInfo(assetId: asset.id),
        record.variants[.original]?.status == .done
      {
        result.insert("\(asset.id) in \(record.relPath)")
      }
      for placement in h.collections.placements.values
      where h.collections.exportInfo(assetId: asset.id, placement: placement)?
        .variants[.original]?.status == .done
      {
        result.insert("\(asset.id) in \(placement.relativePath)")
      }
    }
    return result
  }

  @Test func monthAndAlbumReadInTwoBatchesMatchTheSameFiles() async throws {
    let s = try await makeScenario("ImportBatchedReads")
    let h = s.harness

    await h.importBackup()
    let single = adopted(s)
    let all = Set(
      s.assets.flatMap { ["\($0.id) in \(s.monthPath)", "\($0.id) in \(Scenario.albumPath)"] })
    #expect(single == all, "the one-batch import is the positive control")

    await h.wipeHistory()
    h.library.progressiveStreamOverride = { scope in
      guard scope == s.month || scope == Scenario.album else { return nil }
      return AsyncThrowingStream { continuation in
        for asset in s.assets { continuation.yield([asset]) }
        continuation.finish()
      }
    }
    await h.importBackup()

    #expect(h.manager.importError == nil)
    #expect(adopted(s) == single)
    let report = try #require(h.manager.importResult)
    #expect(report.matchedCount == 2)
    #expect(report.collectionMatchedCount == 2)
    await h.cleanup()
  }

  enum HeldRead: CaseIterable { case month, album }

  @Test(arguments: HeldRead.allCases)
  func cancellingAfterTheFirstBatchLeavesBothHistoriesUnchanged(held: HeldRead) async throws {
    let s = try await makeScenario("ImportBatchedCancel")
    let h = s.harness
    let scope = held == .month ? s.month : Scenario.album
    let gate = AsyncCheckpoint()
    // A batched read holds after its first batch.
    h.library.progressiveStreamOverride = { requested in
      guard requested == scope else { return nil }
      return AsyncThrowingStream { continuation in
        let task = Task {
          continuation.yield([s.assets[0]])
          await gate.enter()
          continuation.yield([s.assets[1]])
          continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
      }
    }
    // A whole-scope read holds before it returns.
    switch scope {
    case .timeline(let year, _): h.library.fetchAssetsCheckpointByYear[year] = gate
    default: h.library.fetchAssetsCheckpointByAlbumId["paris"] = gate
    }
    let before = h.historyBytes()

    h.manager.startImport()
    let task = try #require(h.manager.importTask)
    #expect(await gate.waitForEnter(count: 1))
    h.manager.cancelImport()
    await gate.releaseAll()
    _ = await finished(task)

    #expect(!h.manager.isImporting)
    #expect(h.manager.importError == nil)
    #expect(h.manager.importResult == nil)
    #expect(h.historyBytes() == before)
    #expect(adopted(s).isEmpty)
    await h.cleanup()
  }
}
