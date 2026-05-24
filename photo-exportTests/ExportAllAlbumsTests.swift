import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Coverage for `ExportManager.startExportAllAlbums()` and the supporting
/// `PhotoCollectionDescriptor.albumLocalIds(in:)` tree-walk helper.
///
@MainActor
struct ExportAllAlbumsTests {

  // MARK: - Tree walk

  @Test func albumLocalIdsCollectsTopLevelAndNestedAlbumsExcludingFavorites() {
    let tree: [PhotoCollectionDescriptor] = [
      PhotoCollectionDescriptor(
        id: "favorites", localIdentifier: nil, title: "Favorites",
        kind: .favorites, pathComponents: [], children: []),
      PhotoCollectionDescriptor(
        id: "album:top-A", localIdentifier: "top-A", title: "Top A",
        kind: .album, pathComponents: [], children: []),
      PhotoCollectionDescriptor(
        id: "folder:F1", localIdentifier: "F1", title: "Folder 1",
        kind: .folder, pathComponents: [],
        children: [
          PhotoCollectionDescriptor(
            id: "album:nested-B", localIdentifier: "nested-B", title: "Nested B",
            kind: .album, pathComponents: ["Folder 1"], children: []),
          PhotoCollectionDescriptor(
            id: "folder:F2", localIdentifier: "F2", title: "Folder 2",
            kind: .folder, pathComponents: ["Folder 1"],
            children: [
              PhotoCollectionDescriptor(
                id: "album:deep-C", localIdentifier: "deep-C", title: "Deep C",
                kind: .album, pathComponents: ["Folder 1", "Folder 2"],
                children: [])
            ]),
        ]),
    ]

    let ids = PhotoCollectionDescriptor.albumLocalIds(in: tree)

    #expect(ids == ["top-A", "nested-B", "deep-C"])
  }

  @Test func albumLocalIdsReturnsEmptyForFavoritesOnlyTree() {
    let tree: [PhotoCollectionDescriptor] = [
      PhotoCollectionDescriptor(
        id: "favorites", localIdentifier: nil, title: "Favorites",
        kind: .favorites, pathComponents: [], children: [])
    ]
    #expect(PhotoCollectionDescriptor.albumLocalIds(in: tree).isEmpty)
  }

  /// Shared albums must not leak into the user-album batch — `albumLocalIds`
  /// is what `startExportAllAlbums` walks, and shared albums are intentionally
  /// excluded from that batch (they export at reduced quality and need explicit
  /// opt-in). One-line failure here would silently send shared-album content
  /// through the "Export All Albums" path.
  @Test func albumLocalIdsExcludesSharedAlbums() {
    let user = PhotoCollectionDescriptor(
      id: "album:user-1", localIdentifier: "user-1", title: "Trip",
      kind: .album, pathComponents: [], children: [])
    let shared = PhotoCollectionDescriptor(
      id: "shared-album:shared-1", localIdentifier: "shared-1", title: "Family",
      kind: .sharedAlbum, pathComponents: [], children: [])
    let ids = PhotoCollectionDescriptor.albumLocalIds(in: [user, shared])
    #expect(ids == ["user-1"])
  }

  /// `sharedAlbumLocalIds` is a flat top-level filter: it doesn't recurse into
  /// folders, doesn't match `.album` kind, and returns shared albums in tree
  /// order. The flat scope is the contract — shared albums don't nest in
  /// PhotoKit, so any future "recurse through folders" change is a bug.
  @Test func sharedAlbumLocalIdsReturnsOnlySharedTopLevel() {
    let user = PhotoCollectionDescriptor(
      id: "album:user-1", localIdentifier: "user-1", title: "Trip",
      kind: .album, pathComponents: [], children: [])
    let folder = PhotoCollectionDescriptor(
      id: "folder:f", localIdentifier: "f", title: "Folder",
      kind: .folder, pathComponents: [], children: [user])
    let s1 = PhotoCollectionDescriptor(
      id: "shared-album:s1", localIdentifier: "s1", title: "Family",
      kind: .sharedAlbum, pathComponents: [], children: [])
    let s2 = PhotoCollectionDescriptor(
      id: "shared-album:s2", localIdentifier: "s2", title: "Friends",
      kind: .sharedAlbum, pathComponents: [], children: [])
    let ids = PhotoCollectionDescriptor.sharedAlbumLocalIds(in: [folder, s1, s2])
    #expect(ids == ["s1", "s2"])
  }

  // MARK: - Test harness

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

    /// Tear down in the right order: cancel anything in flight, flush both stores'
    /// IO queues so no async append is still racing toward the temp dirs, remove
    /// the dirs, drop the per-suite UserDefaults. Tests using `AsyncCheckpoint`
    /// must call `await checkpoint.releaseAll()` before this so suspended
    /// writer/fetch tasks unblock — otherwise `cancelAndClear` waits on tasks
    /// that have nothing to wake them up.
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
      .appendingPathComponent("ExportAllAlbums-\(UUID().uuidString)", isDirectory: true)
    let timelineStore = ExportRecordStore(baseDirectoryURL: storeRoot)
    timelineStore.configure(for: "test")
    let collectionStore = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    collectionStore.configure(for: "test")
    let suiteName = "test-ExportAllAlbums-\(UUID().uuidString)"
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

  private func makeAsset(id: String) -> AssetDescriptor {
    AssetDescriptor(
      id: id, creationDate: Date(timeIntervalSince1970: 1_700_000_000),
      mediaType: .image, pixelWidth: 100, pixelHeight: 100, duration: 0,
      hasAdjustments: false)
  }

  /// Adds a top-level album with `ids` assets. Mirrors the seeding helper in
  /// QueueStateAcrossModesTests.
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

  // MARK: - Enqueue behaviour

  /// Top-level albums and albums nested under folders both reach the queue.
  /// Favorites assets are present in the canned data but are NOT enqueued
  /// because the batch is albums-only.
  @Test func enqueuesEveryAlbumIncludingNestedAndExcludesFavorites() async throws {
    let h = makeHarness()
    defer { h.cleanup() }

    let topAlbum = seedAlbum(h.photoLib, localId: "top-A", ids: ["a1", "a2"])
    let nestedAlbum = seedAlbum(
      h.photoLib, localId: "nested-B", ids: ["b1"], pathComponents: ["F1"])

    // Favorites is canonically present in the tree built by PhotoLibraryManager;
    // include it here so the test verifies the batch ignores it. Seed favorites
    // assets too — if the batch incorrectly routed favorites we'd see them in
    // the enqueued count.
    let favorites = PhotoCollectionDescriptor(
      id: "favorites", localIdentifier: nil, title: "Favorites",
      kind: .favorites, pathComponents: [], children: [])
    let favAsset = makeAsset(id: "fav1")
    h.photoLib.favoritesAssets = [favAsset]
    h.photoLib.resourcesByAssetId["fav1"] = [
      ResourceDescriptor(type: .photo, originalFilename: "fav1.HEIC")
    ]

    let folder = PhotoCollectionDescriptor(
      id: "folder:F1", localIdentifier: "F1", title: "F1",
      kind: .folder, pathComponents: [], children: [nestedAlbum])

    h.photoLib.collectionTree = [favorites, topAlbum, folder]

    h.manager.startExportAllAlbums()
    await waitUntil(h.manager.totalJobsEnqueued == 3)

    #expect(h.manager.totalJobsEnqueued == 3)

    // Every queued placement must be an album — never `.favorites` or `.timeline`.
    let kinds = Set(h.manager.pendingJobs.map { $0.placement.kind })
    #expect(kinds.isSubset(of: [.album]))
  }

  /// Bulk-album export drops `phAssetCache` between iterations to bound peak
  /// memory at one album's working set rather than the cumulative 282-album
  /// sweep. Pins the structural property responsible for keeping a sandboxed
  /// macOS app under its memory high watermark on large libraries (issue #112).
  ///
  /// The assertion goes through a `RecordingPHAssetCacheControl` spy injected
  /// at `ExportManager` init. A future refactor that drops the
  /// `phAssetCacheControl.forgetPHAssetCache()` line from `runBulkEnqueueLoop`
  /// would let `forgetCallCount` stay below the album count and fail this
  /// test — the structural defence against silent re-introduction of the
  /// bug. (Real cache emptiness is verified by code-reading rather than
  /// directly observed because `PHAsset` can't be constructed in unit tests
  /// without PhotoKit authorisation; the spy is the load-bearing test
  /// surface, mirroring `RecordingDirectoryFsync` from PR #114.)
  @Test func bulkAlbumExportCallsForgetPHAssetCachePerAlbum() async throws {
    let photoLib = FakePhotoLibraryService()
    let dest = FakeExportDestination()
    let writer = FakeAssetResourceWriter()
    let fileSystem = FakeFileSystem()
    let storeRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("ExportAllAlbums-cache-\(UUID().uuidString)", isDirectory: true)
    let timelineStore = ExportRecordStore(baseDirectoryURL: storeRoot)
    timelineStore.configure(for: "test")
    let collectionStore = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    collectionStore.configure(for: "test")
    let suiteName = "test-ExportAllAlbums-cache-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let cacheControl = RecordingPHAssetCacheControl()
    let manager = ExportManager(
      photoLibraryService: photoLib,
      exportDestination: dest,
      exportRecordStore: timelineStore,
      collectionExportRecordStore: collectionStore,
      assetResourceWriter: writer,
      fileSystem: fileSystem,
      phAssetCacheControl: cacheControl,
      userDefaults: defaults
    )
    defer {
      manager.cancelAndClear()
      timelineStore.flushForTesting()
      collectionStore.flushForTesting()
      try? FileManager.default.removeItem(at: storeRoot)
      dest.cleanup()
      UserDefaults().removePersistentDomain(forName: suiteName)
    }

    let albumA = seedAlbum(photoLib, localId: "A", ids: ["a1"])
    let albumB = seedAlbum(photoLib, localId: "B", ids: ["b1"])
    let albumC = seedAlbum(photoLib, localId: "C", ids: ["c1"])
    photoLib.collectionTree = [albumA, albumB, albumC]

    manager.startExportAllAlbums()
    await waitUntil(manager.totalJobsEnqueued == 3)

    // The bulk loop's items list also includes the no-op favorites pass
    // (a 0-or-1 element pass) and the shared-albums pass (also 0 or 1).
    // For a tree with three albums and no favorites/shared, the favorites
    // pass runs 0 iterations, the albums pass runs 3, the shared pass
    // runs 0. Per-iteration drops therefore total 3. If the implementation
    // later changes to run a 0-element favorites pass through a
    // runBulkEnqueueLoop call, the assertion may need a `>=` rather than
    // an exact match — the architectural invariant is "at least one drop
    // per real bulk iteration".
    #expect(
      cacheControl.forgetCallCount >= 3,
      "runBulkEnqueueLoop must call forgetPHAssetCache() at least once per album; got \(cacheControl.forgetCallCount)"
    )
  }

  @Test func emptyAlbumTreeSetsNoAlbumsMessage() async throws {
    let h = makeHarness()
    defer { h.cleanup() }

    h.photoLib.collectionTree = [
      PhotoCollectionDescriptor(
        id: "favorites", localIdentifier: nil, title: "Favorites",
        kind: .favorites, pathComponents: [], children: [])
    ]

    h.manager.startExportAllAlbums()
    await waitUntil(h.manager.emptyRunMessage != nil)

    #expect(h.manager.emptyRunMessage == "No albums to export.")
    #expect(h.manager.totalJobsEnqueued == 0)
  }

  /// During the "queued but run loop not started" window — `enqueueCollection` has
  /// appended jobs from album A but the album-B `fetchAssets` is still suspended —
  /// `pause()` must be honoured. Pre-fix it was a no-op (it required `isRunning`),
  /// so the queue would resume processing as soon as the enqueue loop completed
  /// and called `processQueueIfNeeded()`.
  @Test func pauseHonoredDuringEnqueueWindow() async throws {
    let h = makeHarness()
    defer { h.cleanup() }

    let albumA = seedAlbum(h.photoLib, localId: "A", ids: ["a1"])
    let albumB = seedAlbum(h.photoLib, localId: "B", ids: ["b1"])
    h.photoLib.collectionTree = [albumA, albumB]
    // Gate album B's fetch deterministically. The enqueue loop will reach
    // album B, suspend on `enter()`, and stay there until we release. That
    // pins the "queued (album A's jobs) but run loop not started yet" window
    // open for as long as the test needs — no sleeping.
    let fetchGate = AsyncCheckpoint()
    h.photoLib.fetchAssetsCheckpointByAlbumId["B"] = fetchGate

    h.manager.startExportAllAlbums()

    // Wait until the enqueue loop has appended album A's job and is
    // suspended on album B's fetch gate.
    await fetchGate.waitForEnter(count: 1)
    #expect(h.manager.queueCount > 0)
    #expect(h.manager.isEnqueueingAll)
    #expect(!h.manager.isRunning)

    // The pre-fix bug: pause() guarded on `isRunning`, so this no-op'd.
    h.manager.pause()
    #expect(h.manager.isPaused)

    // Release the fetch gate so the enqueue loop can complete and call
    // processQueueIfNeeded(). With pause held, the run loop must NOT start.
    await fetchGate.release(1)
    await waitUntil(!h.manager.isEnqueueingAll)
    #expect(h.manager.isPaused)
    #expect(!h.manager.isRunning)
    #expect(h.manager.queueCount > 0)

    // Resume drains the queue normally.
    h.manager.resume()
    await waitUntil(h.manager.queueCount == 0)
    #expect(h.manager.queueCount == 0)

    await fetchGate.releaseAll()
  }

  /// A throw partway through the album loop must not strand earlier albums' jobs in
  /// `pendingJobs` with no active processor. The catch path drains what was queued and
  /// surfaces the partial state via the empty-run message slot.
  @Test func partialEnqueueFailureDrainsTheJobsAlreadyQueued() async throws {
    let h = makeHarness()
    defer { h.cleanup() }

    let albumA = seedAlbum(h.photoLib, localId: "album-A", ids: ["a1", "a2"])
    let albumB = seedAlbum(h.photoLib, localId: "broken-album", ids: ["b1"])
    h.photoLib.collectionTree = [albumA, albumB]
    h.photoLib.fetchAssetsErrorByAlbumId["broken-album"] = NSError(
      domain: "Test", code: 7, userInfo: [NSLocalizedDescriptionKey: "boom"])

    // Gate the writer so we can step through the queue drain deterministically.
    // The queue processes one job at a time, so the second writer cannot enter
    // while the first is still suspended on the gate — release sequentially.
    let writeGate = AsyncCheckpoint()
    h.writer.checkpoint = writeGate

    h.manager.startExportAllAlbums()
    await writeGate.waitForEnter(count: 1)
    await writeGate.release(1)
    await writeGate.waitForEnter(count: 2)
    await writeGate.releaseAll()
    await waitUntil(h.manager.totalJobsCompleted == 2)

    // Album A's two jobs were already queued before B threw. They must drain
    // and the queue empties.
    #expect(h.manager.totalJobsCompleted == 2)
    #expect(h.manager.queueCount == 0)
    #expect(!h.manager.isEnqueueingAll)
    // The partial-failure message lands in the queue-warning slot (rendered alongside
    // active progress). emptyRunMessage stays nil because the queue isn't empty.
    #expect(
      h.manager.queueWarningMessage
        == "Couldn't list every album. Continuing with the photos already queued.")
    #expect(h.manager.emptyRunMessage == nil)
  }

  @Test func allAlbumsAlreadyExportedSetsAlreadyDoneMessage() async throws {
    let h = makeHarness()
    defer { h.cleanup() }

    let album = seedAlbum(h.photoLib, localId: "done-album", ids: ["d1"])
    h.photoLib.collectionTree = [album]

    // Pre-populate the collection store via the same resolver `enqueueCollection`
    // uses, so the placement id matches what the enqueue path will compute.
    let placement = try ExportPlacementResolver().placement(
      for: .album(collectionId: "done-album"),
      collections: h.photoLib.collectionTree,
      existingPlacements: []
    )
    h.collectionStore.upsertPlacement(placement)
    // Asset has `hasAdjustments: false`, so `.edited` selection mode requires
    // the `.original` variant only.
    h.collectionStore.markVariantExported(
      assetId: "d1", placement: placement, variant: .original,
      filename: "d1.HEIC", exportedAt: Date())

    h.manager.startExportAllAlbums()
    await waitUntil(h.manager.emptyRunMessage != nil)

    #expect(
      h.manager.emptyRunMessage == "All albums in this destination are already exported.")
    #expect(h.manager.totalJobsEnqueued == 0)
  }

  /// AutoSync passes `selectionOverride` so a scheduled run honours the AutoSync
  /// version selection regardless of the current UI toggle. The override must
  /// thread through to every queued `ExportJob.selection`, not just the first.
  @Test func selectionOverrideThreadsToEveryQueuedJob() async throws {
    let h = makeHarness()
    defer { h.cleanup() }

    let albumA = seedAlbum(h.photoLib, localId: "A", ids: ["a1"])
    let albumB = seedAlbum(h.photoLib, localId: "B", ids: ["b1"])
    let albumC = seedAlbum(h.photoLib, localId: "C", ids: ["c1"])
    h.photoLib.collectionTree = [albumA, albumB, albumC]

    // UI toggle says `.edited`; AutoSync schedules a run with `.editedWithOriginals`.
    // The queued jobs must reflect the override, not the toggle.
    h.manager.versionSelection = .edited

    // Gate the worker after it pulls the first job so the remaining two stay in
    // `pendingJobs` and we can read their `.selection` directly.
    let writerGate = AsyncCheckpoint()
    h.writer.checkpoint = writerGate

    h.manager.startExportAllAlbums(selectionOverride: .editedWithOriginals)
    await waitUntil(h.manager.totalJobsEnqueued == 3)
    await writerGate.waitForEnter(count: 1)

    // Every still-queued job carries the override selection — proves the
    // parameter threaded through the helper into the per-album `enqueueCollection`
    // call, not just into the first.
    let pendingSelections = Set(h.manager.pendingJobs.map(\.selection))
    #expect(pendingSelections == [.editedWithOriginals])
    // UI toggle is unchanged — override is per-run, not a side effect.
    #expect(h.manager.versionSelection == .edited)

    await writerGate.releaseAll()
  }

  /// Inverse variant: toggle says `.editedWithOriginals`, override says `.edited`.
  /// Without this case, the prior test could pass even if `selectionOverride` were
  /// silently ignored and the toggle were read directly — both would happen to
  /// equal the same default value. Two opposite-direction tests isolate the
  /// parameter-threading from a coincidental match.
  @Test func selectionOverrideWinsOverToggleInBothDirections() async throws {
    let h = makeHarness()
    defer { h.cleanup() }

    let album = seedAlbum(h.photoLib, localId: "A", ids: ["a1", "a2"])
    h.photoLib.collectionTree = [album]

    h.manager.versionSelection = .editedWithOriginals

    let writerGate = AsyncCheckpoint()
    h.writer.checkpoint = writerGate

    h.manager.startExportAllAlbums(selectionOverride: .edited)
    await waitUntil(h.manager.totalJobsEnqueued == 2)
    await writerGate.waitForEnter(count: 1)

    let pendingSelections = Set(h.manager.pendingJobs.map(\.selection))
    #expect(pendingSelections == [.edited])
    #expect(h.manager.versionSelection == .editedWithOriginals)

    await writerGate.releaseAll()
  }
}
