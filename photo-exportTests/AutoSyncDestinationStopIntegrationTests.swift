import Combine
import Foundation
import Testing

@testable import Photo_Export

/// Destination failures through the real export queue and the AutoSync effect runner: the
/// run stops at the first failed item, nothing reschedules it while the destination still
/// looks mounted, and the next Auto Export run picks up what the stop left.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct AutoSyncDestinationStopIntegrationTests {
  @MainActor
  private final class SummaryProbe {
    private(set) var summaries: [ExportRunSummary] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var cancellable: AnyCancellable?

    init(manager: AutoSyncManager) {
      cancellable = manager.$lastRunSummary.compactMap { $0 }.sink { [weak self] summary in
        MainActor.assumeIsolated { self?.receive(summary) }
      }
    }

    func waitForCount(_ count: Int) async {
      if summaries.count >= count { return }
      await withCheckedContinuation { continuation in
        waiters.append((count: count, continuation: continuation))
      }
    }

    private func receive(_ summary: ExportRunSummary) {
      summaries.append(summary)
      let ready = waiters.filter { $0.count <= summaries.count }
      waiters.removeAll { $0.count <= summaries.count }
      for waiter in ready { waiter.continuation.resume() }
    }
  }

  /// Three timeline photos, a real `ExportManager` over fake Photos, files and destination,
  /// and an `AutoSyncManager` attached to a timeline-only scope on an available destination.
  @MainActor
  private final class Harness {
    let ids = ["asset-A", "asset-B", "asset-C"]
    let photoLibrary = FakePhotoLibraryService()
    let destination = FakeExportDestination()
    let writer = FakeAssetResourceWriter()
    let storeRoot = TestScratch.directory("AutoSyncDestinationStop")
    let destinationSnapshot = DestinationSnapshot(
      stableId: "share", fingerprint: nil, isAvailable: true, safety: .safe)
    let destinationId: String
    let timelineStore: ExportRecordStore
    let collectionStore: CollectionExportRecordStore
    let builder = FakeAutoSyncEnvironmentBuilder()
    let exportManager: ExportManager
    let autoSync = AutoSyncManager()
    private(set) var summaries: SummaryProbe?

    init(files: FakeFileSystem = FakeFileSystem()) {
      guard let stableId = destinationSnapshot.stableId else {
        preconditionFailure("The harness destination has a stable id")
      }
      destinationId = stableId
      let assetDate = Date(timeIntervalSince1970: 1_700_000_000)
      let year = Calendar.current.component(.year, from: assetDate)
      let month = Calendar.current.component(.month, from: assetDate)
      photoLibrary.yearCounts = [(year: year, count: ids.count)]
      photoLibrary.assetsByYearMonth["\(year)-\(month)"] = ids.map {
        TestAssetFactory.makeAsset(id: $0, creationDate: assetDate)
      }
      for id in ids {
        photoLibrary.resourcesByAssetId[id] = [
          TestAssetFactory.makeResource(originalFilename: "\(id).JPG")
        ]
      }
      timelineStore = ExportRecordStore(baseDirectoryURL: storeRoot)
      timelineStore.configure(for: destinationId)
      collectionStore = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
      collectionStore.configure(for: destinationId)
      exportManager = ExportManager(
        photoLibraryService: photoLibrary,
        exportDestination: destination,
        exportRecordStore: timelineStore,
        collectionExportRecordStore: collectionStore,
        assetResourceWriter: writer,
        fileSystem: files,
        userDefaults: builder.userDefaults
      )
      exportManager.autoSyncEligibilityCheck = {
        [weak autoSync] assetId, placement, variant, now in
        autoSync?.isAutoSyncEligible(
          assetId: assetId, placement: placement, variant: variant, now: now) ?? true
      }
    }

    func attach() {
      let environment = AutoSyncEnvironment(
        exportRunner: exportManager,
        destination: builder.destination,
        scopes: builder.scopes,
        photos: builder.photos,
        importing: exportManager,
        dirtyStateStore: builder.dirtyStore,
        retryStateStore: builder.retryStore,
        runSummaryStore: builder.runSummaryStore,
        perDestinationTokenStore: builder.perDestinationTokenStore,
        currentRunStore: builder.currentRunStore,
        clock: builder.clock,
        photosAuthorization: builder.photosAuthorization,
        userDefaults: builder.userDefaults
      )
      builder.userDefaults.set(true, forKey: AutoSyncManager.enabledDefaultsKey)
      builder.destination.subject.send(destinationSnapshot)
      builder.scopes.subject.send(AutoExportScopeSelection(timeline: true))
      autoSync.attach(to: environment)
      summaries = SummaryProbe(manager: autoSync)
    }

    func pushInserted(_ ids: Set<String>) {
      builder.photos.push(
        PhotoLibraryPersistentChangeEvent(
          insertedLocalIdentifiers: ids, observedAt: builder.clock.now()))
    }

    /// Advances past the Photos-change debounce and waits for the run it starts. A due
    /// retry entry instead schedules a zero-delay retry debounce, which `dueRetry` runs.
    func runScheduled(
      expectingSummary count: Int, dueRetry: Bool = false
    ) async throws -> ExportRunSummary {
      builder.clock.advance(by: 30)
      if dueRetry { builder.clock.advance(by: 0) }
      let run = try #require(autoSync.activeRunFanOutTask)
      await run.value
      let probe = try #require(summaries)
      await probe.waitForCount(count)
      return probe.summaries[count - 1]
    }

    var pendingTimelineIds: Set<String> {
      builder.dirtyStore.load(destinationId: destinationId).scope(.timeline).pendingAssetIds
    }

    func retryEntry(_ assetId: String) -> RetryEntry? {
      autoSync.currentRetryState.entry(scope: .timeline, assetId: assetId, variant: .original)
    }

    func close() {
      autoSync.setEnabled(false)
      exportManager.cancelAndClear()
      timelineStore.flushForTesting()
      collectionStore.flushForTesting()
      try? FileManager.default.removeItem(at: storeRoot)
      destination.cleanup()
    }
  }

  /// A network share that stops answering mid-run.
  @Test func unreachableShareStopsTheRunWithoutAReschedule() async throws {
    // Every exclusive rename fails with ENOTCONN until the share comes back.
    let unreachable = LockedBox(true)
    let files = FakeFileSystem(
      real: FileIOService(
        renamer: { source, destination, flags in
          unreachable.value ? ENOTCONN : FileIOService.systemRename(source, destination, flags)
        },
        capability: { _ in true }))
    let h = Harness(files: files)
    defer { h.close() }
    h.attach()
    // Pending Photos work that the resume hook would otherwise reschedule.
    h.pushInserted(Set(h.ids))

    let stopped = try await h.runScheduled(expectingSummary: 1)
    #expect(stopped.result == .interrupted)
    #expect(stopped.cancelReason == .destinationUnavailable)
    #expect(stopped.stoppedBy == .destinationUnavailable)
    #expect(stopped.failures.map(\.assetId) == ["asset-A"])
    #expect(h.writer.writeCalls.map(\.assetId) == ["asset-A"])
    #expect(h.autoSync.state == .idle)
    #expect(h.builder.clock.pendingCount == 0, "No debounce or retry timer after the stop")
    #expect(h.pendingTimelineIds == Set(h.ids))
    let entry = try #require(h.retryEntry("asset-A"))
    #expect(entry.category == .destinationUnavailable && entry.nextEligibleAt == nil)

    // The share answers again and a Photos change arrives: the next run retries the
    // failed item with the others.
    unreachable.mutate { $0 = false }
    h.pushInserted(["asset-A"])
    guard case .scheduled(.photosChanged, _) = h.autoSync.state else {
      Issue.record("A Photos change after the stop must schedule, got \(h.autoSync.state)")
      return
    }
    let resumed = try await h.runScheduled(expectingSummary: 2)
    #expect(resumed.result == .completed)
    for id in h.ids { #expect(h.timelineStore.isExported(assetId: id)) }
    #expect(h.autoSync.currentRetryState.isEmpty)
    #expect(h.autoSync.state == .idle)
    #expect(h.builder.clock.pendingCount == 0)
  }

  /// A read-only export folder can be reached, so the run stops at its first item as a
  /// permission failure. That includes an item an older version had stored as an `unknown`
  /// failure with a backoff deadline: it now needs the user, so it is held until **Retry**.
  @Test func readOnlyFolderStopsTheRunAndHoldsALegacyUnknownEntry() async throws {
    let h = Harness()
    defer { h.close() }
    let readOnly = ExportDestinationManager.ExportDestinationError.notWritable
    let bridged = readOnly as NSError
    let signature = "\(bridged.domain):\(bridged.code)"
    let failedAt = h.builder.clock.now().addingTimeInterval(-60)
    var legacy = AutoSyncRetryState.empty
    legacy.recordFailure(
      scope: .timeline, assetId: "asset-A", variant: .original, category: .unknown,
      errorSignature: signature, at: failedAt,
      nextEligibleAt: AutoSyncFailureCategory.unknown.nextEligibleAt(
        attemptCount: 1, from: failedAt))
    let due = try #require(
      legacy.entry(scope: .timeline, assetId: "asset-A", variant: .original))
    try #require(due.isEligibleForAutoSync(now: h.builder.clock.now()))
    try h.builder.retryStore.save(legacy, destinationId: h.destinationId)
    h.destination.urlForRelativeDirectoryError = readOnly
    h.attach()
    h.pushInserted(Set(h.ids))

    let stopped = try await h.runScheduled(expectingSummary: 1, dueRetry: true)
    #expect(stopped.context.reason == .retryBackoff)
    #expect(stopped.result == .failed)
    #expect(stopped.cancelReason == nil)
    #expect(stopped.stoppedBy == .destinationPermission)
    #expect(stopped.failures.map(\.assetId) == ["asset-A"])
    #expect(stopped.failures.map(\.errorSignature) == [signature])
    #expect(h.writer.writeCalls.isEmpty)
    #expect(h.autoSync.state == .idle)
    #expect(h.builder.clock.pendingCount == 0, "No debounce or retry timer after the stop")
    #expect(h.pendingTimelineIds == Set(h.ids))
    let held = try #require(h.retryEntry("asset-A"))
    #expect(held.category == .destinationPermission)
    #expect(held.errorSignature == signature)
    #expect(held.attemptCount == 1)
    #expect(held.nextEligibleAt == nil)
    #expect(h.retryEntry("asset-B") == nil && h.retryEntry("asset-C") == nil)

    // Once the app sees the folder as writable (today that takes a reselect or relaunch, see
    // #362) and a Photos change arrives, the next run exports the items the stop never
    // reached and leaves the held one for the user.
    h.destination.urlForRelativeDirectoryError = nil
    h.pushInserted(["asset-B", "asset-C"])
    guard case .scheduled(.photosChanged, _) = h.autoSync.state else {
      Issue.record("A Photos change after the stop must schedule, got \(h.autoSync.state)")
      return
    }
    let resumed = try await h.runScheduled(expectingSummary: 2)
    #expect(resumed.stoppedBy == nil)
    #expect(resumed.failures.isEmpty)
    #expect(h.writer.writeCalls.map(\.assetId) == ["asset-B", "asset-C"])
    #expect(!h.timelineStore.isExported(assetId: "asset-A"))
    #expect(h.timelineStore.isExported(assetId: "asset-B"))
    #expect(h.timelineStore.isExported(assetId: "asset-C"))
    #expect(h.retryEntry("asset-A") == held)
    #expect(h.autoSync.state == .idle)
    #expect(h.builder.clock.pendingCount == 0)
  }
}
