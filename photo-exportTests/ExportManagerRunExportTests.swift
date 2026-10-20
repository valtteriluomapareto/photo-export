import Combine
import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Phase 0a (auto-sync plan): the awaitable `runExport(context:) async -> ExportRunSummary`
/// API. MVP coverage maps `.timelineFullLibrary`, `.favoritesFull`, and `.allAlbumsFull`
/// to the existing fire-and-forget start* methods; targeted asset-id and `.autoExport`
/// scopes resolve immediately with `.failed` until later slices implement them.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct ExportManagerRunExportTests {

  enum FullScope: CaseIterable, Sendable {
    case timeline
    case favorites
    case albums
    case sharedAlbums

    var runScope: ExportRunScope {
      switch self {
      case .timeline: .timelineFullLibrary
      case .favorites: .favoritesFull
      case .albums: .allAlbumsFull
      case .sharedAlbums: .allSharedAlbumsFull
      }
    }
  }

  @MainActor
  private struct Harness {
    let manager: ExportManager
    let photoLib: FakePhotoLibraryService
    let dest: FakeExportDestination
    let writer: FakeAssetResourceWriter
    let store: ExportRecordStore
    let collectionStore: CollectionExportRecordStore
    let storeRoot: URL

    func cleanup() async {
      var running = manager.currentPreparationTasks + [manager.currentTask].compactMap { $0 }
      // Release any suspended writers before cancelling so the writer Task can complete.
      if let checkpoint = writer.checkpoint {
        await checkpoint.releaseAll()
      }
      manager.cancelAndClear()
      running += manager.currentPreparationTasks + [manager.currentTask].compactMap { $0 }
      // The cancelled work must stop before its store folder is removed.
      for task in running { _ = await finished(task) }
      store.flushForTesting()
      collectionStore.flushForTesting()
      try? FileManager.default.removeItem(at: storeRoot)
      dest.cleanup()
    }
  }

  private func makeHarness() -> Harness {
    let photoLib = FakePhotoLibraryService()
    let dest = FakeExportDestination()
    let writer = FakeAssetResourceWriter()
    let fileSystem = FakeFileSystem()
    let storeRoot = TestScratch.directory("ExportManagerRunExport")
    let store = ExportRecordStore(baseDirectoryURL: storeRoot)
    store.configure(for: "test")
    let collectionStore = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    collectionStore.configure(for: "test")
    let defaults = TestScratch.defaults("ExportManagerRunExport")
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
      storeRoot: storeRoot)
  }

  private func makeContext(scope: ExportRunScope) -> ExportRunContext {
    ExportRunContext(
      source: .manual,
      visibility: .userVisible,
      scope: scope,
      selection: .edited
    )
  }

  private func seedAssets(_ assets: [AssetDescriptor], for scope: FullScope, in harness: Harness) {
    switch scope {
    case .timeline:
      harness.photoLib.yearCounts = [(2025, assets.count)]
      harness.photoLib.assetsByYearMonth["2025-1"] = assets
    case .favorites:
      harness.photoLib.favoritesAssets = assets
    case .albums, .sharedAlbums:
      let shared = scope == .sharedAlbums
      let id = shared ? "shared-1" : "album-1"
      harness.photoLib.collectionTree = [
        PhotoCollectionDescriptor(
          id: "\(shared ? "shared-album" : "album"):\(id)",
          localIdentifier: id, title: "Test album",
          kind: shared ? .sharedAlbum : .album, pathComponents: [], children: [])
      ]
      if shared {
        harness.photoLib.assetsBySharedAlbumLocalId[id] = assets
      } else {
        harness.photoLib.assetsByAlbumLocalId[id] = assets
      }
    }
    for asset in assets {
      harness.photoLib.resourcesByAssetId[asset.id] = [
        TestAssetFactory.makeResource(originalFilename: "\(asset.id).JPG")
      ]
    }
  }

  private func startLegacyExport(for scope: FullScope, in harness: Harness) {
    switch scope {
    case .timeline: harness.manager.startExportAll()
    case .favorites: harness.manager.startExportFavorites()
    case .albums: harness.manager.startExportAllAlbums()
    case .sharedAlbums: harness.manager.startExportAllSharedAlbums()
    }
  }

  enum ProgressiveScope: CaseIterable, Sendable { case month, year, favorites, album, shared }

  @Test(arguments: ProgressiveScope.allCases)
  func enqueueUsesProgressiveAssetsAcrossEveryScope(scope: ProgressiveScope) async throws {
    let harness = makeHarness()
    let gate = AsyncCheckpoint()
    harness.writer.checkpoint = gate
    let assets = ["stream-a", "stream-b", "legacy-only"].map {
      TestAssetFactory.makeAsset(id: $0, creationDate: makeDate(2025, 1, 1))
    }
    let full: FullScope =
      switch scope {
      case .month, .year: .timeline
      case .favorites: .favorites
      case .album: .albums
      case .shared: .sharedAlbums
      }
    seedAssets(assets, for: full, in: harness)
    harness.photoLib.progressiveStreamOverride = { _ in
      AsyncThrowingStream { continuation in
        continuation.yield([assets[0]])
        continuation.yield([assets[1]])
        continuation.finish()
      }
    }
    switch scope {
    case .month: harness.manager.startExportMonth(year: 2025, month: 1)
    case .year: harness.manager.startExportYear(year: 2025)
    case .favorites: harness.manager.startExportFavorites()
    case .album: harness.manager.startExportAlbum(collectionId: "album-1")
    case .shared: harness.manager.startExportSharedAlbum(collectionId: "shared-1")
    }
    await gate.waitForEnter(count: 1)
    let manager = harness.manager
    manager.pause()
    let ids = Set(
      manager.pendingJobs.map(\.assetLocalIdentifier) + [manager.currentJobAssetId ?? ""])
    #expect(ids == ["stream-a", "stream-b"])
    #expect(manager.totalJobsEnqueued == 2)
    if let queued = manager.pendingJobs.first {
      let expected: ExportPlacement.Kind =
        switch scope {
        case .month, .year: .timeline
        case .favorites: .favorites
        case .album: .album
        case .shared: .sharedAlbum
        }
      #expect(queued.placement.kind == expected)
    }
    await gate.releaseAll()
    manager.resume()
    await manager.waitForQueueDrained()
    await harness.cleanup()
  }

  @Test func progressiveLateFailureDoesNotCommitJobsMetadataOrRetrySkips() async {
    let harness = makeHarness()
    let assets = ["eligible", "blocked"].map {
      TestAssetFactory.makeAsset(id: $0, creationDate: makeDate(2025, 1, 1))
    }
    seedAssets(assets, for: .albums, in: harness)
    harness.photoLib.progressiveStreamOverride = { _ in
      AsyncThrowingStream { continuation in
        continuation.yield(assets)
        continuation.finish(throwing: CocoaError(.fileReadUnknown))
      }
    }
    harness.manager.autoSyncEligibilityCheck = { id, _, _, _ in id != "blocked" }
    let context = ExportRunContext(
      source: .autoSync, visibility: .background, scope: .allAlbumsFull, selection: .edited)
    let summary = await harness.manager.runExport(context: context)
    #expect(summary.result == .failed)
    #expect(summary.enqueuedCount == 0)
    #expect(summary.skippedCount == 0)
    #expect(harness.collectionStore.placements.isEmpty)
    #expect(harness.writer.writeCalls.isEmpty)
    await harness.cleanup()
  }

  @Test func oversizedProgressiveBatchYieldsBeforePlanningEveryAsset() async {
    let harness = makeHarness()
    let assets = (0..<501).map {
      TestAssetFactory.makeAsset(id: "large-\($0)", creationDate: makeDate(2025, 1, 1))
    }
    seedAssets(assets, for: .favorites, in: harness)
    let terminated = AsyncStream<Bool>.makeStream()
    var heldContinuation: AsyncThrowingStream<[AssetDescriptor], any Error>.Continuation?
    harness.photoLib.progressiveStreamOverride = { _ in
      AsyncThrowingStream { continuation in
        heldContinuation = continuation
        continuation.onTermination = { _ in terminated.continuation.yield(true) }
        continuation.yield(assets)
      }
    }
    var probes = 0
    var probesAtHeartbeat = 0
    harness.manager.autoSyncEligibilityCheck = { _, _, _, _ in
      probes += 1
      if probes == 1 {
        Task(priority: .high) { @MainActor in
          probesAtHeartbeat = probes
          harness.manager.cancelAndClear()
        }
      }
      return false
    }
    let context = ExportRunContext(
      source: .autoSync, visibility: .background, scope: .favoritesFull, selection: .edited)
    let run = Task(priority: .background) { await harness.manager.runExport(context: context) }
    let summary = await run.value
    #expect(probesAtHeartbeat > 0 && probesAtHeartbeat < assets.count)
    #expect(probes < 501)
    #expect(summary.result == .cancelled)
    #expect(
      summary.skippedCount == 0, "uncommitted staged skip counts belong to the abandoned scope")
    #expect(harness.manager.pendingJobs.isEmpty)
    let timeout = Task {
      do {
        try await Task.sleep(for: .seconds(5))
        terminated.continuation.yield(false)
      } catch {}
    }
    var terminationIterator = terminated.stream.makeAsyncIterator()
    #expect(await terminationIterator.next() == true, "stale consumer must terminate its producer")
    timeout.cancel()
    heldContinuation?.finish()
    await harness.cleanup()
  }

  @Test func progressiveScopeCommitsOnlyAfterCompletionAndKeepsClickTimeSettings() async {
    let harness = makeHarness()
    let assets = ["first", "second"].map {
      TestAssetFactory.makeAsset(id: $0, creationDate: makeDate(2025, 1, 1), isLivePhoto: true)
    }
    seedAssets(assets, for: .albums, in: harness)
    let stream = AsyncThrowingStream<[AssetDescriptor], any Error>.makeStream()
    harness.photoLib.progressiveStreamOverride = { _ in stream.stream }
    let planned = AsyncCheckpoint()
    harness.manager.autoSyncEligibilityCheck = { _, _, _, _ in
      Task { await planned.enter() }
      return true
    }
    let finished = AsyncStream<Void>.makeStream()
    let observation = harness.manager.$isEnqueueingAll.dropFirst().filter { !$0 }.sink { _ in
      finished.continuation.yield(())
    }
    harness.manager.livePhotosPairedExport = true
    harness.manager.videoLayout = .subfolder
    let context = ExportRunContext(
      source: .autoSync, visibility: .background, scope: .allAlbumsFull,
      selection: .editedWithOriginals)
    let task = Task { await harness.manager.runExport(context: context) }
    stream.continuation.yield([assets[0]])
    await planned.waitForEnter(count: 1)
    harness.manager.queueCoordinator.pause()
    #expect(harness.manager.pendingJobs.isEmpty)
    #expect(harness.collectionStore.placements.isEmpty)
    harness.manager.livePhotosPairedExport = false
    harness.manager.videoLayout = .flat
    harness.manager.versionSelection = .edited
    stream.continuation.yield([assets[1]])
    stream.continuation.finish()
    var iterator = finished.stream.makeAsyncIterator()
    _ = await iterator.next()
    #expect(harness.manager.pendingJobs.map(\.assetLocalIdentifier) == ["first", "second"])
    #expect(
      harness.manager.pendingJobs.allSatisfy {
        $0.selection == .editedWithOriginals && $0.livePhotosPaired && $0.videoLayout == .subfolder
      })
    #expect(harness.collectionStore.placements.count == 1)
    observation.cancel()
    await planned.releaseAll()
    harness.manager.cancelAndClear()
    _ = await task.value
    await harness.cleanup()
  }

  @Test func preparationHandlesCoverOverlappingScopesCompletingOutOfOrder() async throws {
    let harness = makeHarness()
    let oldGate = AsyncCheckpoint()
    let freshGate = AsyncCheckpoint()
    let writerGate = AsyncCheckpoint()
    harness.writer.checkpoint = writerGate
    harness.photoLib.fetchAssetsCheckpointByYear = [2024: oldGate, 2025: freshGate]
    for year in [2024, 2025] {
      let asset = TestAssetFactory.makeAsset(id: "\(year)", creationDate: makeDate(year, 1, 1))
      harness.photoLib.assetsByYearMonth["\(year)-1"] = [asset]
      harness.photoLib.resourcesByAssetId[asset.id] = [TestAssetFactory.makeResource()]
    }
    harness.manager.startExportMonth(year: 2024, month: 1)
    harness.manager.startExportMonth(year: 2025, month: 1)
    #expect(harness.manager.currentPreparationTasks.count == 2)
    await oldGate.waitForEnter(count: 1)
    await freshGate.waitForEnter(count: 1)
    await freshGate.releaseAll()
    await writerGate.waitForEnter(count: 1)
    #expect(harness.manager.currentPreparationTasks.count == 1)
    let remaining = try #require(harness.manager.currentPreparationTasks.first)
    let drain = Task { await harness.manager.waitForQueueDrained() }
    await oldGate.releaseAll()
    await remaining.value
    #expect(harness.manager.currentPreparationTasks.isEmpty)
    await writerGate.releaseAll()
    await drain.value
    #expect(harness.manager.totalJobsCompleted == 2)
    await harness.cleanup()
  }

  @Test(arguments: [
    LibrarySelection.timelineYear(year: 2025), .timelineMonth(year: 2025, month: 1),
    .favorites, .album(collectionId: "album"), .sharedAlbum(collectionId: "shared"),
    .folder(collectionId: "folder"),
  ])
  func selectionDispatcherUsesLiteralPlacements(selection: LibrarySelection) async {
    let harness = makeHarness()
    let january = TestAssetFactory.makeAsset(id: "same", creationDate: makeDate(2025, 1, 1))
    let february = TestAssetFactory.makeAsset(id: "feb", creationDate: makeDate(2025, 2, 1))
    harness.photoLib.assetsByYearMonth = ["2025-1": [january], "2025-2": [february]]
    harness.photoLib.favoritesAssets = [january]
    harness.photoLib.assetsByAlbumLocalId = ["album": [january], "child": [january]]
    harness.photoLib.assetsBySharedAlbumLocalId = ["shared": [january]]
    let album = PhotoCollectionDescriptor(
      id: "album:album", localIdentifier: "album", title: "Owned",
      kind: .album, pathComponents: [], children: [])
    let child = PhotoCollectionDescriptor(
      id: "album:child", localIdentifier: "child", title: "Nested",
      kind: .album, pathComponents: ["Folder"], children: [])
    harness.photoLib.collectionTree = [
      album,
      PhotoCollectionDescriptor(
        id: "shared-album:shared", localIdentifier: "shared", title: "Shared",
        kind: .sharedAlbum, pathComponents: [], children: []),
      PhotoCollectionDescriptor(
        id: "folder:folder", localIdentifier: "folder", title: "Folder",
        kind: .folder, pathComponents: [], children: [child]),
    ]
    harness.manager.queueCoordinator.pause()
    harness.manager.startExport(selection: selection)
    for task in harness.manager.currentPreparationTasks { await task.value }
    let expected: Set<String> =
      switch selection {
      case .timelineYear: ["2025/01/|same", "2025/02/|feb"]
      case .timelineMonth: ["2025/01/|same"]
      case .favorites: ["Collections/Favorites/|same"]
      case .album: ["Collections/Albums/Owned/|same"]
      case .sharedAlbum: ["Collections/Shared Albums/Shared/|same"]
      case .folder: ["Collections/Albums/Folder/Nested/|same"]
      }
    #expect(
      Set(
        harness.manager.pendingJobs.map {
          $0.placement.relativePath + "|" + $0.assetLocalIdentifier
        }) == expected)
    if case .sharedAlbum = selection {
      #expect(
        harness.manager.pendingJobs.allSatisfy {
          $0.placement.kind.variantPolicy == .singleResource
        })
    }
    await harness.cleanup()
  }

  // MARK: - Stale bulk-task ownership (issue #140)

  /// A normal late fetch result and a late fetch error both belong to A.
  /// Await A's actual enqueue task before inspecting B, so the assertions
  /// cannot pass merely because A's epilogue has not run yet.
  enum LateFetchMode: CaseIterable, Sendable {
    case legacySuccess, legacyFailure, streamSuccess, streamFailure
  }

  @Test(arguments: LateFetchMode.allCases, [false, true])
  func staleBulkFetchCannotMutateReplacementRun(mode: LateFetchMode, hasQueuedJobs: Bool)
    async throws
  {
    let throwsError = mode == .legacyFailure || mode == .streamFailure
    let progressive = mode == .streamSuccess || mode == .streamFailure
    let harness = makeHarness()
    let manager = harness.manager
    let oldFetch = AsyncCheckpoint()
    let newFetch = AsyncCheckpoint()
    let writerGate = AsyncCheckpoint()
    harness.writer.checkpoint = writerGate
    try await withCleanup {
      harness.photoLib.yearCounts = [(2023, 1)]
      harness.photoLib.fetchAssetsCheckpointByYear[2023] = oldFetch
      if progressive {
        harness.photoLib.progressiveStreamOverride = { scope in
          guard scope == .timeline(year: 2023, month: nil) else { return nil }
          return AsyncThrowingStream { continuation in
            let producer = Task {
              continuation.yield([
                TestAssetFactory.makeAsset(
                  id: "staged-old", creationDate: makeDate(2023, 1, 1))
              ])
              await oldFetch.enter()
              if throwsError {
                continuation.finish(throwing: CocoaError(.fileReadUnknown))
              } else {
                continuation.yield([
                  TestAssetFactory.makeAsset(
                    id: "late-old", creationDate: makeDate(2023, 1, 1))
                ])
                continuation.finish()
              }
            }
            continuation.onTermination = { _ in producer.cancel() }
          }
        }
      }
      if throwsError {
        harness.photoLib.fetchAssetsErrorByYear[2023] = NSError(domain: "OldFetch", code: 1)
      }
      let oldTask = try #require(manager.startExportAll())
      await oldFetch.waitForEnter(count: 1)
      manager.cancelAndClear()

      let asset = TestAssetFactory.makeAsset(id: "replacement", creationDate: makeDate(2025, 1, 1))
      harness.photoLib.assetsByYearMonth["2025-1"] = [asset]
      harness.photoLib.resourcesByAssetId[asset.id] = [
        TestAssetFactory.makeResource(originalFilename: "replacement.JPG")
      ]
      harness.photoLib.yearCounts = hasQueuedJobs ? [(2025, 1), (2024, 0)] : [(2025, 1)]
      harness.photoLib.fetchAssetsCheckpointByYear[hasQueuedJobs ? 2024 : 2025] = newFetch
      let context = makeContext(scope: .timelineFullLibrary)
      var completions: [ExportRunSummary] = []
      let subscription = manager.completedRunsPublisher.sink { completions.append($0) }
      defer { subscription.cancel() }
      async let replacement = manager.runExport(context: context)
      await newFetch.waitForEnter(count: 1)

      let pendingJobs = manager.pendingJobs
      let generation = manager.generation
      #expect(pendingJobs.count == (hasQueuedJobs ? 1 : 0))
      #expect(manager.isEnqueueingAll)
      #expect(manager.activeRunContext == context)
      await oldFetch.releaseAll()
      await oldTask.value

      #expect(manager.generation == generation)
      #expect(manager.currentPreparationTasks.count == 1, "A must leave B preparation registered")
      #expect(manager.isEnqueueingAll)
      #expect(manager.activeRunContext == context)
      #expect(manager.pendingJobs == pendingJobs)
      #expect(manager.queueCount == pendingJobs.count)
      #expect(manager.totalJobsEnqueued == pendingJobs.count)
      #expect(manager.totalJobsCompleted == 0)
      #expect(!manager.isRunning)
      #expect(!manager.isProcessing)
      #expect(manager.queueWarningMessage == nil)
      #expect(manager.emptyRunMessage == nil)
      #expect(completions.isEmpty, "A must not resolve B's continuation")

      await newFetch.releaseAll()
      await writerGate.releaseAll()
      let summary = await replacement
      #expect(summary.context == context)
      #expect(summary.result == .completed, "A must not mark B as a partial scan")
      #expect(summary.enqueuedCount == 1)
      #expect(summary.completedCount == 1)
      #expect(summary.failedCount == 0)
      #expect(summary.failures.isEmpty)
      #expect(completions == [summary], "B must complete exactly once")
    } cleanup: {
      await oldFetch.releaseAll()
      await newFetch.releaseAll()
      await harness.cleanup()
    }
  }

  @Test(arguments: [false, true])
  func bulkTaskCancelledBeforeStartingCannotClearReplacementEnqueueFlag(supersede: Bool)
    async throws
  {
    let harness = makeHarness()
    let gate = AsyncCheckpoint()
    try await withCleanup {
      harness.photoLib.yearCounts = [(2025, 0)]
      harness.photoLib.fetchAssetsCheckpointByYear[2025] = gate

      // All three calls are synchronous on MainActor: A cannot start before
      // cancellation and B's enqueue flag is set before we yield to A.
      let oldTask = try #require(harness.manager.startExportAll())
      if supersede {
        harness.manager.supersedeForManualRun()
      } else {
        harness.manager.cancelAndClear()
      }
      let replacementTask = try #require(harness.manager.startExportAll())
      await oldTask.value
      #expect(harness.manager.isEnqueueingAll)
      await gate.waitForEnter(count: 1)
      #expect(harness.photoLib.fetchAssetsCalls.count == 1, "Only B should fetch")
      #expect(harness.manager.isEnqueueingAll)
      await gate.releaseAll()
      await replacementTask.value
      #expect(!harness.manager.isEnqueueingAll)
      #expect(!harness.manager.hasActiveExportWork)
    } cleanup: {
      await gate.releaseAll()
      await harness.cleanup()
    }
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
    await withCleanup {
      let asset = TestAssetFactory.makeAsset(id: "no-resource", mediaType: .video)
      // No resources seeded for the asset — variant write fails on the "no resource" guard.
      harness.photoLib.favoritesAssets = [asset]

      let summary = await harness.manager.runExport(
        context: makeContext(scope: .favoritesFull))

      // Per-variant record AND ExportRunSummary bookkeeping must both reflect the failure.
      #expect(
        summary.failedCount == 1,
        "VariantExporter.Host.recordVariantFailed must increment failedCount; got \(summary.failedCount)"
      )
      #expect(
        !summary.failures.isEmpty,
        "summary.failures must contain the per-variant failure detail; got \(summary.failures.count)")
      #expect(summary.failures.first?.assetId == "no-resource")
    } cleanup: {
      await harness.cleanup()
    }
  }

  @Test func persistenceFailureCannotReportSuccessfulRun() async throws {
    let harness = makeHarness()
    try await withCleanup {
      let checkpoint = AsyncCheckpoint()
      harness.writer.checkpoint = checkpoint
      let asset = TestAssetFactory.makeAsset(id: "persistence-failure")
      harness.photoLib.favoritesAssets = [asset]
      harness.photoLib.resourcesByAssetId[asset.id] = [
        TestAssetFactory.makeResource(type: .photo, originalFilename: "A.jpg")
      ]
      let task = Task {
        await harness.manager.runExport(context: makeContext(scope: .favoritesFull))
      }
      await checkpoint.waitForEnter(count: 1)
      try await harness.collectionStore.flush()
      let log = harness.storeRoot.appendingPathComponent("test/collection-records.jsonl")
      try FileManager.default.removeItem(at: log)
      try FileManager.default.createDirectory(at: log, withIntermediateDirectories: false)
      await checkpoint.releaseAll()
      let summary = await task.value
      #expect(summary.result == .failed)
      #expect(harness.collectionStore.state == .persistenceFailed)
      #expect(!harness.manager.canExportCollection)
      #expect(harness.manager.canExportTimeline)
      #expect(!harness.manager.hasActiveExportWork)
      #expect(
        harness.collectionStore.exportInfo(assetId: asset.id, placement: .favorites())?
          .variants[.original]?.status == .done)
      try FileManager.default.removeItem(at: log)
      harness.collectionStore.retryPersistence()
      #expect(harness.collectionStore.state == .ready)
      harness.collectionStore.configure(for: "test")
      #expect(
        harness.collectionStore.exportInfo(assetId: asset.id, placement: .favorites())?
          .variants[.original]?.status == .done)
      let retry = await harness.manager.runExport(context: makeContext(scope: .favoritesFull))
      #expect(retry.result == .completed)
      #expect(harness.writer.writeCalls.count == 1)
    } cleanup: {
      await harness.cleanup()
    }
  }

  /// A second `runExport` while one is active is rejected with a `.failed` summary for its
  /// own context instead of trapping. The active run keeps ownership and completes.
  @Test(.timeLimit(.minutes(1)))
  func concurrentRunExportIsRejectedWithoutDisturbingTheActiveRun() async throws {
    let harness = makeHarness()
    try await withCleanup {
      let gate = AsyncCheckpoint()
      harness.writer.checkpoint = gate
      let asset = TestAssetFactory.makeAsset(id: "held", creationDate: makeDate(2025, 1, 1))
      seedAssets([asset], for: .timeline, in: harness)
      var completions: [ExportRunSummary] = []
      let subscription = harness.manager.completedRunsPublisher.sink { completions.append($0) }
      defer { subscription.cancel() }
      let first = makeContext(scope: .timelineFullLibrary)
      let firstRun = Task { await harness.manager.runExport(context: first) }
      let writing = await gate.waitForEnter(count: 1)
      try #require(writing)

      let second = makeContext(scope: .favoritesFull)
      let rejected = await harness.manager.runExport(context: second)

      #expect(rejected.context == second)
      #expect(rejected.result == .failed)
      #expect(harness.manager.activeRunContext == first)
      #expect(completions.isEmpty)
      await gate.releaseAll()
      let summary = await firstRun.value
      #expect(summary.context == first)
      #expect(summary.result == .completed)
      #expect(completions == [summary])
    } cleanup: {
      await harness.cleanup()
    }
  }

  /// Turning Auto Export off stops only AutoSync-sourced runs; a run with another source
  /// keeps its ownership and completes.
  @Test(.timeLimit(.minutes(1)))
  func cancelAutoSyncRunLeavesAManualSourcedRunRunning() async throws {
    let harness = makeHarness()
    try await withCleanup {
      let gate = AsyncCheckpoint()
      harness.writer.checkpoint = gate
      let asset = TestAssetFactory.makeAsset(id: "manual", creationDate: makeDate(2025, 1, 1))
      seedAssets([asset], for: .timeline, in: harness)
      let context = makeContext(scope: .timelineFullLibrary)
      let run = Task { await harness.manager.runExport(context: context) }
      let writing = await gate.waitForEnter(count: 1)
      try #require(writing)

      harness.manager.cancelAutoSyncRun()

      #expect(harness.manager.activeRunContext == context)
      await gate.releaseAll()
      let summary = await run.value
      #expect(summary.result == .completed)
      #expect(harness.writer.writeCalls.count == 1)
    } cleanup: {
      await harness.cleanup()
    }
  }

  /// A favorites run whose scan fails resolves `.failed` exactly once. The `.manual` case
  /// exercises the run-context branch (no UI path uses it) and keeps the scan message in its
  /// feedback; an AutoSync run has none. Awaits the preparation rather than the run, so a
  /// regression fails here instead of hanging.
  @Test(.timeLimit(.minutes(1)), arguments: [ExportRunSource.manual, .autoSync])
  func favoritesScanFailureResolvesTheRunAsFailed(source: ExportRunSource) async throws {
    let harness = makeHarness()
    try await withCleanup {
      harness.photoLib.fetchAssetsError = CocoaError(.fileReadUnknown)
      var completions: [ExportRunSummary] = []
      let subscription = harness.manager.completedRunsPublisher.sink { completions.append($0) }
      defer { subscription.cancel() }
      let context = ExportRunContext(
        source: source, visibility: source == .manual ? .userVisible : .background,
        scope: .favoritesFull, selection: .edited)

      _ = Task { await harness.manager.runExport(context: context) }
      // `runExport` sets the context and registers the preparation in one MainActor turn.
      let preparing = await eventually("favorites run started") {
        harness.manager.activeRunContext != nil || !completions.isEmpty
      }
      try #require(preparing)
      for task in harness.manager.currentPreparationTasks {
        let done = await finished(task)
        try #require(done)
      }

      #expect(completions.map(\.context) == [context])
      #expect(completions.map(\.result) == [.failed])
      #expect(harness.manager.activeRunContext == nil)
      #expect(
        harness.manager.progressState.manualSummary?.failureMessage
          == (source == .manual ? "Could not scan Favorites. Try exporting again." : nil))
    } cleanup: {
      await harness.cleanup()
    }
  }

  // MARK: - Full-scope run characterization (issue #153)

  /// Every supported full scope must resolve an empty scan once. This also pins
  /// the zero-count baseline captured after synchronous start* dispatch.
  @Test(.timeLimit(.minutes(1)), arguments: FullScope.allCases)
  func emptyFullScopeCompletesExactlyOnce(scope: FullScope) async {
    let harness = makeHarness()
    await withCleanup {
      let context = makeContext(scope: scope.runScope)
      var completions: [ExportRunSummary] = []
      let subscription = harness.manager.completedRunsPublisher.sink { completions.append($0) }
      defer { subscription.cancel() }

      let summary = await harness.manager.runExport(context: context)

      #expect(summary.context == context)
      #expect(summary.result == .completed)
      #expect(summary.cancelReason == nil)
      #expect(summary.enqueuedCount == 0)
      #expect(summary.completedCount == 0)
      #expect(summary.failedCount == 0)
      #expect(completions == [summary])
      #expect(harness.manager.activeRunContext == nil)
    } cleanup: {
      await harness.cleanup()
    }
  }

  /// The next run's summary must exclude the previous run's progress counters.
  /// A new asset on the same scope forces another real job after the reset.
  @Test(.timeLimit(.minutes(1)), arguments: FullScope.allCases)
  func fullScopeSummaryUsesFreshCounterBaseline(scope: FullScope) async {
    let harness = makeHarness()
    await withCleanup {
      let asset = TestAssetFactory.makeAsset(
        id: "baseline-\(scope)", creationDate: makeDate(2025, 1, 1))
      seedAssets([asset], for: scope, in: harness)
      let context = makeContext(scope: scope.runScope)
      var completions: [ExportRunSummary] = []
      let subscription = harness.manager.completedRunsPublisher.sink { completions.append($0) }
      defer { subscription.cancel() }

      let first = await harness.manager.runExport(context: context)
      let nextAsset = TestAssetFactory.makeAsset(
        id: "next-\(scope)", creationDate: makeDate(2025, 1, 2))
      seedAssets([nextAsset], for: scope, in: harness)
      let second = await harness.manager.runExport(context: context)

      #expect(first.result == .completed)
      #expect(first.enqueuedCount == 1)
      #expect(first.completedCount == 1)
      #expect(second.result == .completed)
      #expect(second.enqueuedCount == 1)
      #expect(second.completedCount == 1)
      #expect(completions == [first, second])
      #expect(harness.writer.writeCalls.count == 2)
    } cleanup: {
      await harness.cleanup()
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: FullScope.allCases)
  func importingRejectsEveryFullScopeWithoutStrandingAwaiter(scope: FullScope) async {
    let harness = makeHarness()
    await withCleanup {
      harness.manager.startImport()
      #expect(harness.manager.isImporting)
      let context = makeContext(scope: scope.runScope)
      var completions: [ExportRunSummary] = []
      let subscription = harness.manager.completedRunsPublisher.sink { completions.append($0) }
      defer { subscription.cancel() }

      let summary = await harness.manager.runExport(context: context)
      harness.manager.cancelImport()

      #expect(summary.context == context)
      #expect(summary.result == .failed)
      #expect(summary.enqueuedCount == 0)
      #expect(summary.completedCount == 0)
      #expect(completions == [summary])
      #expect(harness.manager.activeRunContext == nil)
    } cleanup: {
      await harness.cleanup()
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: FullScope.allCases)
  func unavailableRelevantStoreRejectsEveryFullScope(scope: FullScope) async {
    let harness = makeHarness()
    await withCleanup {
      if scope == .timeline {
        harness.store.configure(for: nil)
        #expect(harness.manager.canExportCollection)
      } else {
        harness.collectionStore.configure(for: nil)
        #expect(harness.manager.canExportTimeline)
      }
      let context = makeContext(scope: scope.runScope)
      var completions: [ExportRunSummary] = []
      let subscription = harness.manager.completedRunsPublisher.sink { completions.append($0) }
      defer { subscription.cancel() }

      let summary = await harness.manager.runExport(context: context)

      #expect(summary.context == context)
      #expect(summary.result == .failed)
      #expect(summary.enqueuedCount == 0)
      #expect(summary.completedCount == 0)
      #expect(completions == [summary])
      #expect(harness.manager.activeRunContext == nil)
    } cleanup: {
      await harness.cleanup()
    }
  }

  /// Without Photos access a full-scope run ends `.failed` and writes nothing, so AutoSync
  /// keeps the scope's pending work instead of acknowledging a scan that never happened.
  /// The listing calls throw `authorizationDenied` as production does, which already ends
  /// timeline and album runs `.failed`. Favorites lists nothing first, so its unauthorized
  /// scan is the case this pins. Missing access is a run-level condition, so no per-asset
  /// failure is recorded.
  @Test(
    .timeLimit(.minutes(1)),
    arguments: FullScope.allCases, [ExportRunSource.manual, .autoSync])
  func fullScopeWithoutPhotosAccessResolvesFailed(
    scope: FullScope, source: ExportRunSource
  ) async throws {
    let harness = makeHarness()
    try await withCleanup {
      let asset = TestAssetFactory.makeAsset(
        id: "no-access-\(scope)", creationDate: makeDate(2025, 1, 1))
      seedAssets([asset], for: scope, in: harness)
      harness.photoLib.isAuthorized = false
      let denied = PhotoLibraryManager.PhotoLibraryError.authorizationDenied
      harness.photoLib.availableYearsError = denied
      harness.photoLib.collectionTreeError = denied
      var completions: [ExportRunSummary] = []
      let subscription = harness.manager.completedRunsPublisher.sink { completions.append($0) }
      defer { subscription.cancel() }
      let context = ExportRunContext(
        source: source, visibility: source == .manual ? .userVisible : .background,
        scope: scope.runScope, selection: .edited)

      let summary = await harness.manager.runExport(context: context)
      for task in harness.manager.currentPreparationTasks {
        let done = await finished(task)
        try #require(done)
      }

      #expect(summary.context == context)
      #expect(summary.result == .failed)
      #expect(summary.enqueuedCount == 0)
      #expect(summary.completedCount == 0)
      #expect(summary.failedCount == 0)
      #expect(summary.failures.isEmpty)
      #expect(harness.writer.writeCalls.isEmpty)
      #expect(completions == [summary])
      #expect(harness.manager.activeRunContext == nil)
      // Favorites stops at the access guard. The other scopes stop earlier, when listing
      // their years or albums throws, and keep the bulk scan message.
      let manualMessage =
        scope == .favorites
        ? "Photos access is required to scan this selection."
        : "Some requested photos could not be scanned. Try exporting again."
      #expect(
        harness.manager.progressState.manualSummary?.failureMessage
          == (source == .manual ? manualMessage : nil))
    } cleanup: {
      await harness.cleanup()
    }
  }

  enum MidScanScope: CaseIterable, Sendable { case timeline, albums, sharedAlbums }

  /// Access lost between two items of a bulk scan ends the run `.failed`: a `.completed`
  /// summary would clear AutoSync's pending work for the item the scan never reached. The
  /// fake's writes don't check access, so this isolates the scan guard: only the missing
  /// second item can fail the run.
  @Test(.timeLimit(.minutes(1)), arguments: MidScanScope.allCases)
  func fullScopeLosingPhotosAccessMidScanResolvesFailed(scope: MidScanScope) async throws {
    let harness = makeHarness()
    let firstFetch = AsyncCheckpoint()
    try await withCleanup {
      let assets = (1...2).map {
        TestAssetFactory.makeAsset(
          id: "mid-scan-\(scope)-\($0)", creationDate: makeDate(2023 + $0, 1, 1))
      }
      let runScope: ExportRunScope
      switch scope {
      case .timeline:
        runScope = .timelineFullLibrary
        harness.photoLib.yearCounts = [(2024, 1), (2025, 1)]
        harness.photoLib.assetsByYearMonth["2024-1"] = [assets[0]]
        harness.photoLib.assetsByYearMonth["2025-1"] = [assets[1]]
        harness.photoLib.fetchAssetsCheckpointByYear[2024] = firstFetch
      case .albums, .sharedAlbums:
        let shared = scope == .sharedAlbums
        runScope = shared ? .allSharedAlbumsFull : .allAlbumsFull
        harness.photoLib.collectionTree = (1...2).map {
          PhotoCollectionDescriptor(
            id: "\(shared ? "shared-album" : "album"):album-\($0)",
            localIdentifier: "album-\($0)", title: "Album \($0)",
            kind: shared ? .sharedAlbum : .album, pathComponents: [], children: [])
        }
        for (index, asset) in assets.enumerated() {
          if shared {
            harness.photoLib.assetsBySharedAlbumLocalId["album-\(index + 1)"] = [asset]
          } else {
            harness.photoLib.assetsByAlbumLocalId["album-\(index + 1)"] = [asset]
          }
        }
        harness.photoLib.fetchAssetsCheckpointByAlbumId["album-1"] = firstFetch
      }
      for asset in assets {
        harness.photoLib.resourcesByAssetId[asset.id] = [
          TestAssetFactory.makeResource(originalFilename: "\(asset.id).JPG")
        ]
      }
      var completions: [ExportRunSummary] = []
      let subscription = harness.manager.completedRunsPublisher.sink { completions.append($0) }
      defer { subscription.cancel() }
      let context = makeContext(scope: runScope)

      let run = Task { await harness.manager.runExport(context: context) }
      let entered = await firstFetch.waitForEnter(count: 1)
      try #require(entered)
      harness.photoLib.isAuthorized = false
      await firstFetch.release()
      let summary = await run.value

      #expect(summary.context == context)
      #expect(summary.result == .failed)
      #expect(summary.enqueuedCount == 1)
      #expect(summary.completedCount == 1)
      #expect(summary.failedCount == 0)
      #expect(summary.failures.isEmpty)
      #expect(harness.writer.writeCalls.map(\.assetId) == [assets[0].id])
      #expect(completions == [summary])
      #expect(harness.manager.activeRunContext == nil)
    } cleanup: {
      await firstFetch.releaseAll()
      await harness.cleanup()
    }
  }

  /// A legacy fire-and-forget export has no `activeRunContext`, but it still
  /// occupies the queue and must cause `runExport` to fail fast.
  @Test(.timeLimit(.minutes(1)), arguments: FullScope.allCases)
  func busyLegacyQueueRejectsEveryFullScope(scope: FullScope) async {
    let harness = makeHarness()
    let gate = AsyncCheckpoint()
    harness.writer.checkpoint = gate
    await withCleanup {
      let asset = TestAssetFactory.makeAsset(
        id: "busy-\(scope)", creationDate: makeDate(2025, 1, 1))
      seedAssets([asset], for: scope, in: harness)
      startLegacyExport(for: scope, in: harness)
      await gate.waitForEnter(count: 1)
      let legacyTask = harness.manager.currentTask
      #expect(harness.manager.activeRunContext == nil)
      let context = makeContext(scope: scope.runScope)
      var completions: [ExportRunSummary] = []
      let subscription = harness.manager.completedRunsPublisher.sink { completions.append($0) }
      defer { subscription.cancel() }

      let summary = await harness.manager.runExport(context: context)

      #expect(summary.context == context)
      #expect(summary.result == .failed)
      #expect(summary.enqueuedCount == 0)
      #expect(summary.completedCount == 0)
      #expect(completions == [summary])
      #expect(harness.manager.activeRunContext == nil)
      await gate.releaseAll()
      await legacyTask?.value
      #expect(completions == [summary], "the legacy queue must not publish another summary")
    } cleanup: {
      await harness.cleanup()
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: FullScope.allCases)
  func cancellationCompletesEveryFullScopeExactlyOnce(scope: FullScope) async {
    let harness = makeHarness()
    let gate = AsyncCheckpoint()
    harness.writer.checkpoint = gate
    await withCleanup {
      let asset = TestAssetFactory.makeAsset(
        id: "cancel-\(scope)", creationDate: makeDate(2025, 1, 1))
      seedAssets([asset], for: scope, in: harness)
      let context = makeContext(scope: scope.runScope)
      var completions: [ExportRunSummary] = []
      let subscription = harness.manager.completedRunsPublisher.sink { completions.append($0) }
      defer { subscription.cancel() }
      let run = Task { await harness.manager.runExport(context: context) }
      await gate.waitForEnter(count: 1)
      let writerTask = harness.manager.currentTask

      harness.manager.cancelAndClear()
      let summary = await run.value
      await gate.releaseAll()
      await writerTask?.value

      #expect(summary.context == context)
      #expect(summary.result == .cancelled)
      #expect(summary.cancelReason == .userCancelled)
      #expect(summary.enqueuedCount == 0, "cancellation clears progress counters before finalizing")
      #expect(summary.completedCount == 0)
      #expect(completions == [summary])
      #expect(harness.manager.activeRunContext == nil)
    } cleanup: {
      await harness.cleanup()
    }
  }

  /// Pause with one job in the writer and one pending. The awaiter remains
  /// active until resume drains the second job, including across bulk scopes.
  @Test(.timeLimit(.minutes(1)), arguments: FullScope.allCases)
  func pauseAndResumeCompletesEveryFullScope(scope: FullScope) async {
    let harness = makeHarness()
    let gate = AsyncCheckpoint()
    harness.writer.checkpoint = gate
    await withCleanup {
      let assets = (1...2).map {
        TestAssetFactory.makeAsset(id: "paused-\(scope)-\($0)", creationDate: makeDate(2025, 1, $0))
      }
      seedAssets(assets, for: scope, in: harness)
      let context = makeContext(scope: scope.runScope)
      var completions: [ExportRunSummary] = []
      let subscription = harness.manager.completedRunsPublisher.sink { completions.append($0) }
      defer { subscription.cancel() }
      let run = Task { await harness.manager.runExport(context: context) }
      await gate.waitForEnter(count: 1)
      let firstWriterTask = harness.manager.currentTask

      harness.manager.pause()
      await gate.release()
      await firstWriterTask?.value
      #expect(harness.manager.isPaused)
      #expect(harness.manager.pendingJobs.count == 1)
      #expect(harness.manager.totalJobsCompleted == 1)
      #expect(completions.isEmpty)
      #expect(harness.manager.activeRunContext == context)

      await gate.releaseAll()
      harness.manager.resume()
      let summary = await run.value
      #expect(summary.result == .completed)
      #expect(summary.enqueuedCount == 2)
      #expect(summary.completedCount == 2)
      #expect(completions == [summary])
      #expect(harness.manager.activeRunContext == nil)
    } cleanup: {
      await harness.cleanup()
    }
  }

  /// Regression for the codex P2 finding: when a bulk-album run throws partway
  /// through and the partial-queue drain path runs, the summary must report
  /// `.failed`, not `.completed`. `AutoSyncReducer.coveredScopes` clears dirty
  /// state only on `.completed` summaries — a `.completed` here would hide the
  /// albums that the enqueue loop never reached from the next reconciliation.
  ///
  /// Reproduction: seed two albums; the second throws on `fetchAssets`. The
  /// first album's jobs queue, then the second throws, the catch block elects
  /// to drain the partial queue, and `incompleteScan` flips the natural
  /// `.completed` to `.failed` in `finalizeActiveRun`.
  @Test func allAlbumsFullPartialEnqueueResolvesFailed() async {
    let harness = makeHarness()
    await withCleanup {
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
    } cleanup: {
      await harness.cleanup()
    }
  }

  /// `startExportSharedAlbum` is the per-shared-album entry point — fire-and-
  /// forget, used by the per-pane Export Shared Album button and by the
  /// reduced-fidelity AutoSync path. It must route the asset through a
  /// `.sharedAlbum` placement (so the `Collections/Shared Albums/...` path
  /// is used and the `.singleResource` variant clamp kicks in), not a regular
  /// `.album` placement. Pin both: a placement of the right kind ends up in
  /// the collection store, and the on-disk relative path uses the Shared
  /// Albums root.
  @Test(.timeLimit(.minutes(2))) func startExportSharedAlbumWritesUnderSharedAlbumsRoot() async {
    let harness = makeHarness()
    await withCleanup {
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
      await harness.manager.waitForQueueDrained()
      #expect(harness.manager.totalJobsCompleted == 1)

      let placement = harness.collectionStore.placements(matching: .sharedAlbum)
        .first(where: { $0.collectionLocalIdentifier == "shared-1" })
      #expect(placement?.kind == .sharedAlbum)
      #expect(placement?.relativePath == "Collections/Shared Albums/Family stream/")
      // The user-album bucket must stay empty — a regression where the entry
      // point routed through `.album` would land the asset in
      // `Collections/Albums/...` and this assertion would fail.
      #expect(harness.collectionStore.placements(matching: .album).isEmpty)
    } cleanup: {
      await harness.cleanup()
    }
  }

  private func waitUntil(
    _ condition: @autoclosure () -> Bool, sourceLocation: SourceLocation = #_sourceLocation
  ) async {
    _ = await eventually("waitUntil condition", sourceLocation: sourceLocation) { condition() }
  }

  /// Same regression guard as the user-album test above, but exercising the
  /// `.allSharedAlbumsFull` code path. The two scopes share `enqueueBulkAlbumExport`
  /// and `finalizeActiveRun`'s `incompleteScan` check, so a single shared
  /// regression would affect both — but the AutoSync wiring (clearing
  /// `.sharedAlbums` dirty state on completed runs) lives on its own branch in
  /// `AutoSyncReducer.coveredScopes`, and pinning both gives the bug two red
  /// tests to walk through instead of one.
  @Test func allSharedAlbumsFullPartialEnqueueResolvesFailed() async {
    let harness = makeHarness()
    await withCleanup {
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
    } cleanup: {
      await harness.cleanup()
    }
  }

  // MARK: - AutoSync retry-eligibility skip (Phase 3 Slice C)

  /// AutoSync run on a destination where every asset's required variant is
  /// in retry backoff (eligibility closure returns false for all). Manager
  /// must skip enqueuing those assets and surface them as `skippedCount`
  /// rather than letting them churn the queue immediately after they fail.
  @Test func autoSyncRunSkipsAssetsWithAllVariantsInBackoff() async {
    let harness = makeHarness()
    await withCleanup {
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
    } cleanup: {
      await harness.cleanup()
    }
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
    await withCleanup {
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

      #expect(
        !eligibilityCalls.contains("already-done"),
        "skipForAutoSyncRetry must NOT be called for already-exported assets; got calls: \(eligibilityCalls)"
      )
      #expect(
        summary.skippedCount == 0,
        "already-exported asset must be filtered by isExported, not counted as a retry skip")
      #expect(summary.enqueuedCount == 0)
      #expect(summary.result == .completed)
    } cleanup: {
      await harness.cleanup()
    }
  }

  /// Manual runs (`source == .manual`) must never gate on AutoSync retry
  /// eligibility — that's plan §"Retry": only auto-sync runs honor the
  /// retry store; a manual export is the user's explicit override.
  @Test func manualRunIgnoresEligibilityCheck() async {
    let harness = makeHarness()
    await withCleanup {
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
    } cleanup: {
      await harness.cleanup()
    }
  }

  @Test(arguments: [false, true])
  func autoSyncOnlyAttemptsEligibleMissingVariants(originalAlreadyDone: Bool) async throws {
    let harness = makeHarness()
    try await withCleanup {
      let asset = TestAssetFactory.makeAsset(id: "mixed-retry", hasAdjustments: true)
      let placement = ExportPlacement.favorites()
      harness.photoLib.favoritesAssets = [asset]
      harness.photoLib.resourcesByAssetId[asset.id] = [
        TestAssetFactory.makeResource(type: .photo, originalFilename: "A.JPG"),
        TestAssetFactory.makeResource(type: .fullSizePhoto, originalFilename: "A-edit.JPG"),
      ]
      if originalAlreadyDone {
        harness.collectionStore.upsertPlacement(placement)
        harness.collectionStore.markVariantExported(
          assetId: asset.id, placement: placement, variant: .original,
          filename: "A_orig.JPG", exportedAt: Date())
        try await harness.collectionStore.flush()
      }
      var editedEligible = false
      harness.manager.autoSyncEligibilityCheck = { _, _, variant, _ in
        variant == .original || editedEligible
      }
      func context() -> ExportRunContext {
        ExportRunContext(
          source: .autoSync, visibility: .background, scope: .favoritesFull,
          selection: .editedWithOriginals)
      }
      let first = await harness.manager.runExport(context: context())
      #expect(first.skippedCount == (originalAlreadyDone ? 1 : 0))
      #expect(harness.writer.writeCalls.count == (originalAlreadyDone ? 0 : 1))
      #expect(harness.writer.writeCalls.allSatisfy { $0.resource.type == .photo })
      #expect(
        harness.collectionStore.exportInfo(assetId: asset.id, placement: placement)?
          .variants[.edited] == nil)

      editedEligible = true
      let retry = await harness.manager.runExport(context: context())
      #expect(retry.result == .completed)
      #expect(harness.writer.writeCalls.count == (originalAlreadyDone ? 1 : 2))
      #expect(harness.writer.writeCalls.last?.resource.type == .fullSizePhoto)
      #expect(
        harness.collectionStore.exportInfo(assetId: asset.id, placement: placement)?.variants[
          .edited]?.status == .done)
    } cleanup: {
      await harness.cleanup()
    }
  }

  @Test(arguments: [false, true])
  func mixedLivePhotoEligibilityPreservesPairingAndManualOverride(manual: Bool) async throws {
    let harness = makeHarness()
    try await withCleanup {
      let asset = TestAssetFactory.makeAsset(id: "live-retry", isLivePhoto: true)
      harness.photoLib.favoritesAssets = [asset]
      let resources = [
        TestAssetFactory.makeResource(type: .photo, originalFilename: "LIVE.HEIC"),
        TestAssetFactory.makeResource(type: .pairedVideo, originalFilename: "LIVE.MOV"),
      ]
      harness.photoLib.resourcesByAssetId[asset.id] = resources
      harness.manager.livePhotosPairedExport = true
      harness.manager.autoSyncEligibilityCheck = { _, _, variant, _ in variant == .original }
      let result = await harness.manager.runExport(
        context: ExportRunContext(
          source: manual ? .manual : .autoSync, visibility: .userVisible,
          scope: .favoritesFull, selection: .edited))
      #expect(result.result == .completed)
      #expect(harness.writer.writeCalls.count == (manual ? 2 : 1))
      #expect(harness.writer.writeCalls.first?.resource.type == .photo)
      let variants = try #require(
        harness.collectionStore.exportInfo(assetId: asset.id, placement: .favorites())?.variants)
      #expect(variants[.original]?.status == .done)
      #expect(variants[.original]?.filename == "LIVE.HEIC")
      let directory = try harness.dest.urlForRelativeDirectory(
        "Collections/Favorites/", createIfNeeded: false)
      #expect(
        (try? Data(contentsOf: directory.appendingPathComponent("LIVE.HEIC")))
          == FakeAssetResourceWriter.content(for: resources[0], assetId: asset.id))
      if manual {
        #expect(variants[.originalPairedVideo]?.status == .done)
        #expect(variants[.originalPairedVideo]?.filename == "LIVE.MOV")
        #expect(
          (try? Data(contentsOf: directory.appendingPathComponent("LIVE.MOV")))
            == FakeAssetResourceWriter.content(for: resources[1], assetId: asset.id))
      } else {
        #expect(variants[.originalPairedVideo] == nil)
      }
    } cleanup: {
      await harness.cleanup()
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func variantEligibilityIsRecheckedAfterEarlierVariantSuspends() async {
    let harness = makeHarness()
    let gate = AsyncCheckpoint()
    await withCleanup {
      let asset = TestAssetFactory.makeAsset(id: "queued-retry", hasAdjustments: true)
      harness.photoLib.favoritesAssets = [asset]
      harness.photoLib.resourcesByAssetId[asset.id] = [
        TestAssetFactory.makeResource(type: .photo, originalFilename: "A.JPG"),
        TestAssetFactory.makeResource(type: .fullSizePhoto, originalFilename: "A-edit.JPG"),
      ]
      var editedEligible = true
      harness.manager.autoSyncEligibilityCheck = { _, _, variant, _ in
        variant == .original || editedEligible
      }
      harness.writer.checkpoint = gate
      let run = Task {
        await harness.manager.runExport(
          context: ExportRunContext(
            source: .autoSync, visibility: .background, scope: .favoritesFull,
            selection: .editedWithOriginals))
      }
      await gate.waitForEnter(count: 1)
      editedEligible = false
      await gate.releaseAll()
      _ = await run.value
      #expect(harness.writer.writeCalls.count == 1)
      #expect(harness.writer.writeCalls.first?.resource.type == .photo)
    } cleanup: {
      await gate.releaseAll()
      await harness.cleanup()
    }
  }

  @Test func editedFallbackCannotBypassOriginalBackoff() async {
    let harness = makeHarness()
    await withCleanup {
      let asset = TestAssetFactory.makeAsset(id: "fallback-retry", hasAdjustments: true)
      harness.photoLib.favoritesAssets = [asset]
      harness.photoLib.resourcesByAssetId[asset.id] = [TestAssetFactory.makeResource()]
      harness.manager.autoSyncEligibilityCheck = { _, _, variant, _ in variant == .edited }
      let result = await harness.manager.runExport(
        context: ExportRunContext(
          source: .autoSync, visibility: .background, scope: .favoritesFull, selection: .edited))
      #expect(result.result == .failed)
      #expect(harness.writer.writeCalls.isEmpty)
      #expect(
        harness.collectionStore.exportInfo(assetId: asset.id, placement: .favorites())?.variants[
          .original] == nil)
    } cleanup: {
      await harness.cleanup()
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func legacyManualExportPrunesRetryAfterDurableCompletion() async throws {
    let harness = makeHarness()
    let builder = FakeAutoSyncEnvironmentBuilder()
    let autoSync = AutoSyncManager()
    let gate = AsyncCheckpoint()
    harness.writer.checkpoint = gate
    try await withCleanup {
      let asset = TestAssetFactory.makeAsset(id: "manual-retry", creationDate: makeDate(2025, 1, 1))
      harness.photoLib.favoritesAssets = [asset]
      harness.photoLib.resourcesByAssetId[asset.id] = [
        TestAssetFactory.makeResource(originalFilename: "manual-retry.JPG")
      ]
      var retry = AutoSyncRetryState.empty
      retry.recordFailure(
        scope: .favorites, assetId: asset.id, variant: .original,
        category: .destinationNoSpace, errorSignature: "full", at: builder.clock.now(),
        nextEligibleAt: nil)
      try builder.retryStore.save(retry, destinationId: "test")
      builder.destination.subject.send(
        DestinationSnapshot(stableId: "test", fingerprint: nil, isAvailable: true, safety: .safe))
      autoSync.attach(
        to: AutoSyncEnvironment(
          exportRunner: harness.manager, destination: builder.destination, scopes: builder.scopes,
          photos: builder.photos, importing: harness.manager, dirtyStateStore: builder.dirtyStore,
          retryStateStore: builder.retryStore, runSummaryStore: builder.runSummaryStore,
          perDestinationTokenStore: builder.perDestinationTokenStore,
          currentRunStore: builder.currentRunStore, clock: builder.clock,
          photosAuthorization: builder.photosAuthorization,
          userDefaults: builder.userDefaults))

      // Normal UI entry point has no awaitable run context or completion summary.
      harness.manager.startExportFavorites()
      await gate.waitForEnter(count: 1)
      let job = try #require(harness.manager.currentTask)
      #expect(harness.manager.activeRunContext == nil)
      #expect(!autoSync.currentRetryState.isEmpty)
      await gate.releaseAll()
      await job.value

      #expect(
        harness.collectionStore.exportInfo(assetId: asset.id, placement: .favorites())?
          .variants[.original]?.status == .done)
      #expect(autoSync.currentRetryState.isEmpty)
      #expect(builder.retryStore.load(destinationId: "test").isEmpty)
    } cleanup: {
      await harness.cleanup()
    }
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
    await withCleanup {
      let summary = await harness.manager.runExport(
        context: makeContext(scope: .timelineAssets(["asset-1"])))

      #expect(summary.result == .failed)
      #expect(harness.manager.activeRunContext == nil)
    } cleanup: {
      await harness.cleanup()
    }
  }

  @Test func autoExportScopeResolvesFailedForNow() async {
    let harness = makeHarness()
    await withCleanup {
      let summary = await harness.manager.runExport(
        context: makeContext(
          scope: .autoExport(
            AutoExportScopeSelection(timeline: true, favorites: true, albums: false))))

      #expect(summary.result == .failed)
      #expect(harness.manager.activeRunContext == nil)
    } cleanup: {
      await harness.cleanup()
    }
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
    await withCleanup {
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
      #expect(summary.stoppedBy == nil)
      #expect(harness.manager.activeRunContext == nil)
    } cleanup: {
      await harness.cleanup()
    }
  }

  // MARK: - Run context surfacing

  /// `activeRunContext` is set while a run is in flight and cleared once the awaitable
  /// resolves. The published value flips through nil → ctx → nil; future SwiftUI views
  /// can observe this directly.
  @Test func activeRunContextSurfacesAndClears() async {
    let harness = makeHarness()
    await withCleanup {
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
    } cleanup: {
      await harness.cleanup()
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
  @Test(.timeLimit(.minutes(2))) func videoLayoutSubfolderRoutesStandaloneVideosOnlyLivePhotosStayPaired() async {
    let harness = makeHarness()
    await withCleanup {
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
      await harness.manager.waitForQueueDrained()

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
    } cleanup: {
      await harness.cleanup()
    }
  }

  /// Mid-life same-placement re-run for a standalone video: export under `.flat`,
  /// flip to `.subfolder`, re-export the same month. The asset is already `.done`
  /// (the `videoLayout` toggle does not widen `requiredVariants`), so the second
  /// run skips it — no relocation, no second file in `videos/`, the record's
  /// `subfolder == nil` from the first write is left intact.
  @Test(.timeLimit(.minutes(2))) func videoLayoutFlipAfterFlatExportDoesNotRelocateOrDoubleWrite() async {
    let harness = makeHarness()
    await withCleanup {
      let asset = TestAssetFactory.makeAsset(
        id: "vid-flip", mediaType: .video, isLivePhoto: false)
      harness.photoLib.assetsByYearMonth["2026-3"] = [asset]
      harness.photoLib.resourcesByAssetId["vid-flip"] = [
        TestAssetFactory.makeResource(type: .video, originalFilename: "IMG_FLIP.MOV")
      ]

      // First export under .flat — lands at bare month path.
      harness.manager.videoLayout = .flat
      harness.manager.startExportMonth(year: 2026, month: 3)
      await harness.manager.waitForQueueDrained()
      #expect(harness.manager.totalJobsCompleted == 1)

      let root = harness.dest.rootURL
      let flatPath = root.appendingPathComponent("2026/03/IMG_FLIP.MOV").path
      let subfolderPath = root.appendingPathComponent("2026/03/videos/IMG_FLIP.MOV").path
      let fm = FileManager.default
      #expect(fm.fileExists(atPath: flatPath))
      #expect(!fm.fileExists(atPath: subfolderPath))

      let firstWriteCount = harness.writer.writeCalls.count

      // Capture the real message publication so its normal expiry cannot race the assertion.
      harness.manager.videoLayout = .subfolder
      var messages: [String] = []
      let observation = harness.manager.progressState.$emptyRunMessage.compactMap { $0 }.sink {
        messages.append($0)
      }
      harness.manager.startExportMonth(year: 2026, month: 3)
      await harness.manager.waitForQueueDrained()
      withExtendedLifetime(observation) {
        #expect(messages == ["This month is already exported."])
      }

      // No second file, no second write call, no record mutation.
      #expect(fm.fileExists(atPath: flatPath))
      #expect(!fm.fileExists(atPath: subfolderPath))
      #expect(harness.writer.writeCalls.count == firstWriteCount)
      let record = harness.store.exportInfo(assetId: "vid-flip")
      #expect(record?.variants[.original]?.subfolder == nil)
    } cleanup: {
      await harness.cleanup()
    }
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
  @Test(.timeLimit(.minutes(2))) func videoLayoutMidLifeSynthesizerWritesEditedToSubfolderKeepsOriginalAtBase() async {
    let harness = makeHarness()
    await withCleanup {
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
      await harness.manager.waitForQueueDrained()
      #expect(harness.manager.totalJobsCompleted == 1)

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
    } cleanup: {
      await harness.cleanup()
    }
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
  @Test(.timeLimit(.minutes(2))) func startExportYearWritesEachMonthInYYYYMMStructure() async {
    let harness = makeHarness()
    await withCleanup {
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
      await harness.manager.waitForQueueDrained()

      let root = harness.dest.rootURL
      let fm = FileManager.default
      #expect(
        fm.fileExists(
          atPath: root.appendingPathComponent("2025/03/MARCH.HEIC").path))
      #expect(
        fm.fileExists(
          atPath: root.appendingPathComponent("2025/06/JUNE.HEIC").path))
      #expect(
        fm.fileExists(
          atPath: root.appendingPathComponent("2025/09/SEPT.HEIC").path))

      // Per-record year/month must match the asset's creationDate, not the year arg —
      // a planner bug that planted every job under `2025/01/` would still satisfy the
      // queue drain barrier above but would fail these.
      #expect(harness.store.exportInfo(assetId: "asset-march")?.month == 3)
      #expect(harness.store.exportInfo(assetId: "asset-june")?.month == 6)
      #expect(harness.store.exportInfo(assetId: "asset-sept")?.month == 9)
    } cleanup: {
      await harness.cleanup()
    }
  }
}
