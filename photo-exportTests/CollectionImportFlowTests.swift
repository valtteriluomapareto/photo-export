import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Import Existing Backup's album step inside the whole import: failures leave both histories
/// as they were, a missing album history only skips albums, and one asset can be adopted into
/// the timeline and an album.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct CollectionImportFlowTests {
  typealias F = CollectionBackupFixture

  /// A timeline file, an album file for the same asset, a second album, and history that an
  /// import would change: a timeline record and an album record whose files are missing.
  private func makeScenario(_ label: String) throws -> CollectionImportHarness {
    let h = CollectionImportHarness(label)
    h.library.collectionTree = [F.album("paris", "Paris"), F.album("rome", "Rome")]
    let both = h.addAsset("both", "IMG_0001.JPG", date: F.date(1))
    let romeOnly = h.addAsset("rome-1", "IMG_0002.JPG", date: F.date(2))
    let month = Calendar.current.dateComponents([.year, .month], from: F.date(1))
    h.library.assetsByYearMonth["\(month.year!)-\(month.month!)"] = [both]
    h.library.assetsByAlbumLocalId["paris"] = [both]
    h.library.assetsByAlbumLocalId["rome"] = [romeOnly]
    let monthPath = "\(month.year!)/" + String(format: "%02d", month.month!) + "/"
    try F.plant(at: h.root, monthPath, "IMG_0001.JPG", date: F.date(1))
    try F.plant(at: h.root, "Collections/Albums/Paris/", "IMG_0001.JPG", date: F.date(1))
    try F.plant(at: h.root, "Collections/Albums/Rome/", "IMG_0002.JPG", date: F.date(2))
    try F.plant(at: h.root, "Collections/Albums/Old Trip/", "OLD.JPG", date: F.date(9))

    h.timeline.markVariantExported(
      assetId: "missing", variant: .original, year: 2020, month: 1, relPath: "2020/01/",
      filename: "MISSING.JPG", exportedAt: F.date(5))
    let stale = ExportPlacement(
      kind: .album, id: "collections:album:0000000000000000:00000000", displayName: "Gone",
      collectionLocalIdentifier: "gone", relativePath: "Collections/Albums/Gone/",
      createdAt: F.date(5))
    h.collections.upsertPlacement(stale)
    h.collections.markVariantExported(
      assetId: "missing", placement: stale, variant: .original, filename: "MISSING.JPG",
      exportedAt: F.date(5))
    return h
  }

  @Test func importAdoptsAnAssetIntoBothTheTimelineAndItsAlbum() async throws {
    let h = try makeScenario("CollectionImportBoth")
    await h.importBackup()

    #expect(h.manager.importError == nil)
    #expect(h.timeline.exportInfo(assetId: "both")?.variants[.original]?.status == .done)
    let paris = try #require(
      h.collections.placements.values.first { $0.collectionLocalIdentifier == "paris" })
    #expect(
      h.collections.exportInfo(assetId: "both", placement: paris)?.variants[.original]?.status
        == .done)
    #expect(h.library.resourcesCallCounts["both"] == 1, "one fingerprint per asset per import")
    let report = try #require(h.manager.importResult)
    #expect(report.matchedCount == 1)
    #expect(report.totalScanned == 1)
    #expect(report.collectionFilesScanned == 3)
    #expect(report.collectionMatchedCount == 2)
    #expect(report.collectionUnmatchedCount == 1)
    #expect(report.unrecognizedCollectionFolders == ["Collections/Albums/Old Trip/"])
    #expect(!report.collectionsSkipped)
    #expect(report.prunedRecords == 2, "both missing-file records are pruned after adoption")
    await h.cleanup()
  }

  @Test func albumTreeFailureLeavesBothHistoriesUnchanged() async throws {
    let h = try makeScenario("CollectionImportTreeFailure")
    h.library.collectionTreeError = CocoaError(.fileReadUnknown)
    let before = h.historyBytes()

    await h.importBackup()

    #expect(h.manager.importError != nil)
    #expect(h.manager.importResult == nil)
    #expect(h.historyBytes() == before)
    #expect(h.timeline.exportInfo(assetId: "both") == nil)
    #expect(h.timeline.exportInfo(assetId: "missing") != nil)
    await h.cleanup()
  }

  @Test func albumFetchFailureFailsTheImportWithoutChanges() async throws {
    let h = try makeScenario("CollectionImportAlbumFailure")
    h.library.fetchAssetsErrorByAlbumId["rome"] = CocoaError(.fileReadUnknown)
    let before = h.historyBytes()

    await h.importBackup()

    #expect(h.manager.importError != nil)
    #expect(h.manager.importResult == nil)
    #expect(h.historyBytes() == before)
    #expect(h.collections.placements.values.allSatisfy { $0.collectionLocalIdentifier == "gone" })
    await h.cleanup()
  }

  @Test func cancellingDuringAlbumMatchingLeavesBothHistoriesUnchanged() async throws {
    let h = try makeScenario("CollectionImportCancel")
    let gate = AsyncCheckpoint()
    h.library.fetchAssetsCheckpointByAlbumId["paris"] = gate
    h.library.fetchAssetsCheckpointByAlbumId["rome"] = gate
    let before = h.historyBytes()

    h.manager.startImport()
    let task = try #require(h.manager.importTask)
    #expect(await gate.waitForEnter(count: 1))
    h.manager.cancelImport()
    await gate.releaseAll()
    _ = await finished(task)

    #expect(!h.manager.isImporting)
    #expect(h.manager.importResult == nil)
    #expect(h.historyBytes() == before)
    await h.cleanup()
  }

  @Test func albumHistoryNotReadySkipsAlbumsAndImportsTheTimeline() async throws {
    let h = try makeScenario("CollectionImportNotReady")
    h.collections.configure(for: nil)

    await h.importBackup()

    #expect(h.manager.importError == nil)
    #expect(h.timeline.exportInfo(assetId: "both")?.variants[.original]?.status == .done)
    let report = try #require(h.manager.importResult)
    #expect(report.collectionsSkipped)
    #expect(report.collectionMatchedCount == 0)
    #expect(h.library.scopeFetchCalls.isEmpty, "albums are not read when they can't be recorded")
    await h.cleanup()
  }

  /// "Same Folder" runs the import against a folder confirmed as the previous backup; album
  /// folders in it are adopted too.
  @Test func sameFolderCheckAdoptsAlbumHistory() async throws {
    let h = try makeScenario("CollectionImportSameFolder")
    let month = Calendar.current.dateComponents([.year, .month], from: F.date(1))
    let monthPath = "\(month.year!)/" + String(format: "%02d", month.month!) + "/"
    h.timeline.markVariantExported(
      assetId: "both", variant: .original, year: month.year!, month: month.month!,
      relPath: monthPath, filename: "IMG_0001.JPG", exportedAt: F.date(1))

    h.manager.startImportForConfirmedSameFolder()
    await h.manager.waitForImportCompletion()

    #expect(!h.manager.previousBackupMissing)
    #expect(h.manager.importError == nil)
    let adopted = Set(h.collections.placements.values.compactMap(\.collectionLocalIdentifier))
    #expect(adopted == ["paris", "rome", "gone"])
    await h.cleanup()
  }
}
