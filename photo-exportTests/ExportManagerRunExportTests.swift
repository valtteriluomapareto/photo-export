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
    timeout: TimeInterval = 10, _ condition: @autoclosure () -> Bool
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

  /// Predicate-order integration pin (post-refactor cleanup). The planner unit tests
  /// pin that `isExported` runs before `shouldSkipForRetry`, but a regression in how
  /// the manager wires those predicates into the planner could silently defeat that.
  ///
  /// Setup: one asset is already `.done` in the record store; AutoSync's eligibility
  /// closure is installed but should NEVER see this asset (it was filtered by
  /// `isExported` first). If the order were reversed, `skipForAutoSyncRetry` would
  /// observe the asset and increment `skippedCount`, inflating AutoSync's "ran but
  /// found nothing to do" counter for assets that were never going to be queued.
  @Test func autoSyncRunFilterAlreadyExportedBeforeRetryCheck() async {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }

    let assetDate = makeDate(2025, 7, 1)
    let asset = TestAssetFactory.makeAsset(id: "already-done", creationDate: assetDate)
    harness.photoLib.assetsByYearMonth["2025-7"] = [asset]
    harness.photoLib.yearCounts = [(year: 2025, count: 1)]

    // Plant a `.done` original so `exportRecordStore.isExported` returns true.
    harness.store.markVariantExported(
      assetId: asset.id, variant: .original,
      year: 2025, month: 7, relPath: "2025/07/",
      filename: "X.HEIC", exportedAt: Date())

    // The eligibility closure must NOT be called for the already-done asset. Record
    // every call so the test can assert the gate never saw this asset id.
    var eligibilityCalls: [String] = []
    harness.manager.autoSyncEligibilityCheck = { assetId, _, _, _ in
      eligibilityCalls.append(assetId)
      return false  // would-be-blocking, but should never run for this asset
    }

    let summary = await harness.manager.runExport(
      context: ExportRunContext(
        source: .autoSync,
        visibility: .background,
        scope: .timelineFullLibrary,
        selection: .edited))

    #expect(!eligibilityCalls.contains("already-done"),
      "skipForAutoSyncRetry must NOT be called for already-exported assets; got calls: \(eligibilityCalls)")
    #expect(summary.skippedCount == 0,
      "already-exported asset must be filtered by isExported, not counted as a retry skip")
    #expect(summary.enqueuedCount == 0)
    #expect(summary.result == .completed)
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

  // MARK: - Videos-subfolder layout (issue #38)

  /// Load-bearing end-to-end pin for option 2: when `videoLayout = .subfolder`, the
  /// chokepoint at `ExportManager.runJob` routes standalone-video assets into the
  /// `videos/` subfolder while leaving image-mediaType assets (including Live Photos
  /// and their paired motion) at the bare placement path. This is the entire
  /// promise the Settings caption makes.
  ///
  /// The asserts read both on-disk file existence (which `FakeAssetResourceWriter`
  /// materialises) AND the per-variant `subfolder` field on the persisted record
  /// (which reuse-source and reconcile consult). A regression that mis-routed
  /// either side would fail this test.
  @Test func videoLayoutSubfolderRoutesStandaloneVideosOnlyLivePhotosStayPaired() async {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }

    // Three assets in the same month so a single export run exercises all three:
    let photo = TestAssetFactory.makeAsset(
      id: "photo-1", mediaType: .image, isLivePhoto: false)
    let standaloneVideo = TestAssetFactory.makeAsset(
      id: "video-1", mediaType: .video, isLivePhoto: false)
    let livePhoto = TestAssetFactory.makeAsset(
      id: "live-1", mediaType: .image, isLivePhoto: true)

    harness.photoLib.assetsByYearMonth["2026-3"] = [photo, standaloneVideo, livePhoto]
    harness.photoLib.resourcesByAssetId["photo-1"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_PHOTO.JPG")
    ]
    harness.photoLib.resourcesByAssetId["video-1"] = [
      TestAssetFactory.makeResource(type: .video, originalFilename: "IMG_VIDEO.MOV")
    ]
    harness.photoLib.resourcesByAssetId["live-1"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_LIVE.HEIC"),
      TestAssetFactory.makeResource(type: .pairedVideo, originalFilename: "IMG_LIVE.MOV"),
    ]

    harness.manager.videoLayout = .subfolder
    harness.manager.livePhotosPairedExport = true

    harness.manager.startExportMonth(year: 2026, month: 3)
    await waitUntil(harness.manager.totalJobsCompleted >= 3)

    let root = harness.dest.rootURL
    let monthDir = root.appendingPathComponent("2026/03", isDirectory: true)
    let videosDir = monthDir.appendingPathComponent("videos", isDirectory: true)
    let fm = FileManager.default

    // Photo stays at the bare month path.
    #expect(fm.fileExists(atPath: monthDir.appendingPathComponent("IMG_PHOTO.JPG").path))
    // Standalone video lands in the subfolder.
    #expect(fm.fileExists(atPath: videosDir.appendingPathComponent("IMG_VIDEO.MOV").path))
    // Live Photo still and paired motion BOTH stay at the bare month path — the
    // load-bearing carve-out. A bug that routed `.MOV` files unconditionally would
    // put the motion in `videos/` and fail this assertion.
    #expect(fm.fileExists(atPath: monthDir.appendingPathComponent("IMG_LIVE.HEIC").path))
    #expect(fm.fileExists(atPath: monthDir.appendingPathComponent("IMG_LIVE.MOV").path))
    // And the subfolder is NOT a sibling of the Live Photo motion file.
    #expect(!fm.fileExists(atPath: videosDir.appendingPathComponent("IMG_LIVE.MOV").path))

    // Per-variant `subfolder` on persisted records mirrors the on-disk layout.
    // Reuse-source and reconcile consult these directly.
    let photoRecord = harness.store.exportInfo(assetId: "photo-1")
    let videoRecord = harness.store.exportInfo(assetId: "video-1")
    let liveRecord = harness.store.exportInfo(assetId: "live-1")
    #expect(photoRecord?.variants[.original]?.subfolder == nil)
    #expect(videoRecord?.variants[.original]?.subfolder == "videos")
    #expect(liveRecord?.variants[.original]?.subfolder == nil)
    #expect(liveRecord?.variants[.originalPairedVideo]?.subfolder == nil)
  }

  /// Mid-life same-placement re-run for a standalone video: export under `.flat`,
  /// flip to `.subfolder`, re-export the same month. The asset is already `.done`
  /// (the `videoLayout` toggle does not widen `requiredVariants`), so the second
  /// run skips it — no relocation, no second file in `videos/`, the record's
  /// `subfolder == nil` from the first write is left intact.
  @Test func videoLayoutFlipAfterFlatExportDoesNotRelocateOrDoubleWrite() async {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }

    let asset = TestAssetFactory.makeAsset(
      id: "vid-flip", mediaType: .video, isLivePhoto: false)
    harness.photoLib.assetsByYearMonth["2026-3"] = [asset]
    harness.photoLib.resourcesByAssetId["vid-flip"] = [
      TestAssetFactory.makeResource(type: .video, originalFilename: "IMG_FLIP.MOV")
    ]

    // First export under .flat — lands at bare month path.
    harness.manager.videoLayout = .flat
    harness.manager.startExportMonth(year: 2026, month: 3)
    await waitUntil(harness.manager.totalJobsCompleted >= 1)

    let root = harness.dest.rootURL
    let flatPath = root.appendingPathComponent("2026/03/IMG_FLIP.MOV").path
    let subfolderPath = root.appendingPathComponent("2026/03/videos/IMG_FLIP.MOV").path
    let fm = FileManager.default
    #expect(fm.fileExists(atPath: flatPath))
    #expect(!fm.fileExists(atPath: subfolderPath))

    let firstWriteCount = harness.writer.writeCalls.count

    // Flip the layout. The asset is still `.done` — `requiredVariants` doesn't widen.
    // The `didSet` on `videoLayout` calls `clearEmptyRunMessage()`, so the message
    // starts nil for the second run; waiting for the "already exported" message to
    // appear is a deterministic signal that `startExportMonth` reached
    // `enqueueMonth`, the planner returned `.alreadyComplete`, and the empty-run
    // banner was set. Beats `Task.sleep`-based settle windows that race the
    // fire-and-forget task's tail.
    harness.manager.videoLayout = .subfolder
    harness.manager.startExportMonth(year: 2026, month: 3)
    await waitUntil(harness.manager.emptyRunMessage == "This month is already exported.")

    // No second file, no second write call, no record mutation.
    #expect(fm.fileExists(atPath: flatPath))
    #expect(!fm.fileExists(atPath: subfolderPath))
    #expect(harness.writer.writeCalls.count == firstWriteCount)
    let record = harness.store.exportInfo(assetId: "vid-flip")
    #expect(record?.variants[.original]?.subfolder == nil)
  }

  /// Mid-life synthesizer policy (plan §6): a standalone video has `.original`
  /// already done at the bare path (the user exported under `.flat`). Photos
  /// then exposes an edit on the same asset and the user has flipped
  /// `videoLayout` to `.subfolder`. A fresh export run needs to write `.edited`.
  ///
  /// Pinned invariants:
  /// - The `.edited` file lands in `2026/03/videos/`, not the bare path.
  /// - The new `.edited` variant record carries `subfolder = "videos"`.
  /// - The previously-written `.original` variant record's `subfolder` stays
  ///   `nil` — its file is still at the bare path on disk, and a future
  ///   reuse-source or reconcile lookup for `.original` must find it there.
  ///
  /// Without per-variant `subfolder`, the shared `ExportRecord.relPath` would
  /// be overwritten to `2026/03/videos/` on the `.edited` write, mis-locating
  /// the `.original` variant on the next reconcile and silently pruning it.
  @Test func videoLayoutMidLifeSynthesizerWritesEditedToSubfolderKeepsOriginalAtBase() async {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }

    // Adjusted standalone video. Two resources: the original `.video` plus a
    // `.fullSizeVideo` so `selectEditedProducer` returns `.resource(...)` and
    // the edited byte source flows through `FakeAssetResourceWriter`. Without
    // `.fullSizeVideo`, the producer takes the `.render` branch which the
    // fake writer doesn't service.
    let asset = TestAssetFactory.makeAsset(
      id: "video-mid-life", mediaType: .video, hasAdjustments: true,
      isLivePhoto: false)
    harness.photoLib.assetsByYearMonth["2026-3"] = [asset]
    harness.photoLib.resourcesByAssetId["video-mid-life"] = [
      TestAssetFactory.makeResource(type: .video, originalFilename: "IMG_ML.MOV"),
      TestAssetFactory.makeResource(
        type: .fullSizeVideo, originalFilename: "IMG_ML.MOV"),
    ]

    // Pre-plant the `.original` variant as already exported under `.flat` —
    // file conceptually at `2026/03/IMG_ML.MOV`, record carries `subfolder = nil`.
    // The test does not need the file to exist on disk; the chokepoint only
    // reads `existingVariants` from the store.
    harness.store.markVariantExported(
      assetId: "video-mid-life", variant: .original,
      year: 2026, month: 3, relPath: "2026/03/",
      filename: "IMG_ML.MOV", exportedAt: Date(), subfolder: nil)

    // User flips the layout. The `.original` record stays as-is; only the
    // missing `.edited` will run this round.
    harness.manager.videoLayout = .subfolder

    harness.manager.startExportMonth(year: 2026, month: 3)
    await waitUntil(harness.manager.totalJobsCompleted >= 1)

    let root = harness.dest.rootURL
    let videosDir = root.appendingPathComponent("2026/03/videos", isDirectory: true)
    let fm = FileManager.default

    // `.edited` lands in the subfolder.
    #expect(fm.fileExists(atPath: videosDir.appendingPathComponent("IMG_ML.MOV").path))

    // Per-variant subfolder is correct on both variants. `.edited` carries
    // `"videos"`; `.original` is untouched at `nil` (the load-bearing assertion
    // — without per-variant storage this would now read `"videos"` from the
    // shared `record.relPath`).
    let record = harness.store.exportInfo(assetId: "video-mid-life")
    #expect(record?.variants[.original]?.subfolder == nil)
    #expect(record?.variants[.edited]?.subfolder == "videos")
    // `.original`'s filename also stays put.
    #expect(record?.variants[.original]?.filename == "IMG_ML.MOV")
  }

  // MARK: - Per-year manual export (Export Year button)

  /// End-to-end coverage for `startExportYear(year:)`. `ExportJobPlannerTests` pins the
  /// pure month-derivation logic in `planTimelineYear`, but the orchestration that wires
  /// the Timeline sidebar's "Export Year" button through `enqueueYear` → planner →
  /// queue → on-disk YYYY/MM placement is otherwise untested. A regression that silently
  /// returned early from `startExportYear`, swallowed the `Task` body, or mis-routed
  /// jobs to the wrong month placement would pass every other timeline test.
  ///
  /// Three assets in three different months of the same year so the planner exercises
  /// the per-asset month derivation and the queue fans them out to three distinct
  /// `2025/MM/` directories.
  @Test func startExportYearWritesEachMonthInYYYYMMStructure() async {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }

    let march = TestAssetFactory.makeAsset(
      id: "asset-march", creationDate: makeDate(2025, 3, 12))
    let june = TestAssetFactory.makeAsset(
      id: "asset-june", creationDate: makeDate(2025, 6, 1))
    let september = TestAssetFactory.makeAsset(
      id: "asset-sept", creationDate: makeDate(2025, 9, 30))

    // `fetchAssets(year:month:nil)` in the fake concatenates every month bucket for
    // the year, so seeding one asset per month bucket gives `enqueueYear` the full
    // year set in one call.
    harness.photoLib.assetsByYearMonth["2025-3"] = [march]
    harness.photoLib.assetsByYearMonth["2025-6"] = [june]
    harness.photoLib.assetsByYearMonth["2025-9"] = [september]
    harness.photoLib.resourcesByAssetId["asset-march"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "MARCH.HEIC")
    ]
    harness.photoLib.resourcesByAssetId["asset-june"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "JUNE.HEIC")
    ]
    harness.photoLib.resourcesByAssetId["asset-sept"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "SEPT.HEIC")
    ]

    harness.manager.startExportYear(year: 2025)
    await waitUntil(harness.manager.totalJobsCompleted >= 3)

    let root = harness.dest.rootURL
    let fm = FileManager.default
    #expect(fm.fileExists(
      atPath: root.appendingPathComponent("2025/03/MARCH.HEIC").path))
    #expect(fm.fileExists(
      atPath: root.appendingPathComponent("2025/06/JUNE.HEIC").path))
    #expect(fm.fileExists(
      atPath: root.appendingPathComponent("2025/09/SEPT.HEIC").path))

    // Per-record year/month must match the asset's creationDate, not the year arg —
    // a planner bug that planted every job under `2025/01/` would still satisfy the
    // queue-count expectation above but would fail these.
    #expect(harness.store.exportInfo(assetId: "asset-march")?.month == 3)
    #expect(harness.store.exportInfo(assetId: "asset-june")?.month == 6)
    #expect(harness.store.exportInfo(assetId: "asset-sept")?.month == 9)
  }
}
