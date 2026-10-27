import Combine
import Foundation
import Testing

@testable import Photo_Export

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct RecordStoreNotificationTests {
  @MainActor
  private final class Fixture {
    let root = TestScratch.directory("RecordStoreNotification")
    let clock = TestClock()
    let timeline: ExportRecordStore
    let collections: CollectionExportRecordStore
    let placement = ExportPlacement.favorites()
    let collection: Bool

    init(collection: Bool) async {
      self.collection = collection
      timeline = ExportRecordStore(baseDirectoryURL: root, notificationClock: clock)
      collections = CollectionExportRecordStore(baseDirectoryURL: root, notificationClock: clock)
      await timeline.configureAndWait(for: "A")
      await collections.configureAndWait(for: "A")
      collections.upsertPlacement(placement)
      clock.advance(by: 0.201)
    }

    var counter: Int { collection ? collections.mutationCounter : timeline.mutationCounter }

    func write(_ id: String) {
      if collection {
        collections.markVariantInProgress(
          assetId: id, placement: placement, variant: .original, filename: "\(id).JPG")
      } else {
        timeline.markVariantInProgress(
          assetId: id, variant: .original, year: 2026, month: 9,
          relPath: "2026/09/", filename: "\(id).JPG")
      }
    }

    func record(_ id: String) -> ExportVariantRecord? {
      if collection {
        return collections.exportInfo(assetId: id, placement: placement)?.variants[.original]
      }
      return timeline.exportInfo(assetId: id)?.variants[.original]
    }

    func flushNotifications() {
      if collection {
        collections.flushPendingNotifications()
      } else {
        timeline.flushPendingNotifications()
      }
    }

    func close() async {
      try? await timeline.flush()
      try? await collections.flush()
      try? FileManager.default.removeItem(at: root)
    }
  }

  @Test(arguments: [false, true])
  func sustainedMutationsPublishCurrentRecordsDuringTheStream(collection: Bool) async {
    let f = await Fixture(collection: collection)
    var latestID = ""
    var delivered: [(Date, String)] = []
    var oldestPending: Date?
    let observation = ObservationProbe(
      { _ = f.counter },
      onChange: {
        #expect(f.record(latestID)?.status == .inProgress)
        #expect(oldestPending.map { f.clock.now().timeIntervalSince($0) <= 0.201 } == true)
        oldestPending = nil
        delivered.append((f.clock.now(), latestID))
      })
    let start = f.clock.now()
    for index in 0..<20 {
      latestID = "asset-\(index)"
      if oldestPending == nil { oldestPending = f.clock.now() }
      f.write(latestID)
      f.clock.advance(by: 0.05)
    }
    #expect(delivered.count >= 4)
    #expect(delivered.first.map { $0.0.timeIntervalSince(start) <= 0.201 } == true)
    #expect(delivered.contains { $0.1 != latestID })
    f.clock.advance(by: 0.201)
    #expect(delivered.last?.1 == latestID)
    withExtendedLifetime(observation) {}
    await f.close()
  }

  @Test(arguments: [false, true])
  func burstsCoalesceAndFinalPhaseOffsetMutationIsDelivered(collection: Bool) async {
    let f = await Fixture(collection: collection)
    let baseline = f.counter
    for index in 0..<5 { f.write("burst-\(index)") }
    f.clock.advance(by: 0.199)
    #expect(f.counter == baseline)
    f.clock.advance(by: 0.002)
    #expect(f.counter == baseline + 1)
    f.clock.advance(by: 0.035)
    f.write("last")
    f.clock.advance(by: 0.199)
    #expect(f.counter == baseline + 1)
    f.clock.advance(by: 0.002)
    #expect(f.counter == baseline + 2)
    #expect(f.record("last")?.status == .inProgress)
    f.clock.advance(by: 1)
    #expect(f.counter == baseline + 2)
    await f.close()
  }

  @Test(arguments: [false, true])
  func subscriberMutationOpensTheNextWindow(collection: Bool) async {
    let f = await Fixture(collection: collection)
    let baseline = f.counter
    var delivered = 0
    let observation = ObservationProbe(
      { _ = f.counter },
      onChange: {
        delivered += 1
        if delivered == 1 { f.write("reentrant") }
      })
    f.write("first")
    f.clock.advance(by: 0.201)
    #expect(f.counter == baseline + 1)
    #expect(f.record("reentrant")?.status == .inProgress)
    f.clock.advance(by: 0.201)
    #expect(f.counter == baseline + 2)
    withExtendedLifetime(observation) {}
    await f.close()
  }

  @Test(arguments: [false, true])
  func durabilityBarrierDoesNotPublishUIChanges(collection: Bool) async throws {
    let f = await Fixture(collection: collection)
    let baseline = f.counter
    f.write("pending")
    try await f.timeline.flush()
    try await f.collections.flush()
    #expect(f.counter == baseline)
    f.clock.advance(by: 0.201)
    #expect(f.counter == baseline + 1)
    await f.close()
  }

  @Test(arguments: [false, true])
  func terminalFlushIsIdempotentAndPreservesSubscriberMutation(collection: Bool) async {
    let f = await Fixture(collection: collection)
    let baseline = f.counter
    var delivered = 0
    let observation = ObservationProbe(
      { _ = f.counter },
      onChange: {
        delivered += 1
        if delivered == 1 { f.write("reentrant") }
      })
    f.flushNotifications()
    #expect(f.counter == baseline)
    f.write("first")
    f.flushNotifications()
    #expect(f.counter == baseline + 1)
    f.clock.advance(by: 0.201)
    #expect(f.counter == baseline + 2)
    #expect(f.record("reentrant")?.status == .inProgress)
    f.flushNotifications()
    #expect(f.counter == baseline + 2)
    withExtendedLifetime(observation) {}
    await f.close()
  }

  @Test(arguments: [false, true])
  func corruptionAndResetImmediatePublicationsReplacePendingWindow(collection: Bool) async throws {
    let f = await Fixture(collection: collection)
    f.write("old")
    try await f.timeline.flush()
    try await f.collections.flush()
    let name = collection ? "collection-records.json" : "export-records.json"
    try Data("invalid snapshot".utf8).write(
      to: f.root.appendingPathComponent("A").appendingPathComponent(name))
    let baseline = f.counter
    if collection {
      await f.collections.configureAndWait(for: "A")
    } else {
      await f.timeline.configureAndWait(for: "A")
    }
    #expect(f.counter == baseline + 2)
    if collection {
      #expect(f.collections.state == .failed)
      await f.collections.resetHistory()
      #expect(f.collections.state == .ready)
    } else {
      #expect(f.timeline.state == .failed)
      await f.timeline.resetHistory()
      #expect(f.timeline.state == .ready)
    }
    #expect(f.counter == baseline + 3)
    #expect(f.record("old") == nil)
    f.clock.advance(by: 1)
    #expect(f.counter == baseline + 3)
    await f.close()
  }

  @Test(arguments: [false, true], [false, true])
  func immediateDestinationPublicationCancelsOldWindow(collection: Bool, clear: Bool) async throws {
    let f = await Fixture(collection: collection)
    f.write("old")
    try await f.timeline.flush()
    try await f.collections.flush()
    let baseline = f.counter
    if collection {
      await f.collections.configureAndWait(for: clear ? nil : "B")
    } else {
      await f.timeline.configureAndWait(for: clear ? nil : "B")
    }
    #expect(f.counter == baseline + (clear ? 1 : 2))
    #expect(f.record("old") == nil)
    f.clock.advance(by: 1)
    #expect(f.counter == baseline + (clear ? 1 : 2))
    await f.close()
  }

  @Test(arguments: [false, true], [false, true])
  func exportTerminalTransitionsPublishPendingChanges(collection: Bool, cancel: Bool) async {
    let f = await Fixture(collection: collection)
    let destination = FakeExportDestination()
    let suite = TestScratch.suiteName("NotificationExport")
    let photos = FakePhotoLibraryService()
    let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 15))!
    photos.assetsByYearMonth["2026-9"] = [
      TestAssetFactory.makeAsset(id: "asset", creationDate: date)
    ]
    photos.favoritesAssets = photos.assetsByYearMonth["2026-9"]!
    photos.resourcesByAssetId["asset"] = [.init(type: .photo, originalFilename: "ASSET.JPG")]
    let manager = ExportManager(
      photoLibraryService: photos, exportDestination: destination,
      exportRecordStore: f.timeline, collectionExportRecordStore: f.collections,
      assetResourceWriter: FakeAssetResourceWriter(),
      localHEICStorage: LocalHEICStorage(root: TestScratch.directory("ExportHEIC")),
      fileSystem: FakeFileSystem(),
      userDefaults: TestScratch.defaults(suiteName: suite))
    let baseline = f.counter
    if cancel {
      f.write("pending")
      manager.cancelAndClear()
    } else {
      if collection {
        manager.startExportFavorites()
      } else {
        manager.startExportMonth(year: 2026, month: 9)
      }
      await manager.waitForQueueDrained()
      #expect(f.record("asset")?.status == .done)
    }
    #expect(f.counter == baseline + 1)
    f.clock.advance(by: 1)
    #expect(f.counter == baseline + 1)
    let physical = manager.currentTask
    manager.cancelAndClear()
    await physical?.value
    destination.cleanup()
    await f.close()
  }

  private func reached(_ gate: AsyncCheckpoint) async -> Bool {
    await gate.waitForEnter(count: 1)
  }

  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func cancellingHeldExportPublishesAfterRemovingOwnedInProgressRecord(collection: Bool)
    async throws
  {
    let f = await Fixture(collection: collection)
    let destination = FakeExportDestination()
    let suite = TestScratch.suiteName("NotificationHeldExport")
    let photos = FakePhotoLibraryService()
    let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 15))!
    photos.assetsByYearMonth["2026-9"] = [
      TestAssetFactory.makeAsset(id: "held", creationDate: date)
    ]
    photos.favoritesAssets = photos.assetsByYearMonth["2026-9"]!
    photos.resourcesByAssetId["held"] = [.init(type: .photo, originalFilename: "HELD.JPG")]
    let writer = FakeAssetResourceWriter()
    let gate = AsyncCheckpoint()
    writer.checkpoint = gate
    let manager = ExportManager(
      photoLibraryService: photos, exportDestination: destination,
      exportRecordStore: f.timeline, collectionExportRecordStore: f.collections,
      assetResourceWriter: writer,
      localHEICStorage: LocalHEICStorage(root: TestScratch.directory("ExportHEIC")),
      fileSystem: FakeFileSystem(),
      userDefaults: TestScratch.defaults(suiteName: suite))
    var physical: Task<Void, Never>?
    var failure: Error?
    var notifications = 0
    let observation = ObservationProbe(
      { _ = f.counter },
      onChange: {
        notifications += 1
        #expect(f.record("held") == nil)
      })
    if collection {
      manager.startExportFavorites()
    } else {
      manager.startExportMonth(year: 2026, month: 9)
    }
    do {
      try #require(await reached(gate))
      physical = manager.currentTask
      #expect(f.record("held")?.status == .inProgress)
      manager.cancelAndClear()
      #expect(notifications == 1)
      #expect(f.record("held") == nil)
      await gate.releaseAll()
      await physical?.value
      f.clock.advance(by: 1)
      #expect(notifications == 1)
    } catch { failure = error }
    let current = manager.currentTask
    manager.cancelAndClear()
    await gate.releaseAll()
    await physical?.value
    await current?.value
    withExtendedLifetime(observation) {}
    destination.cleanup()
    await f.close()
    if let failure { throw failure }
  }

  @Test func terminalBadgeSubscriberCannotEraseReplacementManualFeedback() async {
    let f = await Fixture(collection: false)
    let destination = FakeExportDestination()
    let suite = TestScratch.suiteName("NotificationManualReentry")
    let photos = FakePhotoLibraryService()
    photos.fetchAssetsErrorByYear[2025] = CocoaError(.fileReadUnknown)
    let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 15))!
    photos.assetsByYearMonth["2026-9"] = [TestAssetFactory.makeAsset(id: "new", creationDate: date)]
    photos.resourcesByAssetId["new"] = [.init(type: .photo, originalFilename: "NEW.JPG")]
    let manager = ExportManager(
      photoLibraryService: photos, exportDestination: destination,
      exportRecordStore: f.timeline, collectionExportRecordStore: f.collections,
      assetResourceWriter: FakeAssetResourceWriter(),
      localHEICStorage: LocalHEICStorage(root: TestScratch.directory("ExportHEIC")),
      fileSystem: FakeFileSystem(),
      userDefaults: TestScratch.defaults(suiteName: suite))
    var replaced = false
    let observation = ObservationProbe(
      { _ = f.counter },
      onChange: {
        guard !replaced else { return }
        replaced = true
        manager.startExportMonth(year: 2026, month: 9)
      })
    f.write("pending")
    manager.startExportMonth(year: 2025, month: 1)
    let oldPreparation = manager.currentPreparationTasks
    for task in oldPreparation { await task.value }
    let replacementPreparation = manager.currentPreparationTasks
    for task in replacementPreparation { await task.value }
    await manager.waitForQueueDrained()
    #expect(replaced)
    #expect(f.record("new")?.status == .done)
    #expect(manager.progressState.manualSummary?.result == .completed)
    let physical = manager.currentTask
    manager.cancelAndClear()
    await physical?.value
    withExtendedLifetime(observation) {}
    destination.cleanup()
    await f.close()
  }

  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func terminalBadgeSubscriberCannotEraseReplacementImportOwnership(cancel: Bool) async throws {
    let f = await Fixture(collection: false)
    let destination = FakeExportDestination()
    let suite = TestScratch.suiteName("NotificationImportReentry")
    let photos = FakePhotoLibraryService()
    let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 15))!
    photos.assetsByYearMonth["2026-9"] = [
      TestAssetFactory.makeAsset(id: "asset", creationDate: date)
    ]
    photos.resourcesByAssetId["asset"] = [.init(type: .photo, originalFilename: "ASSET.JPG")]
    let directory = try destination.urlForRelativeDirectory("2026/09/", createIfNeeded: true)
    let file = directory.appendingPathComponent("ASSET.JPG")
    try Data("bytes".utf8).write(to: file)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
    let manager = ExportManager(
      photoLibraryService: photos, exportDestination: destination,
      exportRecordStore: f.timeline, collectionExportRecordStore: f.collections,
      assetResourceWriter: FakeAssetResourceWriter(),
      localHEICStorage: LocalHEICStorage(root: TestScratch.directory("ExportHEIC")),
      fileSystem: FakeFileSystem(),
      userDefaults: TestScratch.defaults(suiteName: suite))
    let gate = AsyncCheckpoint()
    var replacement: Task<Void, Never>?
    var replaced = false
    let observation = ObservationProbe(
      { _ = f.counter },
      onChange: {
        guard !replaced else { return }
        replaced = true
        manager.cancelImport()
        photos.fetchAssetsCheckpointByYear[2026] = gate
        manager.startImport()
        replacement = manager.importTask
      })
    f.write("pending")
    manager.startImport()
    let original = manager.importTask
    if cancel { manager.cancelImport() }
    await original?.value
    var failure: Error?
    do {
      try #require(await reached(gate))
      #expect(replaced && manager.isImporting)
      #expect(manager.importStage == .readingPhotosLibrary)
      await gate.releaseAll()
      await replacement?.value
      #expect(!manager.isImporting)
      #expect(manager.importStage == .done && manager.importResult?.matchedCount == 1)
    } catch { failure = error }
    let current = manager.importTask
    manager.cancelImport()
    await gate.releaseAll()
    await original?.value
    await replacement?.value
    await current?.value
    withExtendedLifetime(observation) {}
    destination.cleanup()
    await f.close()
    if let failure { throw failure }
  }

  @Test(arguments: [false, true])
  func importTerminalPublishesBothStoresAndStaleTaskCannotFlushNewWindow(cancel: Bool) async {
    let f = await Fixture(collection: false)
    let destination = FakeExportDestination()
    let suite = TestScratch.suiteName("NotificationImport")
    let manager = ExportManager(
      photoLibraryService: FakePhotoLibraryService(), exportDestination: destination,
      exportRecordStore: f.timeline, collectionExportRecordStore: f.collections,
      assetResourceWriter: FakeAssetResourceWriter(),
      localHEICStorage: LocalHEICStorage(root: TestScratch.directory("ExportHEIC")),
      fileSystem: FakeFileSystem(),
      userDefaults: TestScratch.defaults(suiteName: suite))
    let beforeTimeline = f.timeline.mutationCounter
    let beforeCollections = f.collections.mutationCounter
    f.write("pending")
    f.collections.markVariantInProgress(
      assetId: "pending", placement: f.placement, variant: .original, filename: nil)
    var terminalValues: [(Int, Int)] = []
    let observation = manager.isImportingFlagOnlyPublisher.dropFirst().sink { importing in
      if !importing {
        terminalValues.append((f.timeline.mutationCounter, f.collections.mutationCounter))
      }
    }
    manager.startImport()
    let physical = manager.importTask
    if cancel {
      manager.cancelImport()
      // The old task's defer must not flush new changes after losing ownership.
      f.write("replacement")
      f.collections.markVariantInProgress(
        assetId: "replacement", placement: f.placement, variant: .original, filename: nil)
    }
    await physical?.value
    #expect(terminalValues.count == 1)
    #expect(terminalValues.first?.0 == beforeTimeline + 1)
    #expect(terminalValues.first?.1 == beforeCollections + 1)
    #expect(f.timeline.mutationCounter == beforeTimeline + 1)
    #expect(f.collections.mutationCounter == beforeCollections + 1)
    f.clock.advance(by: 0.201)
    #expect(f.timeline.mutationCounter == beforeTimeline + (cancel ? 2 : 1))
    #expect(f.collections.mutationCounter == beforeCollections + (cancel ? 2 : 1))
    withExtendedLifetime(observation) {}
    destination.cleanup()
    await f.close()
  }
}
