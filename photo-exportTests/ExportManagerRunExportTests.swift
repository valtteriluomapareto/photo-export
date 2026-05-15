import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Phase 0a (auto-sync plan): the awaitable `runExport(context:) async -> ExportRunSummary`
/// API. MVP coverage maps `.timelineFullLibrary`, `.favoritesFull`, and `.allAlbumsFull`
/// to the existing fire-and-forget start* methods; targeted asset-id and `.autoExport`
/// scopes resolve immediately with `.failed` until later slices implement them.
@MainActor
struct ExportManagerRunExportTests {

  @MainActor
  private struct Harness {
    let manager: ExportManager
    let photoLib: FakePhotoLibraryService
    let dest: FakeExportDestination
    let writer: FakeAssetResourceWriter
    let store: ExportRecordStore
    let collectionStore: CollectionExportRecordStore
    let storeRoot: URL
    let userDefaultsSuite: String

    func cleanup() async {
      // Release any suspended writers before cancelling so the writer Task can complete.
      if let checkpoint = writer.checkpoint {
        await checkpoint.releaseAll()
      }
      manager.cancelAndClear()
      store.flushForTesting()
      try? FileManager.default.removeItem(at: storeRoot)
      dest.cleanup()
      UserDefaults().removePersistentDomain(forName: userDefaultsSuite)
    }
  }

  private func makeHarness() -> Harness {
    let photoLib = FakePhotoLibraryService()
    let dest = FakeExportDestination()
    let writer = FakeAssetResourceWriter()
    let fileSystem = FakeFileSystem()
    let storeRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("ExportManagerRunExport-\(UUID().uuidString)", isDirectory: true)
    let store = ExportRecordStore(baseDirectoryURL: storeRoot)
    store.configure(for: "test")
    let collectionStore = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    collectionStore.configure(for: "test")
    let suiteName = "test-ExportManagerRunExport-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let manager = ExportManager(
      photoLibraryService: photoLib,
      exportDestination: dest,
      exportRecordStore: store,
      collectionExportRecordStore: collectionStore,
      assetResourceWriter: writer,
      fileSystem: fileSystem,
      userDefaults: defaults
    )
    return Harness(
      manager: manager, photoLib: photoLib, dest: dest, writer: writer,
      store: store, collectionStore: collectionStore,
      storeRoot: storeRoot, userDefaultsSuite: suiteName)
  }

  private func makeContext(scope: ExportRunScope) -> ExportRunContext {
    ExportRunContext(
      source: .manual,
      visibility: .userVisible,
      scope: scope,
      selection: .edited
    )
  }

  // MARK: - Bookkeeping integrity

  /// Phase 3a regression gate: `VariantExporter` routes its sentinel-message failure
  /// recording through `Host.recordVariantFailed`, which is the only path that
  /// increments `activeRunBookkeeping.failedCount` and appends to
  /// `activeRunBookkeeping.failures`. If a future change routed past the host (e.g.
  /// calling `RecordStoreRouter.markVariantFailed` directly), the per-variant record
  /// would still be written but `ExportRunSummary.failedCount` / `.failures` would
  /// silently under-count — breaking AutoSync retry routing and the Export Issues UI.
  ///
  /// Reproduction: a `.timelineMonth` scope with one asset whose mediaType is `.video`
  /// has no original-side resource selector match (selectOriginalResource returns nil
  /// for video without a `.video` resource), so the variant write hits the
  /// `producer.originalFilename == nil` guard and emits a sentinel-message failure.
  @Test func sentinelFailurePopulatesRunSummaryBookkeeping() async {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }

    let asset = TestAssetFactory.makeAsset(id: "no-resource", mediaType: .video)
    // No resources seeded for the asset — variant write fails on the "no resource" guard.
    harness.photoLib.favoritesAssets = [asset]

    let summary = await harness.manager.runExport(
      context: makeContext(scope: .favoritesFull))

    // Per-variant record AND ExportRunSummary bookkeeping must both reflect the failure.
    #expect(summary.failedCount == 1,
      "VariantExporter.Host.recordVariantFailed must increment failedCount; got \(summary.failedCount)")
    #expect(!summary.failures.isEmpty,
      "summary.failures must contain the per-variant failure detail; got \(summary.failures.count)")
    #expect(summary.failures.first?.assetId == "no-resource")
  }

  // MARK: - Empty library

  /// `runExport` against an empty Photos library resolves immediately with `.completed`
  /// — `processQueueIfNeeded` early-returns on the empty queue and finalizes the run.
  @Test func timelineFullLibraryEmptyResolvesCompleted() async {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }
    // Empty `yearCounts` → availableYears() returns []; nothing to enqueue.

    let summary = await harness.manager.runExport(
      context: makeContext(scope: .timelineFullLibrary))

    #expect(summary.result == .completed)
    #expect(summary.cancelReason == nil)
    #expect(summary.enqueuedCount == 0)
    #expect(summary.completedCount == 0)
    #expect(harness.manager.activeRunContext == nil)
  }

  /// `.favoritesFull` against an empty favorites collection resolves immediately.
  @Test func favoritesFullEmptyResolvesCompleted() async {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }
    // `favoritesAssets` is empty by default.

    let summary = await harness.manager.runExport(
      context: makeContext(scope: .favoritesFull))

    #expect(summary.result == .completed)
    #expect(harness.manager.activeRunContext == nil)
  }

  /// `.allAlbumsFull` against an empty album set resolves immediately.
  @Test func allAlbumsFullEmptyResolvesCompleted() async {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }
    // `collectionTree` is empty by default.

    let summary = await harness.manager.runExport(
      context: makeContext(scope: .allAlbumsFull))

    #expect(summary.result == .completed)
    #expect(harness.manager.activeRunContext == nil)
  }

  /// Regression for the codex P2 finding: when a bulk-album run throws partway
  /// through and the partial-queue drain path runs, the summary must report
  /// `.failed`, not `.completed`. `AutoSyncReducer.coveredScopes` clears dirty
  /// state only on `.completed` summaries — a `.completed` here would hide the
  /// albums that the enqueue loop never reached from the next reconciliation.
  ///
  /// Reproduction: seed two albums; the second throws on `fetchAssets`. The
  /// first album's jobs queue, then the second throws, the catch block elects
  /// to drain the partial queue, and `partialBulkScan` flips the natural
  /// `.completed` to `.failed` in `finalizeActiveRun`.
  @Test func allAlbumsFullPartialEnqueueResolvesFailed() async {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }

    let asset = TestAssetFactory.makeAsset(id: "a1")
    harness.photoLib.assetsByAlbumLocalId["album-A"] = [asset]
    harness.photoLib.resourcesByAssetId["a1"] = [
      TestAssetFactory.makeResource(originalFilename: "a1.HEIC")
    ]
    harness.photoLib.collectionTree = [
      PhotoCollectionDescriptor(
        id: "album:album-A", localIdentifier: "album-A", title: "Album A",
        kind: .album, pathComponents: [], children: []),
      PhotoCollectionDescriptor(
        id: "album:broken-album", localIdentifier: "broken-album",
        title: "Broken", kind: .album, pathComponents: [], children: []),
    ]
    harness.photoLib.fetchAssetsErrorByAlbumId["broken-album"] = NSError(
      domain: "Test", code: 7, userInfo: [NSLocalizedDescriptionKey: "boom"])

    let summary = await harness.manager.runExport(
      context: makeContext(scope: .allAlbumsFull))

    #expect(summary.result == .failed)
    #expect(summary.completedCount >= 1)
    #expect(harness.manager.activeRunContext == nil)
  }

  /// `startExportSharedAlbum` is the per-shared-album entry point — fire-and-
  /// forget, used by the per-pane Export Shared Album button and by the
  /// reduced-fidelity AutoSync path. It must route the asset through a
  /// `.sharedAlbum` placement (so the `Collections/Shared Albums/...` path
  /// is used and the `.singleResource` variant clamp kicks in), not a regular
  /// `.album` placement. Pin both: a placement of the right kind ends up in
  /// the collection store, and the on-disk relative path uses the Shared
  /// Albums root.
  @Test func startExportSharedAlbumWritesUnderSharedAlbumsRoot() async {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }

    let asset = TestAssetFactory.makeAsset(id: "s-asset-1")
    harness.photoLib.assetsBySharedAlbumLocalId["shared-1"] = [asset]
    harness.photoLib.resourcesByAssetId["s-asset-1"] = [
      TestAssetFactory.makeResource(originalFilename: "s-asset-1.JPG")
    ]
    harness.photoLib.collectionTree = [
      PhotoCollectionDescriptor(
        id: "shared-album:shared-1", localIdentifier: "shared-1",
        title: "Family stream", kind: .sharedAlbum, pathComponents: [],
        children: [])
    ]

    harness.manager.startExportSharedAlbum(collectionId: "shared-1")
    await waitUntil(harness.manager.totalJobsCompleted >= 1)

    let placement = harness.collectionStore.placements(matching: .sharedAlbum)
      .first(where: { $0.collectionLocalIdentifier == "shared-1" })
    #expect(placement?.kind == .sharedAlbum)
    #expect(placement?.relativePath == "Collections/Shared Albums/Family stream/")
    // The user-album bucket must stay empty — a regression where the entry
    // point routed through `.album` would land the asset in
    // `Collections/Albums/...` and this assertion would fail.
    #expect(harness.collectionStore.placements(matching: .album).isEmpty)
  }

  private func waitUntil(
    timeout: TimeInterval = 5, _ condition: @autoclosure () -> Bool
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
  }

  /// Same regression guard as the user-album test above, but exercising the
  /// `.allSharedAlbumsFull` code path. The two scopes share `enqueueBulkAlbumExport`
  /// and `finalizeActiveRun`'s `partialBulkScan` check, so a single shared
  /// regression would affect both — but the AutoSync wiring (clearing
  /// `.sharedAlbums` dirty state on completed runs) lives on its own branch in
  /// `AutoSyncReducer.coveredScopes`, and pinning both gives the bug two red
  /// tests to walk through instead of one.
  @Test func allSharedAlbumsFullPartialEnqueueResolvesFailed() async {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }

    let asset = TestAssetFactory.makeAsset(id: "s1")
    harness.photoLib.assetsBySharedAlbumLocalId["shared-A"] = [asset]
    harness.photoLib.resourcesByAssetId["s1"] = [
      TestAssetFactory.makeResource(originalFilename: "s1.HEIC")
    ]
    harness.photoLib.collectionTree = [
      PhotoCollectionDescriptor(
        id: "shared-album:shared-A", localIdentifier: "shared-A",
        title: "Shared A", kind: .sharedAlbum, pathComponents: [], children: []),
      PhotoCollectionDescriptor(
        id: "shared-album:broken-shared", localIdentifier: "broken-shared",
        title: "Broken Shared", kind: .sharedAlbum, pathComponents: [],
        children: []),
    ]
    harness.photoLib.fetchAssetsErrorByAlbumId["broken-shared"] = NSError(
      domain: "Test", code: 7,
      userInfo: [NSLocalizedDescriptionKey: "shared boom"])

    let summary = await harness.manager.runExport(
      context: makeContext(scope: .allSharedAlbumsFull))

    #expect(summary.result == .failed)
    #expect(summary.completedCount >= 1)
    #expect(harness.manager.activeRunContext == nil)
  }

  // MARK: - AutoSync retry-eligibility skip (Phase 3 Slice C)

  /// AutoSync run on a destination where every asset's required variant is
  /// in retry backoff (eligibility closure returns false for all). Manager
  /// must skip enqueuing those assets and surface them as `skippedCount`
  /// rather than letting them churn the queue immediately after they fail.
  @Test func autoSyncRunSkipsAssetsWithAllVariantsInBackoff() async {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }

    // Seed two assets in July 2025.
    let asset1 = TestAssetFactory.makeAsset(
      id: "asset-1",
      creationDate: makeDate(2025, 7, 1))
    let asset2 = TestAssetFactory.makeAsset(
      id: "asset-2",
      creationDate: makeDate(2025, 7, 2))
    harness.photoLib.assetsByYearMonth["2025-7"] = [asset1, asset2]
    harness.photoLib.yearCounts = [(year: 2025, count: 2)]

    // Eligibility closure: asset-1 is ineligible (.original variant in
    // backoff); asset-2 is eligible. The run should enqueue only asset-2.
    harness.manager.autoSyncEligibilityCheck = { assetId, _, _, _ in
      assetId != "asset-1"
    }

    let summary = await harness.manager.runExport(
      context: ExportRunContext(
        source: .autoSync,
        visibility: .background,
        scope: .timelineFullLibrary,
        selection: .edited
      ))

    #expect(summary.skippedCount == 1)
    // The run completed for asset-2; asset-1 was skipped pre-enqueue.
    #expect(summary.enqueuedCount == 1)
  }

  /// Manual runs (`source == .manual`) must never gate on AutoSync retry
  /// eligibility — that's plan §"Retry": only auto-sync runs honor the
  /// retry store; a manual export is the user's explicit override.
  @Test func manualRunIgnoresEligibilityCheck() async {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }

    let asset = TestAssetFactory.makeAsset(
      id: "asset-x",
      creationDate: makeDate(2025, 7, 5))
    harness.photoLib.assetsByYearMonth["2025-7"] = [asset]
    harness.photoLib.yearCounts = [(year: 2025, count: 1)]

    // Closure returns false for everything — would skip on autoSync.
    harness.manager.autoSyncEligibilityCheck = { _, _, _, _ in false }

    let summary = await harness.manager.runExport(
      context: ExportRunContext(
        source: .manual,
        visibility: .userVisible,
        scope: .timelineFullLibrary,
        selection: .edited
      ))

    // Manual run: enqueued despite the closure returning false.
    #expect(summary.skippedCount == 0)
    #expect(summary.enqueuedCount == 1)
  }

  private func makeDate(_ y: Int, _ m: Int, _ d: Int) -> Date {
    var components = DateComponents()
    components.year = y
    components.month = m
    components.day = d
    return Calendar.current.date(from: components) ?? Date()
  }

  // MARK: - Targeted scopes (not implemented yet)

  @Test func timelineAssetsScopeResolvesFailedForNow() async {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }

    let summary = await harness.manager.runExport(
      context: makeContext(scope: .timelineAssets(["asset-1"])))

    #expect(summary.result == .failed)
    #expect(harness.manager.activeRunContext == nil)
  }

  @Test func autoExportScopeResolvesFailedForNow() async {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }

    let summary = await harness.manager.runExport(
      context: makeContext(
        scope: .autoExport(
          AutoExportScopeSelection(timeline: true, favorites: true, albums: false))))

    #expect(summary.result == .failed)
    #expect(harness.manager.activeRunContext == nil)
  }

  // MARK: - Destination-unavailable interruption

  /// `interruptForDestinationUnavailable()` resolves the active run as transient —
  /// `result == .interrupted`, `cancelReason == .destinationUnavailable` — distinct
  /// from `cancelAndClear`'s `.cancelled / .userCancelled`. AutoSync uses this signal
  /// to resume after the drive returns rather than treating queued work as failed.
  ///
  /// Deterministic via a writer checkpoint: real assets enqueue, the writer suspends
  /// on the gate, the test then fires the interrupt. No `Task.yield()` race.
  @Test func interruptForDestinationUnavailableResolvesAsInterrupted() async throws {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }

    let asset = TestAssetFactory.makeAsset(id: "interrupt-1")
    harness.photoLib.assetsByYearMonth["2025-7"] = [asset]
    harness.photoLib.yearCounts = [(year: 2025, count: 1)]
    harness.photoLib.resourcesByAssetId[asset.id] = [
      TestAssetFactory.makeResource(originalFilename: "interrupt-1.JPG")
    ]
    let writeGate = AsyncCheckpoint()
    harness.writer.checkpoint = writeGate

    async let summaryTask = harness.manager.runExport(
      context: makeContext(scope: .timelineFullLibrary))

    // Wait for the writer to arrive at the gate — the run is now actively processing.
    await writeGate.waitForEnter(count: 1)
    harness.manager.interruptForDestinationUnavailable()
    // Release the suspended writer so its Task can complete; the interrupt has already
    // resolved the awaitable continuation.
    await writeGate.releaseAll()

    let summary = await summaryTask

    #expect(summary.result == .interrupted)
    #expect(summary.cancelReason == .destinationUnavailable)
    #expect(harness.manager.activeRunContext == nil)
  }

  // MARK: - Run context surfacing

  /// `activeRunContext` is set while a run is in flight and cleared once the awaitable
  /// resolves. The published value flips through nil → ctx → nil; future SwiftUI views
  /// can observe this directly.
  @Test func activeRunContextSurfacesAndClears() async {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }

    var observedContexts: [ExportRunContext?] = []
    let cancellable = harness.manager.$activeRunContext.sink { ctx in
      observedContexts.append(ctx)
    }
    defer { cancellable.cancel() }

    let context = makeContext(scope: .timelineFullLibrary)
    _ = await harness.manager.runExport(context: context)

    // The publisher should emit: initial nil (Combine replays current value), then the
    // run's context when set, then nil again when finalize clears it.
    #expect(observedContexts.contains(where: { $0 == context }))
    #expect(harness.manager.activeRunContext == nil)
    // Last published value is nil — run cleared the context after finalize.
    if let last = observedContexts.last {
      #expect(last == nil)
    } else {
      Issue.record("Expected at least one observed value")
    }
  }
}
