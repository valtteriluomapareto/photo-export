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
  typealias Fixture = CollectionBackupFixture

  /// A timeline file, an album file for the same asset, a second album, and history that an
  /// import would change: a timeline record and an album record whose files are missing.
  private func makeScenario(
    _ label: String, recordLogIO: any JSONLRecordLogIO = ProductionJSONLRecordLogIO()
  ) throws -> CollectionImportHarness {
    let h = CollectionImportHarness(label, recordLogIO: recordLogIO)
    h.library.collectionTree = [Fixture.album("paris", "Paris"), Fixture.album("rome", "Rome")]
    let both = h.addAsset("both", "IMG_0001.JPG", date: Fixture.date(1))
    let romeOnly = h.addAsset("rome-1", "IMG_0002.JPG", date: Fixture.date(2))
    let month = Calendar.current.dateComponents([.year, .month], from: Fixture.date(1))
    h.library.assetsByYearMonth["\(month.year!)-\(month.month!)"] = [both]
    h.library.assetsByAlbumLocalId["paris"] = [both]
    h.library.assetsByAlbumLocalId["rome"] = [romeOnly]
    let monthPath = "\(month.year!)/" + String(format: "%02d", month.month!) + "/"
    try Fixture.plant(at: h.root, monthPath, "IMG_0001.JPG", date: Fixture.date(1))
    try Fixture.plant(
      at: h.root, "Collections/Albums/Paris/", "IMG_0001.JPG", date: Fixture.date(1))
    try Fixture.plant(at: h.root, "Collections/Albums/Rome/", "IMG_0002.JPG", date: Fixture.date(2))
    try Fixture.plant(at: h.root, "Collections/Albums/Old Trip/", "OLD.JPG", date: Fixture.date(9))

    h.timeline.markVariantExported(
      assetId: "missing", variant: .original, year: 2020, month: 1, relPath: "2020/01/",
      filename: "MISSING.JPG", exportedAt: Fixture.date(5))
    let stale = ExportPlacement(
      kind: .album, id: "collections:album:0000000000000000:00000000", displayName: "Gone",
      collectionLocalIdentifier: "gone", relativePath: "Collections/Albums/Gone/",
      createdAt: Fixture.date(5))
    h.collections.upsertPlacement(stale)
    h.collections.markVariantExported(
      assetId: "missing", placement: stale, variant: .original, filename: "MISSING.JPG",
      exportedAt: Fixture.date(5))
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
    await h.collections.configureAndWait(for: nil)

    await h.importBackup()

    #expect(h.manager.importError == nil)
    #expect(h.timeline.exportInfo(assetId: "both")?.variants[.original]?.status == .done)
    let report = try #require(h.manager.importResult)
    #expect(report.collectionsSkipped)
    #expect(report.collectionMatchedCount == 0)
    #expect(h.library.scopeFetchCalls.isEmpty, "albums are not read when they can't be recorded")
    await h.cleanup()
  }

  /// Reloads one store's history with its snapshot read held, as right after a destination
  /// change, and returns the held snapshot.
  private func reloadHeld(
    _ h: CollectionImportHarness, io: HeldReadIO, collection: Bool
  ) async throws -> URL {
    h.timeline.drainSynchronously()
    h.collections.drainSynchronously()
    let snapshot = h.snapshotURL(collection: collection)
    io.hold(snapshot)
    if collection {
      await h.collections.configureAndWait(for: nil)
      h.collections.beginConfigure(for: h.destinationId)
      try #require(h.collections.state == .loading)
    } else {
      await h.timeline.configureAndWait(for: nil)
      h.timeline.beginConfigure(for: h.destinationId)
      try #require(h.timeline.state == .loading)
    }
    return snapshot
  }

  /// An import started while the album history loads waits for it and adopts the albums.
  @Test func importWaitsForLoadingAlbumHistoryAndAdoptsAlbums() async throws {
    let io = HeldReadIO()
    let h = try makeScenario("CollectionImportAlbumsLoading", recordLogIO: io)
    try await withCleanup {
      let snapshot = try await reloadHeld(h, io: io, collection: true)

      #expect(h.manager.importCoordinator.startImport() == nil)
      #expect(h.manager.isImporting)
      // Keep the history held until the import waits for it, or has run without it.
      #expect(
        await eventually("the import waits for the album history or ends") {
          h.collections.pendingSettleWaiterCount == 1 || !h.manager.isImporting
        })
      io.release(snapshot)
      await h.manager.waitForImportCompletion()

      #expect(h.manager.importError == nil)
      let report = try #require(h.manager.importResult)
      #expect(!report.collectionsSkipped)
      #expect(report.collectionMatchedCount == 2)
      let paris = try #require(
        h.collections.placements.values.first { $0.collectionLocalIdentifier == "paris" })
      #expect(
        h.collections.exportInfo(assetId: "both", placement: paris)?.variants[.original]?.status
          == .done)
    } cleanup: {
      io.releaseAll()
      await h.cleanup()
    }
  }

  /// An import started while the timeline history loads waits for it instead of refusing.
  @Test func importWaitsForLoadingTimelineHistory() async throws {
    let io = HeldReadIO()
    let h = try makeScenario("CollectionImportTimelineLoading", recordLogIO: io)
    try await withCleanup {
      let snapshot = try await reloadHeld(h, io: io, collection: false)

      #expect(h.manager.importCoordinator.startImport() == nil)
      #expect(h.manager.isImporting)
      // Keep the history held until the import waits for it, or has run without it.
      #expect(
        await eventually("the import waits for the timeline history or ends") {
          h.timeline.pendingSettleWaiterCount == 1 || !h.manager.isImporting
        })
      io.release(snapshot)
      await h.manager.waitForImportCompletion()

      #expect(h.manager.importError == nil)
      let report = try #require(h.manager.importResult)
      #expect(report.matchedCount == 1)
      #expect(h.timeline.exportInfo(assetId: "both")?.variants[.original]?.status == .done)
      #expect(h.timeline.exportInfo(assetId: "missing") == nil)
    } cleanup: {
      io.releaseAll()
      await h.cleanup()
    }
  }

  /// A destination change while the import waits for the history abandons the import: nothing
  /// is imported into the new destination's history or reported.
  @Test func destinationChangeWhileWaitingForHistoryAbandonsImport() async throws {
    let io = HeldReadIO()
    let h = try makeScenario("CollectionImportLoadingSwitch", recordLogIO: io)
    try await withCleanup {
      let snapshot = try await reloadHeld(h, io: io, collection: false)

      #expect(h.manager.importCoordinator.startImport() == nil)
      #expect(h.manager.isImporting)
      #expect(
        await eventually("the import waits for the timeline history or ends") {
          h.timeline.pendingSettleWaiterCount == 1 || !h.manager.isImporting
        })
      // The held read blocks the IO queue the switch drains, so release it in the same turn.
      io.release(snapshot)
      await h.timeline.configureAndWait(for: "other")
      await h.collections.configureAndWait(for: "other")
      await h.manager.waitForImportCompletion()

      #expect(!h.manager.isImporting)
      #expect(h.manager.importResult == nil)
      #expect(h.manager.importError == nil)
      #expect(h.timeline.exportInfo(assetId: "both") == nil)
      #expect(h.collections.placements.isEmpty)
    } cleanup: {
      io.releaseAll()
      await h.cleanup()
    }
  }

  enum LoadEnding: CaseIterable, Sendable { case corrupt, unreadable }

  /// A timeline history that ends corrupt or unreadable while an import waits for it ends the
  /// import without running, and says why: a "Same Folder" check could not check the folder,
  /// and a plain import found the export history unavailable.
  @Test(arguments: LoadEnding.allCases, [false, true])
  func importWaitingForHistoryThatFailsToLoadImportsNothing(
    ending: LoadEnding, sameFolder: Bool
  ) async throws {
    let io = HeldReadIO()
    let h = try makeScenario("CollectionImportLoadFails", recordLogIO: io)
    try await withCleanup {
      let snapshot = try await reloadHeld(h, io: io, collection: false)
      let log = snapshot.deletingLastPathComponent()
        .appendingPathComponent(ExportRecordStore.Constants.logFileName)
      let historyBytes = try Data(contentsOf: log)
      // The read is held, so the load reads the files as changed here.
      try? FileManager.default.removeItem(at: snapshot)
      switch ending {
      case .corrupt:
        try Data("corrupt snapshot".utf8).write(to: snapshot)
      case .unreadable:
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: false)
      }

      #expect(
        h.manager.importCoordinator.startImport(requiringPreviousBackup: sameFolder) == nil)
      #expect(h.manager.isImporting)
      #expect(
        await eventually("the import waits for the timeline history or ends") {
          h.timeline.pendingSettleWaiterCount == 1 || !h.manager.isImporting
        })
      io.release(snapshot)
      await h.manager.waitForImportCompletion()

      #expect(h.timeline.state == (ending == .corrupt ? .failed : .persistenceFailed))
      #expect(!h.manager.isImporting)
      #expect(!h.manager.previousBackupMissing)
      #expect(h.manager.importResult == nil)
      #expect(h.manager.importStage == nil)
      #expect(h.collections.placements.values.compactMap(\.collectionLocalIdentifier) == ["gone"])
      #expect(try Data(contentsOf: log) == historyBytes, "the import changed the history")
      let error = try #require(h.manager.importError)
      if sameFolder {
        #expect(error.contains("couldn\u{2019}t check this folder against your export history"))
        #expect(error.contains("Your export history was kept"))
        #expect(!error.contains("while an export is running"))
      } else {
        #expect(error == ImportCoordinator.historyUnavailableMessage)
      }
    } cleanup: {
      io.releaseAll()
      await h.cleanup()
    }
  }

  /// "Same Folder" runs the import against a folder confirmed as the previous backup; album
  /// folders in it are adopted too.
  @Test func sameFolderCheckAdoptsAlbumHistory() async throws {
    let h = try makeScenario("CollectionImportSameFolder")
    let month = Calendar.current.dateComponents([.year, .month], from: Fixture.date(1))
    let monthPath = "\(month.year!)/" + String(format: "%02d", month.month!) + "/"
    h.timeline.markVariantExported(
      assetId: "both", variant: .original, year: month.year!, month: month.month!,
      relPath: monthPath, filename: "IMG_0001.JPG", exportedAt: Fixture.date(1))

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
    let listing = try Fixture.listing(of: h.root)
    let month = Calendar.current.dateComponents([.year, .month], from: Fixture.date(1))

    h.manager.startExportMonth(year: month.year!, month: month.month!)
    await h.manager.waitForQueueDrained()
    h.manager.startExportAlbums(collectionIds: ["paris", "rome"])
    await h.manager.waitForQueueDrained()

    #expect(h.writer.writeCalls.isEmpty)
    #expect(h.fileSystem.copyCalls.isEmpty)
    #expect(h.fileSystem.moveCalls.isEmpty)
    #expect(try Fixture.listing(of: h.root) == listing)
    await h.cleanup()
  }

  /// An album that kept 2 of the 10 photos it was exported with keeps its folder.
  @Test func albumThatLostMostOfItsPhotosKeepsItsFolder() async throws {
    let h = CollectionImportHarness("CollectionImportShrunkAlbum")
    h.library.collectionTree = [Fixture.album("trip", "Trip")]
    var kept: [AssetDescriptor] = []
    for index in 1...10 {
      let asset = h.addAsset("a\(index)", "IMG_\(index).JPG", date: Fixture.date(index))
      if index <= 2 { kept.append(asset) }
      try Fixture.plant(
        at: h.root, "Collections/Albums/Trip/", "IMG_\(index).JPG", date: Fixture.date(index))
    }
    h.library.assetsByAlbumLocalId["trip"] = kept
    let listing = try Fixture.listing(of: h.root)

    await h.importBackup()
    #expect(h.manager.importResult?.collectionMatchedCount == 2)
    #expect(h.manager.importResult?.unrecognizedCollectionFolders == [])
    h.manager.startExportAlbum(collectionId: "trip")
    await h.manager.waitForQueueDrained()

    #expect(h.writer.writeCalls.isEmpty)
    #expect(h.fileSystem.copyCalls.isEmpty)
    #expect(try Fixture.listing(of: h.root) == listing)
    await h.cleanup()
  }

  /// A folder spelled in another case than the album: where the volume ignores case it is the
  /// album's folder and is adopted; where case matters it is not the folder exports use, so it
  /// is not adopted and is reported.
  @Test func caseVariantFolderIsAdoptedOnlyWhereTheVolumeIgnoresCase() async throws {
    let h = CollectionImportHarness("CollectionImportCaseVariant")
    h.library.collectionTree = [Fixture.album("trip", "Trip")]
    let asset = h.addAsset("a1", "IMG_1.JPG", date: Fixture.date(1))
    h.library.assetsByAlbumLocalId["trip"] = [asset]
    try Fixture.plant(at: h.root, "Collections/Albums/trip/", "IMG_1.JPG", date: Fixture.date(1))
    let caseSensitive = try #require(
      try h.root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        .volumeSupportsCaseSensitiveNames)

    await h.importBackup()

    #expect(h.manager.importError == nil)
    #expect(h.manager.importResult?.collectionMatchedCount == (caseSensitive ? 0 : 1))
    #expect(
      h.manager.importResult?.unrecognizedCollectionFolders
        == (caseSensitive ? ["Collections/Albums/trip/"] : []))
    if caseSensitive {
      #expect(h.collections.placements.isEmpty)
    } else {
      let placement = try #require(h.collections.placements.values.first)
      #expect(placement.relativePath == "Collections/Albums/Trip/")
      #expect(
        h.collections.exportInfo(assetId: "a1", placement: placement)?.variants[.original]?
          .status == .done, "the reconcile right after the import keeps the record")
      h.manager.startExportAlbum(collectionId: "trip")
      await h.manager.waitForQueueDrained()
      #expect(h.writer.writeCalls.isEmpty)
    }
    await h.cleanup()
  }

  /// A destination change during the album step invalidates the import without cancelling its
  /// task. The album being fetched is not fingerprinted, no further album is read, and neither
  /// history changes.
  @Test func destinationTeardownDuringAlbumMatchingStopsAlbumReads() async throws {
    let h = try makeScenario("CollectionImportTeardown")
    // An asset only in Paris, so its resources are read only if Paris is fingerprinted.
    let parisOnly = h.addAsset("paris-only", "IMG_0003.JPG", date: Fixture.date(3))
    h.library.assetsByAlbumLocalId["paris", default: []].append(parisOnly)
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
    #expect(h.library.resourcesCallCounts["paris-only"] == nil)
    #expect(h.manager.importResult == nil)
    #expect(h.historyBytes() == before)
    await h.cleanup()
  }
}
