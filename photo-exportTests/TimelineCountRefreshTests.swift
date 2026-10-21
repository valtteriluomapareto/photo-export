import Combine
import Foundation
import Testing

@testable import Photo_Export

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct TimelineCountRefreshTests {
  @Test func oldCountsCannotRestoreCompleteBadgeAfterNewPhotoArrives() async throws {
    let service = FakePhotoLibraryService()
    service.cachedCountOverride = { scope, adjusted in
      scope == .timeline(year: 2025, month: 1) && !adjusted ? 1 : 0
    }
    let loader = TimelineSidebarCounts(service: service)
    await loader.loadCounts(forYears: [2025])
    let root = TestScratch.directory("TimelineCountRefresh")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ExportRecordStore(baseDirectoryURL: root)
    defer { store.drainSynchronously() }
    store.configure(for: "A")
    store.markVariantExported(
      assetId: "old", variant: .original, year: 2025, month: 1,
      relPath: "2025/01/", filename: "old.jpg", exportedAt: Date())
    func summary() -> MonthStatusSummary? {
      store.sidebarSummary(
        year: 2025, month: 1, totalCount: loader.assetCountsByYearMonth["2025-1"] ?? 0,
        adjustedCount: loader.adjustedCountsByYearMonth["2025-1"],
        selection: .edited, livePhotosPaired: false)
    }
    #expect(summary()?.exportedCount == 1)
    let oldGate = AsyncCheckpoint()
    service.cachedCountOverride = { scope, adjusted in
      guard scope == .timeline(year: 2025, month: 1) else { return 0 }
      await oldGate.enter()
      return adjusted ? 1 : 1
    }
    let old = Task { await loader.loadCounts(forYears: [2025, 2024]) }
    await oldGate.waitForEnter(count: 2)
    #expect(loader.monthsWithAssets(for: 2025) == [1])
    #expect(summary()?.exportedCount == 1, "keep the previous coherent badge during refresh")
    #expect(summary()?.totalCount == 1)
    let freshGate = AsyncCheckpoint()
    service.cachedCountOverride = { scope, adjusted in
      guard scope == .timeline(year: 2025, month: 1) else { return 0 }
      if adjusted {
        await freshGate.enter()
        return 0
      }
      return 2
    }
    let fresh = Task { await loader.loadCounts(forYears: [2025]) }
    await freshGate.waitForEnter(count: 1)
    #expect(summary()?.totalCount == 1)
    await freshGate.releaseAll()
    await fresh.value
    #expect(summary()?.exportedCount == 1)
    #expect(summary()?.totalCount == 2)
    await oldGate.releaseAll()
    await old.value
    #expect(summary()?.exportedCount == 1)
    #expect(summary()?.totalCount == 2)
    #expect(loader.adjustedCountsByYearMonth["2025-1"] == 0)
    #expect(loader.assetCountsByYearMonth["2024-1"] == nil)
  }

  @Test(arguments: [true, false])
  func loadedPairStaysVisibleUntilBothFreshCountsArrive(totalFirst: Bool) async throws {
    let service = FakePhotoLibraryService()
    service.cachedCountOverride = { _, adjusted in adjusted ? 0 : 1 }
    let loader = TimelineSidebarCounts(service: service)
    await loader.loadCounts(forYears: [2025])
    let totalGate = AsyncCheckpoint()
    let adjustedGate = AsyncCheckpoint()
    let responses = AsyncStream<Bool>.makeStream()
    var iterator = responses.stream.makeAsyncIterator()
    service.cachedCountOverride = { scope, adjusted in
      guard scope == .timeline(year: 2025, month: 1) else { return adjusted ? 0 : 1 }
      await (adjusted ? adjustedGate : totalGate).enter()
      responses.continuation.yield(adjusted)
      return adjusted ? 1 : 2
    }
    var observed: [String] = []
    let subscription = loader.$countsByYearMonth.sink { snapshot in
      observed.append("\(snapshot["2025-1"]?.total ?? -1):\(snapshot["2025-1"]?.adjusted ?? -1)")
    }
    let refresh = Task { await loader.loadCounts(forYears: [2025]) }
    var failure: Error?
    do {
      let totalStarted = await totalGate.waitForEnter(count: 1)
      let adjustedStarted = await adjustedGate.waitForEnter(count: 1)
      try #require(totalStarted && adjustedStarted)
      #expect(loader.assetCountsByYearMonth["2025-1"] == 1)
      #expect(loader.adjustedCountsByYearMonth["2025-1"] == 0)
      await (totalFirst ? totalGate : adjustedGate).releaseAll()
      // The first fake request returns before the other may return. Every emitted
      // consumer snapshot (including any delayed delivery) must remain coherent.
      #expect(await iterator.next() == !totalFirst)
      #expect(loader.assetCountsByYearMonth["2025-1"] == 1)
      #expect(loader.adjustedCountsByYearMonth["2025-1"] == 0)
      #expect(observed == ["1:0"])
    } catch { failure = error }
    await totalGate.releaseAll()
    await adjustedGate.releaseAll()
    await refresh.value
    #expect(loader.assetCountsByYearMonth["2025-1"] == 2)
    #expect(loader.adjustedCountsByYearMonth["2025-1"] == 1)
    #expect(observed == ["1:0", "2:1"])
    withExtendedLifetime(subscription) {}
    if let failure { throw failure }
  }

  @Test func identicalRefreshDoesNotPublish() async {
    let service = FakePhotoLibraryService()
    service.cachedCountOverride = { _, adjusted in adjusted ? 0 : 1 }
    let loader = TimelineSidebarCounts(service: service)
    await loader.loadCounts(forYears: [2025])
    var publications = 0
    let subscription = loader.objectWillChange.sink { publications += 1 }
    var snapshots = 0
    let countSubscription = loader.$countsByYearMonth.dropFirst().sink { _ in snapshots += 1 }
    await loader.loadCounts(forYears: [2025])
    #expect(publications == 0)
    #expect(snapshots == 0)
    withExtendedLifetime((subscription, countSubscription)) {}
  }

  @Test(arguments: [true, false])
  func currentFailureInvalidatesOnlyAffectedMonthAndCanRecover(totalFails: Bool) async {
    let service = FakePhotoLibraryService()
    service.cachedCountOverride = { _, adjusted in adjusted ? 0 : 1 }
    let loader = TimelineSidebarCounts(service: service)
    await loader.loadCounts(forYears: [2025])
    service.cachedCountOverride = { scope, adjusted in
      if scope == .timeline(year: 2025, month: 1), adjusted != totalFails {
        throw CocoaError(.fileReadUnknown)
      }
      return adjusted ? 1 : 2
    }
    await loader.loadCounts(forYears: [2025])
    #expect(loader.assetCountsByYearMonth["2025-1"] == (totalFails ? 1 : 2))
    #expect(loader.adjustedCountsByYearMonth["2025-1"] == nil)
    #expect(loader.assetCountsByYearMonth["2025-2"] == 2)
    #expect(loader.adjustedCountsByYearMonth["2025-2"] == 1)
    #expect(loader.lastError != nil)
    service.cachedCountOverride = { _, adjusted in adjusted ? 1 : 2 }
    await loader.loadCounts(forYears: [2025])
    #expect(loader.assetCountsByYearMonth["2025-1"] == 2)
    #expect(loader.adjustedCountsByYearMonth["2025-1"] == 1)
    #expect(loader.lastError == nil)
  }

  @Test func obsoleteErrorCannotReplaceNewerSuccessfulRefresh() async throws {
    let service = FakePhotoLibraryService()
    let gate = AsyncCheckpoint()
    service.cachedCountOverride = { _, adjusted in
      await gate.enter()
      if adjusted { throw CocoaError(.fileReadUnknown) }
      return 1
    }
    let loader = TimelineSidebarCounts(service: service)
    let old = Task { await loader.loadCounts(forYears: [2025]) }
    var failure: Error?
    do {
      let started = await gate.waitForEnter(count: 24)
      try #require(started)
      service.cachedCountOverride = { _, adjusted in adjusted ? 1 : 2 }
      await loader.loadCounts(forYears: [2025])
    } catch { failure = error }
    await gate.releaseAll()
    await old.value
    #expect(loader.assetCountsByYearMonth["2025-1"] == 2)
    #expect(loader.adjustedCountsByYearMonth["2025-1"] == 1)
    #expect(loader.lastError == nil)
    if let failure { throw failure }
  }

  @Test func totalFailureDoesNotPairOldTotalWithFreshAdjustedCount() async {
    let service = FakePhotoLibraryService()
    service.cachedCountOverride = { _, adjusted in adjusted ? 0 : 1 }
    let loader = TimelineSidebarCounts(service: service)
    await loader.loadCounts(forYears: [2025])
    service.cachedCountOverride = { _, adjusted in
      if !adjusted { throw CocoaError(.fileReadUnknown) }
      return 0
    }
    await loader.loadCounts(forYears: [2025])
    #expect(loader.assetCountsByYearMonth["2025-1"] == 1)
    #expect(loader.adjustedCountsByYearMonth["2025-1"] == nil)
    #expect(loader.lastError != nil)
  }

  @Test func resetAndCancellationRejectNonCooperativeLateWritesAndErrors() async {
    for reset in [true, false] {
      let gate = AsyncCheckpoint()
      let service = FakePhotoLibraryService()
      service.cachedCountOverride = { _, adjusted in
        await gate.enter()
        if adjusted { throw CocoaError(.fileReadUnknown) }
        return 9
      }
      let loader = TimelineSidebarCounts(service: service)
      let task = Task { await loader.loadCounts(forYears: [2025, 2024]) }
      await gate.waitForEnter(count: 24)
      if reset { loader.reset() } else { task.cancel() }
      await gate.releaseAll()
      await task.value
      #expect(loader.assetCountsByYearMonth.isEmpty)
      #expect(loader.adjustedCountsByYearMonth.isEmpty)
      #expect(loader.lastError == nil)
    }
  }
}

struct CountCacheFreshnessTests {
  @Test func invalidatedNonCooperativeFetchCannotReturnOrReplaceFreshValue() async throws {
    let cache = CollectionCountCache()
    let gate = AsyncCheckpoint()
    let old = Task {
      try await cache.count(for: "month") {
        await gate.enter()
        return 1
      }
    }
    await gate.waitForEnter(count: 1)
    await cache.invalidateAll()
    #expect(try await cache.count(for: "month") { 2 } == 2)
    await gate.releaseAll()
    do {
      _ = try await old.value
      Issue.record("invalidated counts must not reach sidebar readers")
    } catch { #expect(error is CancellationError) }
    #expect(try await cache.count(for: "month") { 99 } == 2)
  }
}

@MainActor
struct PhotoLibraryCountInvalidationTests {
  @Test func countReadsWaitForAllInvalidationsAndUseFreshTotalAndAdjustedValues() async throws {
    let service = FakePhotoLibraryService()
    let scope = PhotoFetchScope.timeline(year: 2025, month: 1)
    let old = AssetDescriptor(
      id: "old",
      creationDate: Calendar.current.date(from: DateComponents(year: 2025, month: 1, day: 15))!,
      mediaType: .image, pixelWidth: 1,
      pixelHeight: 1, duration: 0, hasAdjustments: false)
    let edited = AssetDescriptor(
      id: "new",
      creationDate: Calendar.current.date(from: DateComponents(year: 2025, month: 1, day: 15))!,
      mediaType: .image, pixelWidth: 1,
      pixelHeight: 1, duration: 0, hasAdjustments: true)
    service.assetsByYearMonth["2025-1"] = [old]
    #expect(try await service.cachedCountAssets(in: scope) == 1)
    #expect(try await service.cachedCountAdjustedAssets(in: scope) == 0)
    let gate = AsyncCheckpoint()
    let events = AsyncStream<String>.makeStream()
    var iterator = events.stream.makeAsyncIterator()
    let manager = PhotoLibraryManager(
      overrideService: service,
      countInvalidationOverride: {
        await gate.enter()
        await service.collectionCountCache.invalidateAll()
      },
      countInvalidationWaitObserver: { events.continuation.yield("waiting") })
    manager.invalidateCache()
    await gate.waitForEnter(count: 1)
    let total = Task {
      let value = try await manager.cachedCountAssets(in: scope)
      events.continuation.yield("finished")
      return value
    }
    #expect(await iterator.next() == "waiting", "reader is suspended on A")
    manager.invalidateCache()
    await gate.release()
    await gate.waitForEnter(count: 2)
    // A has finished and B is pending. A one-barrier reader would finish;
    // the correct reader observes B and reports another wait instead.
    #expect(await iterator.next() == "waiting")
    service.assetsByYearMonth["2025-1"] = [old, edited]
    let adjusted = Task { try await manager.cachedCountAdjustedAssets(in: scope) }
    await gate.releaseAll()
    #expect(try await total.value == 2)
    #expect(try await adjusted.value == 1)
    #expect(manager.libraryRevision == 2)
  }
}
