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

  /// After the import, exporting the month and both albums again writes nothing, and the
  /// album export doesn't copy the timeline file either.
  @Test func exportingTheTimelineAndAlbumsAgainWritesNothing() async throws {
    let h = try makeScenario("CollectionImportReexport")
    await h.importBackup()
    try #require(h.manager.importError == nil)
    let listing = try F.listing(of: h.root)
    let month = Calendar.current.dateComponents([.year, .month], from: F.date(1))

    h.manager.startExportMonth(year: month.year!, month: month.month!)
    await h.manager.waitForQueueDrained()
    h.manager.startExportAlbums(collectionIds: ["paris", "rome"])
    await h.manager.waitForQueueDrained()

    #expect(h.writer.writeCalls.isEmpty)
    #expect(h.fileSystem.copyCalls.isEmpty)
    #expect(h.fileSystem.moveCalls.isEmpty)
    #expect(try F.listing(of: h.root) == listing)
    await h.cleanup()
  }

  /// An album that kept 2 of the 10 photos it was exported with keeps its folder.
  @Test func albumThatLostMostOfItsPhotosKeepsItsFolder() async throws {
    let h = CollectionImportHarness("CollectionImportShrunkAlbum")
    h.library.collectionTree = [F.album("trip", "Trip")]
    var kept: [AssetDescriptor] = []
    for index in 1...10 {
      let asset = h.addAsset("a\(index)", "IMG_\(index).JPG", date: F.date(index))
      if index <= 2 { kept.append(asset) }
      try F.plant(at: h.root, "Collections/Albums/Trip/", "IMG_\(index).JPG", date: F.date(index))
    }
    h.library.assetsByAlbumLocalId["trip"] = kept
    let listing = try F.listing(of: h.root)

    await h.importBackup()
    #expect(h.manager.importResult?.collectionMatchedCount == 2)
    #expect(h.manager.importResult?.unrecognizedCollectionFolders == [])
    h.manager.startExportAlbum(collectionId: "trip")
    await h.manager.waitForQueueDrained()

    #expect(h.writer.writeCalls.isEmpty)
    #expect(h.fileSystem.copyCalls.isEmpty)
    #expect(try F.listing(of: h.root) == listing)
    await h.cleanup()
  }

  /// A folder spelled in another case than the album: where the volume ignores case it is the
  /// album's folder and the reconcile right after the import keeps its records; where case
  /// matters it is another folder, and the reconcile drops them so the album exports again.
  @Test func caseVariantFolderIsKeptOnlyWhereTheVolumeIgnoresCase() async throws {
    let h = CollectionImportHarness("CollectionImportCaseVariant")
    h.library.collectionTree = [F.album("trip", "Trip")]
    let asset = h.addAsset("a1", "IMG_1.JPG", date: F.date(1))
    h.library.assetsByAlbumLocalId["trip"] = [asset]
    try F.plant(at: h.root, "Collections/Albums/trip/", "IMG_1.JPG", date: F.date(1))
    let caseSensitive = try #require(
      try h.root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        .volumeSupportsCaseSensitiveNames)

    await h.importBackup()

    #expect(h.manager.importError == nil)
    let placement = try #require(h.collections.placements.values.first)
    #expect(placement.relativePath == "Collections/Albums/Trip/")
    let recorded = h.collections.exportInfo(assetId: "a1", placement: placement)?
      .variants[.original]?.status == .done
    #expect(recorded == !caseSensitive)
    if !caseSensitive {
      h.manager.startExportAlbum(collectionId: "trip")
      await h.manager.waitForQueueDrained()
      #expect(h.writer.writeCalls.isEmpty)
    }
    await h.cleanup()
  }

  /// A destination change during the album step invalidates the import without cancelling its
  /// task; no further album is read and neither history changes.
  @Test func destinationTeardownDuringAlbumMatchingStopsAlbumReads() async throws {
    let h = try makeScenario("CollectionImportTeardown")
    let gate = AsyncCheckpoint()
    h.library.fetchAssetsCheckpointByAlbumId["paris"] = gate
    let before = h.historyBytes()

    h.manager.startImport()
    let task = try #require(h.manager.importTask)
    #expect(await gate.waitForEnter(count: 1))
    h.manager.cancelAndClear()
    await gate.releaseAll()
    _ = await finished(task)

    #expect(h.library.scopeFetchCalls == [.album(collectionId: "paris")])
    #expect(h.manager.importResult == nil)
    #expect(h.historyBytes() == before)
    await h.cleanup()
  }
}
