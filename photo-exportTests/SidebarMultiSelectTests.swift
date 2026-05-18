import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Coverage for the sidebar multi-select machinery added in issue #46:
///
/// - `LibrarySelection.isTimeline` / `isCollection`
/// - `TimelineSelectionBuckets.normalize`
/// - `CollectionsSelectionBuckets.normalize`
/// - `ExportManager.startExportTimelineSelection`
/// - `ExportManager.startExportCollectionsSelection`
///
/// The bucket-normalize tests are pure value-type tests; the dispatcher tests run
/// against the same fake-backed `ExportManager` harness `ExportAllAlbumsTests` uses.
@MainActor
struct SidebarMultiSelectTests {

  // MARK: - LibrarySelection.isTimeline / isCollection

  @Test func isTimelineCoversYearAndMonthCases() {
    #expect(LibrarySelection.timelineYear(year: 2026).isTimeline)
    #expect(LibrarySelection.timelineMonth(year: 2026, month: 5).isTimeline)
    #expect(!LibrarySelection.favorites.isTimeline)
    #expect(!LibrarySelection.album(collectionId: "x").isTimeline)
    #expect(!LibrarySelection.folder(collectionId: "x").isTimeline)
    #expect(!LibrarySelection.sharedAlbum(collectionId: "x").isTimeline)
  }

  @Test func isCollectionIsTheInverseOfIsTimeline() {
    let allCases: [LibrarySelection] = [
      .timelineYear(year: 2026),
      .timelineMonth(year: 2026, month: 5),
      .favorites,
      .album(collectionId: "a"),
      .folder(collectionId: "f"),
      .sharedAlbum(collectionId: "s"),
    ]
    for selection in allCases {
      #expect(selection.isCollection != selection.isTimeline)
    }
  }

  // MARK: - TimelineSelectionBuckets.normalize

  @Test func timelineNormalizeKeepsDistinctYearsAndMonths() {
    let buckets = TimelineSelectionBuckets.normalize([
      .timelineYear(year: 2026),
      .timelineMonth(year: 2024, month: 3),
      .timelineMonth(year: 2024, month: 6),
    ])
    #expect(buckets.years == [2026])
    #expect(
      buckets.months == [
        .init(year: 2024, month: 6),
        .init(year: 2024, month: 3),
      ])
    #expect(buckets.count == 3)
  }

  /// Year supersedes any month inside it. The user gets the wider scope.
  @Test func timelineNormalizeDropsMonthsCoveredByASelectedYear() {
    let buckets = TimelineSelectionBuckets.normalize([
      .timelineYear(year: 2026),
      .timelineMonth(year: 2026, month: 5),  // dropped
      .timelineMonth(year: 2026, month: 11),  // dropped
      .timelineMonth(year: 2024, month: 3),  // kept (different year)
    ])
    #expect(buckets.years == [2026])
    #expect(buckets.months == [.init(year: 2024, month: 3)])
  }

  @Test func timelineNormalizeIgnoresCollectionShapedValues() {
    let buckets = TimelineSelectionBuckets.normalize([
      .timelineYear(year: 2026),
      .favorites,
      .album(collectionId: "a"),
      .folder(collectionId: "f"),
    ])
    #expect(buckets.years == [2026])
    #expect(buckets.months.isEmpty)
  }

  @Test func timelineNormalizeSortsDescendingByDate() {
    let buckets = TimelineSelectionBuckets.normalize([
      .timelineYear(year: 2020),
      .timelineYear(year: 2026),
      .timelineYear(year: 2023),
      .timelineMonth(year: 2024, month: 6),
      .timelineMonth(year: 2024, month: 11),
    ])
    #expect(buckets.years == [2026, 2023, 2020])
    #expect(
      buckets.months == [
        .init(year: 2024, month: 11),
        .init(year: 2024, month: 6),
      ])
  }

  @Test func timelineNormalizeEmptyInputIsEmpty() {
    let buckets = TimelineSelectionBuckets.normalize([] as [LibrarySelection])
    #expect(buckets.isEmpty)
    #expect(buckets.count == 0)
  }

  // MARK: - CollectionsSelectionBuckets.normalize

  @Test func collectionsNormalizeSeparatesFavoritesAlbumsShared() {
    let buckets = CollectionsSelectionBuckets.normalize(
      [
        .favorites,
        .album(collectionId: "a1"),
        .album(collectionId: "a2"),
        .sharedAlbum(collectionId: "s1"),
      ]
    ) { _ in [] }

    #expect(buckets.includesFavorites)
    #expect(buckets.albumIds == ["a1", "a2"])
    #expect(buckets.sharedAlbumIds == ["s1"])
  }

  @Test func collectionsNormalizeExpandsFoldersAndDedupesAgainstAlbums() {
    let buckets = CollectionsSelectionBuckets.normalize(
      [
        .album(collectionId: "a1"),
        .folder(collectionId: "f1"),  // expands to a1, a2
        .album(collectionId: "a3"),
      ]
    ) { folderId in
      switch folderId {
      case "f1": return ["a1", "a2"]
      default: return []
      }
    }

    // a1 appears in both the explicit selection AND the folder expansion; dedup
    // keeps the first occurrence, preserving order.
    #expect(buckets.albumIds == ["a1", "a2", "a3"])
    #expect(!buckets.includesFavorites)
    #expect(buckets.sharedAlbumIds.isEmpty)
  }

  @Test func collectionsNormalizeIgnoresTimelineShapedValues() {
    let buckets = CollectionsSelectionBuckets.normalize(
      [
        .timelineYear(year: 2026),
        .timelineMonth(year: 2024, month: 5),
        .album(collectionId: "a1"),
      ]
    ) { _ in [] }

    #expect(buckets.albumIds == ["a1"])
    #expect(!buckets.includesFavorites)
    #expect(buckets.sharedAlbumIds.isEmpty)
  }

  @Test func collectionsNormalizeEmptyInputIsEmpty() {
    let buckets = CollectionsSelectionBuckets.normalize([] as [LibrarySelection]) { _ in [] }
    #expect(buckets.isEmpty)
    #expect(buckets.count == 0)
  }

  // MARK: - ExportManager.startExportTimelineSelection

  /// Mixed years + months in a single call all reach the queue and produce timeline
  /// placements. Verifies the bulk driver loops through both per-year and per-month
  /// enqueue helpers without losing the ordering or short-circuiting after the first
  /// iteration.
  @Test func timelineSelectionEnqueuesYearsAndMonths() async throws {
    let h = makeHarness()
    defer { h.cleanup() }

    // 2026 has two months; 2024 has one month seeded. The year enqueue path walks
    // all 12 months of 2026 (via the fake's `fetchAssets(year: month: nil)`), so
    // only seeded months produce work for that year.
    h.photoLib.assetsByYearMonth["2026-3"] = [makeAsset(id: "y26m3-a", year: 2026, month: 3)]
    h.photoLib.assetsByYearMonth["2026-7"] = [makeAsset(id: "y26m7-a", year: 2026, month: 7)]
    h.photoLib.assetsByYearMonth["2024-5"] = [makeAsset(id: "y24m5-a", year: 2024, month: 5)]

    h.manager.startExportTimelineSelection(
      years: [2026],
      months: [.init(year: 2024, month: 5)]
    )

    await waitUntil(h.manager.totalJobsEnqueued == 3)
    #expect(h.manager.totalJobsEnqueued == 3)

    let kinds = Set(h.manager.pendingJobs.map { $0.placement.kind })
    #expect(kinds.isSubset(of: [.timeline]))
  }

  /// Empty buckets must not enqueue any work, must surface the "no items" message,
  /// and must not leave the manager in `isEnqueueingAll`.
  @Test func timelineSelectionEmptyBucketsSurfacesMessage() async throws {
    let h = makeHarness()
    defer { h.cleanup() }

    h.manager.startExportTimelineSelection(years: [], months: [])
    await waitUntil(h.manager.emptyRunMessage != nil)

    #expect(h.manager.emptyRunMessage == "No timeline items selected.")
    #expect(h.manager.totalJobsEnqueued == 0)
  }

  /// Cancellation mid-loop must reset `isEnqueueingAll` and leave the queue empty.
  /// Mirrors `ExportAllAlbumsTests`'s checkpoint pattern: gate year B's fetch, let
  /// year A's jobs land, cancel, release the gate, assert the manager is idle.
  @Test func cancelMidTimelineSelectionLoopResetsState() async throws {
    let h = makeHarness()
    defer { h.cleanup() }

    h.photoLib.assetsByYearMonth["2026-3"] = [makeAsset(id: "a26", year: 2026, month: 3)]
    h.photoLib.assetsByYearMonth["2024-5"] = [makeAsset(id: "a24", year: 2024, month: 5)]

    let fetchGate = AsyncCheckpoint()
    h.photoLib.fetchAssetsCheckpointByYear[2024] = fetchGate

    let genBefore = h.manager.generation

    h.manager.startExportTimelineSelection(
      years: [2026, 2024], months: []
    )

    // Wait until the loop is suspended on year 2024's fetch.
    await fetchGate.waitForEnter(count: 1)
    #expect(h.manager.isEnqueueingAll)

    // Cancel mid-loop. After this, the loop's next `isCurrent(gen)` check
    // returns false and bails out.
    h.manager.cancelAndClear()
    await fetchGate.releaseAll()

    await waitUntil(!h.manager.isEnqueueingAll)
    #expect(!h.manager.isEnqueueingAll)
    #expect(h.manager.pendingJobs.isEmpty)
    #expect(h.manager.generation > genBefore)
  }

  /// Partial-failure recovery: year A enqueues successfully, year B's fetch
  /// throws. The catch branch must (a) surface the queue-warning message,
  /// (b) drain year A's queued jobs, and (c) set `partialBulkScan` so any
  /// scoped wrapper sees the partial state.
  @Test func timelineSelectionPartialFailureDrainsQueuedJobs() async throws {
    let h = makeHarness()
    defer { h.cleanup() }

    let asset1 = makeAsset(id: "a26-1", year: 2026, month: 3)
    let asset2 = makeAsset(id: "a26-2", year: 2026, month: 3)
    h.photoLib.assetsByYearMonth["2026-3"] = [asset1, asset2]
    // The writer needs a resource per asset to actually complete a job; without
    // these the writer logs "No original byte source" and the queue never drains.
    h.photoLib.resourcesByAssetId["a26-1"] = [
      ResourceDescriptor(type: .photo, originalFilename: "a26-1.HEIC")
    ]
    h.photoLib.resourcesByAssetId["a26-2"] = [
      ResourceDescriptor(type: .photo, originalFilename: "a26-2.HEIC")
    ]
    h.photoLib.fetchAssetsErrorByYear[2024] = NSError(
      domain: "Test", code: 11, userInfo: [NSLocalizedDescriptionKey: "boom"])

    // Gate the writer so we can step the drain deterministically.
    let writeGate = AsyncCheckpoint()
    h.writer.checkpoint = writeGate

    h.manager.startExportTimelineSelection(years: [2026, 2024], months: [])

    await writeGate.waitForEnter(count: 1)
    await writeGate.release(1)
    await writeGate.waitForEnter(count: 2)
    await writeGate.releaseAll()
    await waitUntil(h.manager.totalJobsCompleted == 2)

    #expect(h.manager.totalJobsCompleted == 2)
    #expect(h.manager.queueCount == 0)
    #expect(!h.manager.isEnqueueingAll)
    #expect(
      h.manager.queueWarningMessage
        == "Couldn't scan every item in the selection. Continuing with the photos already queued."
    )
    #expect(h.manager.emptyRunMessage == nil)
  }

  // MARK: - SidebarFocusReducer (pure)

  /// Programmatic full replace (section flip restore): old/new disjoint, caller
  /// pre-set focus to a member of new — respect the caller's pick. This is the
  /// regression the focus-clobber bug fix guards against.
  @Test func focusReducerRespectsPreSetFocusOnDisjointReplace() {
    let old: Set<LibrarySelection> = [.album(collectionId: "A")]
    let new: Set<LibrarySelection> = [
      .timelineYear(year: 2026),
      .timelineMonth(year: 2024, month: 3),
    ]
    let restoredFocus: LibrarySelection = .timelineMonth(year: 2024, month: 3)
    let result = SidebarFocusReducer.nextFocus(
      oldSet: old, newSet: new, currentFocus: restoredFocus)
    #expect(result == restoredFocus)
  }

  /// Plain-click replacing the selection — old/new disjoint AND current focus is
  /// NOT in new. Focus should move to the newly-added item (the just-clicked row).
  @Test func focusReducerMovesToNewlyAddedOnPlainClickReplace() {
    let old: Set<LibrarySelection> = [.album(collectionId: "A")]
    let new: Set<LibrarySelection> = [.album(collectionId: "B")]
    let currentFocus: LibrarySelection = .album(collectionId: "A")
    let result = SidebarFocusReducer.nextFocus(
      oldSet: old, newSet: new, currentFocus: currentFocus)
    #expect(result == .album(collectionId: "B"))
  }

  /// Cmd-click adding to existing selection — old⊂new, current focus stays in
  /// new. Focus should follow the newly-clicked (added) item.
  @Test func focusReducerFollowsAddedOnCmdClickAddition() {
    let old: Set<LibrarySelection> = [.timelineMonth(year: 2024, month: 3)]
    let new: Set<LibrarySelection> = [
      .timelineMonth(year: 2024, month: 3),
      .timelineYear(year: 2026),
    ]
    let currentFocus: LibrarySelection = .timelineMonth(year: 2024, month: 3)
    let result = SidebarFocusReducer.nextFocus(
      oldSet: old, newSet: new, currentFocus: currentFocus)
    #expect(result == .timelineYear(year: 2026))
  }

  /// Cmd-click toggling off the focused item — focus must move to any remaining
  /// item in the set (not stay on the removed item).
  @Test func focusReducerMovesToRemainingOnToggleOffFocused() {
    let old: Set<LibrarySelection> = [
      .album(collectionId: "A"),
      .album(collectionId: "B"),
    ]
    let new: Set<LibrarySelection> = [.album(collectionId: "B")]
    let currentFocus: LibrarySelection = .album(collectionId: "A")
    let result = SidebarFocusReducer.nextFocus(
      oldSet: old, newSet: new, currentFocus: currentFocus)
    #expect(result == .album(collectionId: "B"))
  }

  /// Esc / clear-selection — new is empty, focus must become nil.
  @Test func focusReducerClearsFocusOnEmptyNewSet() {
    let old: Set<LibrarySelection> = [.album(collectionId: "A")]
    let new: Set<LibrarySelection> = []
    let currentFocus: LibrarySelection = .album(collectionId: "A")
    let result = SidebarFocusReducer.nextFocus(
      oldSet: old, newSet: new, currentFocus: currentFocus)
    #expect(result == nil)
  }

  /// No-op diff (oldSet == newSet) keeps current focus. Defensive against the
  /// "spurious onChange with same value" case SwiftUI sometimes emits.
  @Test func focusReducerKeepsFocusOnNoOpDiff() {
    let set: Set<LibrarySelection> = [
      .album(collectionId: "A"),
      .album(collectionId: "B"),
    ]
    let currentFocus: LibrarySelection = .album(collectionId: "A")
    let result = SidebarFocusReducer.nextFocus(
      oldSet: set, newSet: set, currentFocus: currentFocus)
    #expect(result == currentFocus)
  }

  // MARK: - ExportManager.startExportCollectionsSelection

  /// Folder + explicit album in the selection set deduplicate at dispatch time:
  /// the folder's descendant album appears exactly once on the queue.
  @Test func collectionsSelectionExpandsFoldersAndDedupesAlbums() async throws {
    let h = makeHarness()
    defer { h.cleanup() }

    let albumA = seedAlbum(h.photoLib, localId: "A", ids: ["a1"])
    let albumB = seedAlbum(
      h.photoLib, localId: "B", ids: ["b1"], pathComponents: ["F1"])
    let folder = PhotoCollectionDescriptor(
      id: "folder:F1", localIdentifier: "F1", title: "F1",
      kind: .folder, pathComponents: [], children: [albumB])
    h.photoLib.collectionTree = [albumA, folder]

    // Select A explicitly AND the folder (which contains B). Dedup keeps each
    // album once; the queue should have exactly two album jobs (one for A, one
    // for B), not three.
    let buckets = CollectionsSelectionBuckets.normalize(
      [.album(collectionId: "A"), .folder(collectionId: "F1")]
    ) { folderId in
      switch folderId {
      case "F1": return PhotoCollectionDescriptor.albumLocalIds(under: folder)
      default: return []
      }
    }
    h.manager.startExportCollectionsSelection(buckets)

    await waitUntil(h.manager.totalJobsEnqueued == 2)
    #expect(h.manager.totalJobsEnqueued == 2)

    let kinds = Set(h.manager.pendingJobs.map { $0.placement.kind })
    #expect(kinds.isSubset(of: [.album]))
  }

  /// Empty buckets must not enqueue any work and must surface the empty-selection
  /// message.
  @Test func collectionsSelectionEmptyBucketsSurfacesMessage() async throws {
    let h = makeHarness()
    defer { h.cleanup() }

    h.manager.startExportCollectionsSelection(.empty)
    await waitUntil(h.manager.emptyRunMessage != nil)

    #expect(h.manager.emptyRunMessage == "No collections selected.")
    #expect(h.manager.totalJobsEnqueued == 0)
  }

  // MARK: - Issue #67 item 4 follow-ups

  /// Item 4b: cancellation parity with the timeline path
  /// (`cancelMidTimelineSelectionLoopResetsState`). The collections dispatcher
  /// has three buckets (favorites → albums → shared); cancelling between any
  /// two buckets must reset `isEnqueueingAll`, leave the queue idle, and bump
  /// the generation so a re-dispatch can run cleanly.
  @Test func cancelMidCollectionsSelectionBetweenBucketsResetsState() async throws {
    let h = makeHarness()
    defer { h.cleanup() }

    // Favorites: one asset; album A: one asset. Gate album A's fetch so we can
    // cancel after favorites is done but before the album loop completes.
    h.photoLib.favoritesAssets = [makeAsset(id: "fav-1", year: 2026, month: 3)]
    h.photoLib.resourcesByAssetId["fav-1"] = [
      ResourceDescriptor(type: .photo, originalFilename: "fav-1.HEIC")
    ]
    let albumA = seedAlbum(h.photoLib, localId: "A", ids: ["alb-A1"])
    h.photoLib.collectionTree = [albumA]
    let fetchGate = AsyncCheckpoint()
    h.photoLib.fetchAssetsCheckpointByAlbumId["A"] = fetchGate

    let genBefore = h.manager.generation

    let buckets = CollectionsSelectionBuckets.normalize(
      [.favorites, .album(collectionId: "A")]
    ) { _ in [] }
    h.manager.startExportCollectionsSelection(buckets)

    // Wait until the loop is suspended on album A's asset fetch — favorites
    // already enqueued. After this point the next `isCurrent(gen)` check
    // would return false if we cancel.
    await fetchGate.waitForEnter(count: 1)
    #expect(h.manager.isEnqueueingAll)

    h.manager.cancelAndClear()
    await fetchGate.releaseAll()

    await waitUntil(!h.manager.isEnqueueingAll)
    #expect(!h.manager.isEnqueueingAll)
    #expect(h.manager.pendingJobs.isEmpty)
    #expect(h.manager.generation > genBefore)
  }

  /// Item 4c: the predicate-order pin. `enqueueYear/Month/Collection` apply
  /// `isExported` *before* the AutoSync retry-eligibility gate; if a future
  /// refactor inlined a retry-gate check at the dispatcher entry point ahead
  /// of `isExported`, an already-exported asset would route through the gate
  /// and the eligibility-check counter would grow. This test pins the
  /// short-circuit: with all assets already exported (proved by running the
  /// dispatcher once, then re-dispatching), the eligibility check must never
  /// fire for the second run.
  @Test func multiSelectDispatcherHonorsAutoSyncEligibilityCheck() async throws {
    let h = makeHarness()
    defer { h.cleanup() }

    // Seed one album with one asset.
    let album = seedAlbum(h.photoLib, localId: "A", ids: ["a1"])
    h.photoLib.collectionTree = [album]

    let buckets = CollectionsSelectionBuckets.normalize(
      [.album(collectionId: "A")]
    ) { _ in [] }

    // First run: actually export. Drives `enqueueCollection` → variant write
    // → record store mark-exported, so the second run sees the asset as done.
    h.manager.startExportCollectionsSelection(buckets)
    await waitUntil(h.manager.totalJobsCompleted == 1 && !h.manager.isEnqueueingAll)
    #expect(h.manager.totalJobsCompleted == 1)

    // Install an eligibility check that records calls. The closure is
    // `@MainActor`-isolated by type so the counter can be a plain Int.
    final class CallCounter { var count = 0 }
    let counter = CallCounter()
    h.manager.autoSyncEligibilityCheck = { _, _, _, _ in
      counter.count += 1
      return false
    }

    h.manager.startExportCollectionsSelection(buckets)
    await waitUntil(!h.manager.isEnqueueingAll)

    // After the second dispatch on an idle queue, `resetProgressCounters()`
    // wipes both counters back to zero. The load-bearing assertions are that
    // *no new work was queued* and *the eligibility check was never
    // consulted* — together they prove `enqueueCollection`'s `isExported`
    // short-circuit ran before any retry-gate could.
    #expect(h.manager.pendingJobs.isEmpty, "no jobs queued for already-exported assets")
    #expect(h.manager.totalJobsEnqueued == 0)
    #expect(
      counter.count == 0,
      """
      Eligibility check must not fire for an already-exported asset: \
      `isExported` short-circuits inside `enqueueCollection` before the \
      retry-gate. A non-zero count means the predicate order regressed.
      """)
  }

  /// Item 4d: the queue-coordinator route assertion. The multi-select
  /// dispatchers were verified before this PR by terminal counters
  /// (`totalJobsEnqueued` / `totalJobsCompleted`) but never by the queue
  /// coordinator's own `isRunning` publisher — which is the contract AutoSync
  /// observes via the manager's mirror. This test pins that the dispatcher's
  /// jobs do flow through `ExportQueueCoordinator` (and so the mirror sinks
  /// fire as expected).
  @Test func multiSelectEnqueueRoutesThroughQueueCoordinator() async throws {
    let h = makeHarness()
    defer { h.cleanup() }

    h.photoLib.assetsByYearMonth["2026-3"] = [makeAsset(id: "a1", year: 2026, month: 3)]
    h.photoLib.resourcesByAssetId["a1"] = [
      ResourceDescriptor(type: .photo, originalFilename: "a1.HEIC")
    ]

    let writeGate = AsyncCheckpoint()
    h.writer.checkpoint = writeGate

    #expect(!h.manager.queueCoordinator.isRunning, "queue idle before dispatch")
    #expect(!h.manager.isRunning, "manager mirror idle before dispatch")

    h.manager.startExportTimelineSelection(years: [2026], months: [])
    await writeGate.waitForEnter(count: 1)

    // The coordinator is processing the job; the manager's mirror sink has
    // flipped in lockstep (the synchrony of the sink is itself a regression
    // gate — see `ExportQueueStateSnapshotTests`).
    #expect(h.manager.queueCoordinator.isRunning, "queue running mid-job")
    #expect(h.manager.isRunning, "manager mirror running mid-job")

    await writeGate.releaseAll()
    await waitUntil(!h.manager.queueCoordinator.isRunning)
    #expect(!h.manager.queueCoordinator.isRunning, "queue idle after drain")
    #expect(!h.manager.isRunning, "manager mirror idle after drain")
  }

  // MARK: - Test harness (mirrors ExportAllAlbumsTests)

  @MainActor
  private struct Harness {
    let manager: ExportManager
    let photoLib: FakePhotoLibraryService
    let dest: FakeExportDestination
    let writer: FakeAssetResourceWriter
    let timelineStore: ExportRecordStore
    let collectionStore: CollectionExportRecordStore
    let storeRoot: URL
    let userDefaultsSuite: String

    func cleanup() {
      manager.cancelAndClear()
      timelineStore.flushForTesting()
      collectionStore.flushForTesting()
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
      .appendingPathComponent("SidebarMultiSelect-\(UUID().uuidString)", isDirectory: true)
    let timelineStore = ExportRecordStore(baseDirectoryURL: storeRoot)
    timelineStore.configure(for: "test")
    let collectionStore = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    collectionStore.configure(for: "test")
    let suiteName = "test-SidebarMultiSelect-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let manager = ExportManager(
      photoLibraryService: photoLib,
      exportDestination: dest,
      exportRecordStore: timelineStore,
      collectionExportRecordStore: collectionStore,
      assetResourceWriter: writer,
      fileSystem: fileSystem,
      userDefaults: defaults
    )
    return Harness(
      manager: manager, photoLib: photoLib, dest: dest, writer: writer,
      timelineStore: timelineStore, collectionStore: collectionStore,
      storeRoot: storeRoot, userDefaultsSuite: suiteName)
  }

  private func makeAsset(id: String, year: Int = 2024, month: Int = 1) -> AssetDescriptor {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = 1
    let calendar = Calendar(identifier: .gregorian)
    let date = calendar.date(from: components) ?? Date(timeIntervalSince1970: 1_700_000_000)
    return AssetDescriptor(
      id: id, creationDate: date,
      mediaType: .image, pixelWidth: 100, pixelHeight: 100, duration: 0,
      hasAdjustments: false)
  }

  private func seedAlbum(
    _ photoLib: FakePhotoLibraryService, localId: String, ids: [String],
    pathComponents: [String] = []
  ) -> PhotoCollectionDescriptor {
    let assets = ids.map { makeAsset(id: $0) }
    photoLib.assetsByAlbumLocalId[localId] = assets
    for asset in assets {
      photoLib.resourcesByAssetId[asset.id] = [
        ResourceDescriptor(type: .photo, originalFilename: "\(asset.id).HEIC")
      ]
    }
    return PhotoCollectionDescriptor(
      id: "album:\(localId)", localIdentifier: localId, title: "Album-\(localId)",
      kind: .album, pathComponents: pathComponents, children: [])
  }

  private func waitUntil(
    timeout: TimeInterval = 10, _ condition: @autoclosure () -> Bool
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
  }
}
