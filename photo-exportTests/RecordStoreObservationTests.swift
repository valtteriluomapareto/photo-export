import Combine
import Foundation
import Testing

@testable import Photo_Export

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct RecordStoreObservationTests {
  enum Query: String, CaseIterable, Sendable {
    case timelineDestination, timelineIsExported, timelineExportInfo
    case timelineFilenameExceptVariant, timelineFilenameExceptAsset
    case timelineYearCount, timelineMonthTotal, timelineMonthAssets, timelineRecordCount
    case timelineBothDone, timelineEditedDone, timelineNaturalStem, timelineFallback
    case timelinePairedIncomplete, timelineSidebar, timelineSidebarYear
    case collectionDestination, collectionCurrentPlacement, collectionPlacement,
      collectionPlacements
    case collectionRecordedVariants, collectionExportInfo
    case collectionFilenameExceptVariant, collectionFilenameExceptAsset
    case collectionIsExported, collectionRecordCount, collectionMonthAssets, collectionSummary

    var collection: Bool { rawValue.hasPrefix("collection") }

    @MainActor fileprivate func read(_ f: Fixture) {
      switch self {
      case .timelineDestination: _ = f.timeline.destinationId
      case .timelineIsExported:
        _ = f.timeline.isExported(asset: f.asset, selection: .edited, livePhotosPaired: false)
      case .timelineExportInfo: _ = f.timeline.exportInfo(assetId: "seed")
      case .timelineFilenameExceptVariant:
        _ = f.timeline.isFilenameClaimed(
          "SEED.HEIC", year: 2026, month: 9, subfolder: nil, exceptVariant: .edited, of: "other")
      case .timelineFilenameExceptAsset:
        _ = f.timeline.isFilenameClaimed(
          "SEED.HEIC", year: 2026, month: 9, subfolder: nil, exceptAsset: "other")
      case .timelineYearCount: _ = f.timeline.yearExportedCount(year: 2026)
      case .timelineMonthTotal: _ = f.timeline.monthSummary(year: 2026, month: 9, totalAssets: 1)
      case .timelineMonthAssets:
        _ = f.timeline.monthSummary(assets: [f.asset], selection: .edited, livePhotosPaired: false)
      case .timelineRecordCount:
        _ = f.timeline.recordCount(year: 2026, month: 9, variant: .original, status: .done)
      case .timelineBothDone: _ = f.timeline.recordCountBothVariantsDone(year: 2026, month: 9)
      case .timelineEditedDone: _ = f.timeline.recordCountEditedDone(year: 2026, month: 9)
      case .timelineNaturalStem:
        _ = f.timeline.recordCountOriginalDoneAtNaturalStem(year: 2026, month: 9)
      case .timelineFallback: _ = f.timeline.recordCountEditedFallback(year: 2026, month: 9)
      case .timelinePairedIncomplete:
        _ = f.timeline.recordCountPairedVideoIncomplete(year: 2026, month: 9)
      case .timelineSidebar:
        _ = f.timeline.sidebarSummary(
          year: 2026, month: 9, totalCount: 1, adjustedCount: 0,
          selection: .edited, livePhotosPaired: false)
      case .timelineSidebarYear:
        _ = f.timeline.sidebarYearExportedCount(
          year: 2026, totalCountsByMonth: [9: 1], adjustedCountsByMonth: [9: 0],
          selection: .edited, livePhotosPaired: false)
      case .collectionDestination: _ = f.collections.destinationId
      case .collectionCurrentPlacement:
        _ = f.collections.currentPlacement(for: .favorites, collections: [])
      case .collectionPlacement: _ = f.collections.placement(id: f.placement.id)
      case .collectionPlacements: _ = f.collections.placements(matching: .favorites)
      case .collectionRecordedVariants:
        _ = f.collections.recordedVariantCount(of: [
          .init(placement: f.placement, records: ["seed": [.original: f.original]])
        ])
      case .collectionExportInfo:
        _ = f.collections.exportInfo(assetId: "seed", placement: f.placement)
      case .collectionFilenameExceptVariant:
        _ = f.collections.isFilenameClaimed(
          "SEED.HEIC", placement: f.placement, subfolder: nil, exceptVariant: .edited, of: "other")
      case .collectionFilenameExceptAsset:
        _ = f.collections.isFilenameClaimed(
          "SEED.HEIC", placement: f.placement, subfolder: nil, exceptAsset: "other")
      case .collectionIsExported:
        _ = f.collections.isExported(
          asset: f.asset, placement: f.placement, selection: .edited, livePhotosPaired: false)
      case .collectionRecordCount: _ = f.collections.recordCount(in: .favorites)
      case .collectionMonthAssets:
        _ = f.collections.monthSummary(
          assets: [f.asset], placement: f.placement, selection: .edited, livePhotosPaired: false)
      case .collectionSummary: _ = f.collections.summary(for: f.placement)
      }
    }
  }

  @MainActor
  fileprivate final class Fixture {
    let root = TestScratch.directory("RecordStoreObservation")
    let clock = TestClock()
    let timeline: ExportRecordStore
    let collections: CollectionExportRecordStore
    let placement = ExportPlacement.favorites()
    let asset = TestAssetFactory.makeAsset(
      id: "seed",
      creationDate: Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 15))!,
      originalUTI: "public.heic")
    let original = ExportVariantRecord(
      filename: "SEED.HEIC", status: .done, exportDate: nil, lastError: nil)

    init(io: any JSONLRecordLogIO = ProductionJSONLRecordLogIO()) {
      timeline = ExportRecordStore(
        baseDirectoryURL: root, recordLogIO: io, notificationClock: clock)
      collections = CollectionExportRecordStore(
        baseDirectoryURL: root, recordLogIO: io, notificationClock: clock)
      timeline.configure(for: "A")
      collections.configure(for: "A")
      timeline.markVariantExported(
        assetId: "seed", variant: .original, year: 2026, month: 9,
        relPath: "2026/09/", filename: "SEED.HEIC", exportedAt: Date())
      collections.upsertPlacement(placement)
      collections.markVariantExported(
        assetId: "seed", placement: placement, variant: .original, filename: "SEED.HEIC",
        exportedAt: Date())
      timeline.flushPendingNotifications()
      collections.flushPendingNotifications()
    }

    func write(_ id: String, collection: Bool) {
      if collection {
        collections.markVariantInProgress(
          assetId: id, placement: placement, variant: .original, filename: "\(id).JPG")
      } else {
        timeline.markVariantInProgress(
          assetId: id, variant: .original, year: 2026, month: 9, relPath: "2026/09/",
          filename: "\(id).JPG")
      }
    }

    func flushNotifications(_ collection: Bool) {
      if collection {
        collections.flushPendingNotifications()
      } else {
        timeline.flushPendingNotifications()
      }
    }

    func counter(_ collection: Bool) -> Int {
      collection ? collections.mutationCounter : timeline.mutationCounter
    }
    func state(_ collection: Bool) -> RecordStoreState {
      collection ? collections.state : timeline.state
    }
    func waiters(_ collection: Bool) -> Int {
      collection ? collections.pendingSettleWaiterCount : timeline.pendingSettleWaiterCount
    }
    func configure(_ id: String?, collection: Bool) {
      if collection { collections.configure(for: id) } else { timeline.configure(for: id) }
    }
    func beginConfigure(_ id: String, collection: Bool) {
      if collection {
        collections.beginConfigure(for: id)
      } else {
        timeline.beginConfigure(for: id)
      }
    }
    func waitUntilSettled(_ collection: Bool) async {
      if collection {
        await collections.waitUntilSettled()
      } else {
        await timeline.waitUntilSettled()
      }
    }
    func statePublisher(_ collection: Bool) -> AnyPublisher<RecordStoreState, Never> {
      collection ? collections.statePublisher : timeline.statePublisher
    }
    func readRecord(_ collection: Bool) {
      if collection {
        _ = collections.exportInfo(assetId: "seed", placement: placement)
      } else {
        _ = timeline.exportInfo(assetId: "seed")
      }
    }
    func flush() async throws {
      try await timeline.flush()
      try await collections.flush()
    }
    func close() async {
      try? await flush()
      try? FileManager.default.removeItem(at: root)
    }
  }

  /// Each query's notification fails before dependency tracking; writes before the flush stay silent.
  @Test(arguments: Query.allCases)
  func everyQueryRegistersThroughMutationCounter(query: Query) async {
    let f = Fixture()
    await withCleanup {
      let probe = ObservationProbe { query.read(f) }
      let before = f.counter(query.collection)
      f.write("unrelated", collection: query.collection)
      #expect(probe.changeCount == 0)
      f.flushNotifications(query.collection)
      #expect(f.counter(query.collection) == before + 1)
      withKnownIssue("Record store reads do not register this Observation dependency yet") {
        #expect(probe.changeCount == 1)
      } when: {
        true
      }
    } cleanup: {
      await f.close()
    }
  }

  /// The counter already coalesces writes; query notifications are missing until it is tracked.
  @Test(arguments: [false, true])
  func queryNotificationsKeepTheCoalescedRate(collection: Bool) async {
    let f = Fixture()
    await withCleanup {
      let probe = ObservationProbe { f.readRecord(collection) }
      let before = f.counter(collection)
      for index in 0..<5 { f.write("burst-\(index)", collection: collection) }
      #expect(probe.changeCount == 0)
      #expect(f.counter(collection) == before)
      f.clock.advance(by: 0.201)
      #expect(f.counter(collection) == before + 1)
      withKnownIssue("Record store reads do not register this Observation dependency yet") {
        #expect(probe.changeCount == 1)
      } when: {
        true
      }
      f.configure("B", collection: collection)
      #expect(f.counter(collection) == before + 2)
      withKnownIssue("Record store reads do not register this Observation dependency yet") {
        #expect(probe.changeCount == 2)
      } when: {
        true
      }
    } cleanup: {
      await f.close()
    }
  }

  /// Results already follow conversion; only the two queries that read the flag need notifications.
  @Test(arguments: [false, true])
  func convertHEICToJPEGNotifiesOnlyQueriesThatReadIt(collection: Bool) async {
    let f = Fixture()
    await withCleanup {
      let exported = ObservationProbe {
        if collection {
          _ = f.collections.isExported(
            asset: f.asset, placement: f.placement, selection: .edited, livePhotosPaired: false)
        } else {
          _ = f.timeline.isExported(asset: f.asset, selection: .edited, livePhotosPaired: false)
        }
      }
      let month = ObservationProbe {
        if collection {
          _ = f.collections.monthSummary(
            assets: [f.asset], placement: f.placement, selection: .edited, livePhotosPaired: false)
        } else {
          _ = f.timeline.monthSummary(
            assets: [f.asset], selection: .edited, livePhotosPaired: false)
        }
      }
      let sibling = ObservationProbe {
        if collection {
          _ = f.collections.summary(for: f.placement)
        } else {
          _ = f.timeline.sidebarSummary(
            year: 2026, month: 9, totalCount: 1, adjustedCount: 0, selection: .edited,
            livePhotosPaired: false)
        }
      }
      if collection {
        f.collections.convertHEICToJPEG = true
      } else {
        f.timeline.convertHEICToJPEG = true
      }
      withKnownIssue("Record store reads do not register this Observation dependency yet") {
        #expect(exported.changeCount == 1)
      } when: {
        true
      }
      withKnownIssue("Record store reads do not register this Observation dependency yet") {
        #expect(month.changeCount == 1)
      } when: {
        true
      }
      #expect(sibling.changeCount == 0)
      let changedCounts = [exported.changeCount, month.changeCount, sibling.changeCount]
      if collection {
        f.collections.convertHEICToJPEG = true
      } else {
        f.timeline.convertHEICToJPEG = true
      }
      #expect([exported.changeCount, month.changeCount, sibling.changeCount] == changedCounts)
    } cleanup: {
      await f.close()
    }
  }

  /// Combine and waiter ordering already pass; Observation must precede delivery and waiter resumption.
  @Test(arguments: [false, true])
  func stateNotifiesForLoadingAndSettling(collection: Bool) async throws {
    let io = HeldReadIO()
    let f = Fixture(io: io)
    try await withCleanup {
      let probe = ObservationProbe { _ = f.state(collection) }
      var states: [RecordStoreState] = []
      var readyProbeCount: Int?
      let subscription = f.statePublisher(collection).dropFirst().sink { state in
        states.append(state)
        if state == .ready {
          #expect(f.waiters(collection) == 1)
          readyProbeCount = probe.changeCount
        }
      }
      let filename =
        collection
        ? CollectionExportRecordStore.Constants.snapshotFileName
        : ExportRecordStore.Constants.snapshotFileName
      let snapshot = f.root.appendingPathComponent("B").appendingPathComponent(filename)
      io.hold(snapshot)
      f.beginConfigure("B", collection: collection)
      withKnownIssue("Record store reads do not register this Observation dependency yet") {
        #expect(probe.changeCount == 1)
      } when: {
        true
      }
      let waiter = Task { @MainActor in
        await f.waitUntilSettled(collection)
        return (f.state(collection), probe.changeCount)
      }
      try #require(await observe { f.waiters(collection) == 1 && io.heldCount == 1 })
      io.release(snapshot)
      let settled = await waiter.value
      #expect(settled.0 == .ready)
      withKnownIssue("Record store reads do not register this Observation dependency yet") {
        #expect(settled.1 == 2)
      } when: {
        true
      }
      withKnownIssue("Record store reads do not register this Observation dependency yet") {
        #expect(readyProbeCount == 2)
      } when: {
        true
      }
      f.configure(nil, collection: collection)
      withKnownIssue("Record store reads do not register this Observation dependency yet") {
        #expect(probe.changeCount == 3)
      } when: {
        true
      }
      let afterNil = probe.changeCount
      f.configure(nil, collection: collection)
      #expect(probe.changeCount == afterNil)
      #expect(states == [.loading, .ready, .unconfigured, .unconfigured])
      withExtendedLifetime(subscription) {}
    } cleanup: {
      io.releaseAll()
      await f.close()
    }
  }

  private final class FailingLogIO: JSONLRecordLogIO, @unchecked Sendable {
    private let lock = NSLock()
    private var fail = false
    private let real = ProductionJSONLRecordLogIO()
    var shouldFail: Bool {
      get { lock.withLock { fail } }
      set { lock.withLock { fail = newValue } }
    }
    func readIfPresent(at url: URL) throws -> Data? { try real.readIfPresent(at: url) }
    func openForAppending(at url: URL) throws -> FileHandle { try real.openForAppending(at: url) }
    func write(_ data: Data, to handle: FileHandle) throws {
      if shouldFail { throw CocoaError(.fileWriteOutOfSpace) }
      try real.write(data, to: handle)
    }
    func synchronize(_ handle: FileHandle) throws { try real.synchronize(handle) }
  }

  /// Sibling silence already passes; the flush and persistence-failure positive controls need dependencies.
  @Test(arguments: [false, true])
  func bridgedSiblingsStayQuiet(collection: Bool) async throws {
    let io = FailingLogIO()
    let f = Fixture(io: io)
    try await withCleanup {
      try await f.flush()
      let state = ObservationProbe { _ = f.state(collection) }
      let counter = ObservationProbe { _ = f.counter(collection) }
      f.write("healthy", collection: collection)
      f.flushNotifications(collection)
      #expect(state.changeCount == 0)
      withKnownIssue("Record store reads do not register this Observation dependency yet") {
        #expect(counter.changeCount == 1)
      } when: {
        true
      }
      try await f.flush()
      let beforeFailure = counter.changeCount
      io.shouldFail = true
      f.write("failing", collection: collection)
      try #require(await observe { f.state(collection) == .persistenceFailed })
      withKnownIssue("Record store reads do not register this Observation dependency yet") {
        #expect(state.changeCount == 1)
      } when: {
        true
      }
      #expect(counter.changeCount == beforeFailure)
    } cleanup: {
      io.shouldFail = false
      await f.close()
    }
  }
}
