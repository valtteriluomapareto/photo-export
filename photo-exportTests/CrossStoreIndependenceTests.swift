import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Plan §"Cross-store independence" (`docs/project/archive/collections-export-plan.md`):
/// the timeline and collection record stores share no key space. A failure on one side
/// must never mutate state on the other for the same asset, and a corrupt collection
/// store must not block timeline export operations (and vice versa). These tests prove
/// the disjoint-key-space invariant at the `ExportManager` integration level — the
/// per-store rejection guards in `CollectionExportRecordStoreTests` cover the unit-level
/// API; this suite covers the integration paths that touch both stores in one run.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct CrossStoreIndependenceTests {

  // MARK: - Fixtures

  private func makeManager(suiteName: String? = nil) throws -> (
    ExportManager, FakePhotoLibraryService, FakeExportDestination, FakeAssetResourceWriter,
    FakeFileSystem, ExportRecordStore, CollectionExportRecordStore, URL
  ) {
    let photoLib = FakePhotoLibraryService()
    let dest = FakeExportDestination()
    let writer = FakeAssetResourceWriter()
    let fileSystem = FakeFileSystem()
    let storeRoot = TestScratch.directory("CrossStoreInd")
    let timelineStore = ExportRecordStore(baseDirectoryURL: storeRoot)
    timelineStore.configure(for: "test")
    let collectionStore = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    collectionStore.configure(for: "test")
    let defaults = TestScratch.defaults(
      suiteName: suiteName ?? TestScratch.suiteName("CrossStore"))
    let manager = ExportManager(
      photoLibraryService: photoLib,
      exportDestination: dest,
      exportRecordStore: timelineStore,
      collectionExportRecordStore: collectionStore,
      assetResourceWriter: writer,
      fileSystem: fileSystem,
      userDefaults: defaults
    )
    return (manager, photoLib, dest, writer, fileSystem, timelineStore, collectionStore, storeRoot)
  }

  private func makeAsset(id: String, year: Int = 2025, month: Int = 4) -> AssetDescriptor {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = 15
    let date = Calendar.current.date(from: components) ?? Date(timeIntervalSince1970: 1_700_000_000)
    return AssetDescriptor(
      id: id,
      creationDate: date,
      mediaType: .image,
      pixelWidth: 100,
      pixelHeight: 100,
      duration: 0,
      hasAdjustments: false
    )
  }

  // MARK: - Failure on one side does not mutate the other

  /// A failed favorites export marks the failure on the collection store only — the
  /// timeline store has no entry for the same asset id afterward.
  @Test func favoritesFailureDoesNotMutateTimelineStore() async throws {
    let (
      manager, photoLib, dest, writer, _, timelineStore, collectionStore, storeRoot
    ) = try makeManager()
    defer {
      try? FileManager.default.removeItem(at: storeRoot)
      dest.cleanup()
    }

    let asset = makeAsset(id: "shared-asset", year: 2025, month: 5)
    photoLib.favoritesAssets = [asset]
    photoLib.resourcesByAssetId[asset.id] = [
      ResourceDescriptor(type: .photo, originalFilename: "IMG.HEIC")
    ]

    writer.writeError = NSError(
      domain: "Test", code: 42, userInfo: [NSLocalizedDescriptionKey: "Disk full"])
    writer.shouldCreateFile = false

    manager.startExportFavorites()
    await manager.waitForQueueDrained()

    // Collection store records the failure under the favorites placement.
    let favorites = ExportPlacement.favorites()
    let collectionRecord = collectionStore.exportInfo(
      assetId: asset.id, placement: favorites)
    #expect(collectionRecord?.variants[.original]?.status == .failed)
    #expect(collectionRecord?.variants[.original]?.lastError?.contains("Disk full") == true)

    // Timeline store is untouched — no record at all for this asset id.
    #expect(timelineStore.exportInfo(assetId: asset.id) == nil)
  }

  /// A failed timeline export marks the failure on the timeline store only — the
  /// collection store has no entry for the same asset id afterward.
  @Test func timelineFailureDoesNotMutateCollectionStore() async throws {
    let (
      manager, photoLib, dest, writer, _, timelineStore, collectionStore, storeRoot
    ) = try makeManager()
    defer {
      try? FileManager.default.removeItem(at: storeRoot)
      dest.cleanup()
    }

    let asset = makeAsset(id: "shared-asset", year: 2025, month: 7)
    photoLib.assetsByYearMonth["2025-7"] = [asset]
    photoLib.resourcesByAssetId[asset.id] = [
      ResourceDescriptor(type: .photo, originalFilename: "IMG.HEIC")
    ]

    writer.writeError = NSError(
      domain: "Test", code: 99, userInfo: [NSLocalizedDescriptionKey: "Permission denied"])
    writer.shouldCreateFile = false

    manager.startExportMonth(year: 2025, month: 7)
    await manager.waitForQueueDrained()

    // Timeline store records the failure.
    let timelineRecord = timelineStore.exportInfo(assetId: asset.id)
    #expect(timelineRecord?.variants[.original]?.status == .failed)
    #expect(timelineRecord?.variants[.original]?.lastError?.contains("Permission denied") == true)

    // Collection store has no entry for the asset under any placement.
    #expect(collectionStore.recordBodies.isEmpty)
  }

  // MARK: - cancelAndClear routes per-placement

  /// `cancelAndClear` mid-flight on a timeline job removes the in-progress variant from
  /// the timeline store only; the same asset’s collection record stays unchanged.
  @Test(.timeLimit(.minutes(2))) func cancelAndClearOnTimelineDoesNotTouchCollectionStore()
    async throws
  {
    let suite = TestScratch.suiteName("cancel-timeline")
    let (
      manager, photoLib, dest, writer, _, timelineStore, collectionStore, storeRoot
    ) = try makeManager(suiteName: suite)
    let gate = AsyncCheckpoint()
    writer.checkpoint = gate
    var tasks: [Task<Void, Never>] = []
    func cleanup() async {
      tasks += manager.currentPreparationTasks
      if let task = manager.currentTask { tasks.append(task) }
      manager.cancelAndClear()
      await gate.releaseAll()
      for task in tasks { await task.value }
      timelineStore.flushForTesting()
      collectionStore.flushForTesting()
      try? FileManager.default.removeItem(at: storeRoot)
      dest.cleanup()
    }
    do {
      let asset = makeAsset(id: "cancel-asset", year: 2025, month: 8)
      photoLib.assetsByYearMonth["2025-8"] = [asset]
      photoLib.resourcesByAssetId[asset.id] = [
        ResourceDescriptor(type: .photo, originalFilename: "IMG.HEIC")
      ]
      let favorites = ExportPlacement.favorites()
      collectionStore.upsertPlacement(favorites)
      collectionStore.markVariantInProgress(
        assetId: asset.id, placement: favorites, variant: .original,
        filename: "CONTROL.HEIC", subfolder: "preserved")
      let control = try #require(
        collectionStore.exportInfo(assetId: asset.id, placement: favorites))
      let controlPlacement = try #require(collectionStore.placements[favorites.id])

      manager.startExportMonth(year: 2025, month: 8)
      try #require(await gate.waitForEnter(count: 1))
      let oldTask = try #require(manager.currentTask)
      tasks.append(oldTask)
      try #require(writer.writeCalls.count == 1)
      try #require(
        timelineStore.exportInfo(assetId: asset.id)?.variants[.original]?.status == .inProgress)
      try #require(collectionStore.exportInfo(assetId: asset.id, placement: favorites) == control)
      let placementsBeforeCancel = collectionStore.placements

      manager.cancelAndClear()
      #expect(timelineStore.exportInfo(assetId: asset.id)?.variants[.original] == nil)
      #expect(collectionStore.exportInfo(assetId: asset.id, placement: favorites) == control)
      let placementsAfterCancel = collectionStore.placements
      await gate.releaseAll()
      await oldTask.value
      #expect(timelineStore.exportInfo(assetId: asset.id)?.variants[.original] == nil)
      #expect(collectionStore.exportInfo(assetId: asset.id, placement: favorites) == control)
      // Placement equality is ID-only; inspect the actual stored metadata at each boundary.
      for placements in [placementsBeforeCancel, placementsAfterCancel, collectionStore.placements]
      {
        #expect(Set(placements.keys) == [favorites.id])
        let stored = try #require(placements[favorites.id])
        #expect(stored.id == controlPlacement.id)
        #expect(stored.kind == controlPlacement.kind)
        #expect(stored.displayName == controlPlacement.displayName)
        #expect(stored.collectionLocalIdentifier == controlPlacement.collectionLocalIdentifier)
        #expect(stored.relativePath == controlPlacement.relativePath)
        #expect(stored.createdAt == controlPlacement.createdAt)
      }
    } catch {
      await cleanup()
      throw error
    }
    await cleanup()
  }

  /// Symmetric: cancel mid-flight on a favorites job leaves the timeline store
  /// untouched.
  @Test(.timeLimit(.minutes(2))) func cancelAndClearOnFavoritesDoesNotTouchTimelineStore()
    async throws
  {
    let suite = TestScratch.suiteName("cancel-favorites")
    let (
      manager, photoLib, dest, writer, _, timelineStore, collectionStore, storeRoot
    ) = try makeManager(suiteName: suite)
    let gate = AsyncCheckpoint()
    writer.checkpoint = gate
    var tasks: [Task<Void, Never>] = []
    func cleanup() async {
      tasks += manager.currentPreparationTasks
      if let task = manager.currentTask { tasks.append(task) }
      manager.cancelAndClear()
      await gate.releaseAll()
      for task in tasks { await task.value }
      timelineStore.flushForTesting()
      collectionStore.flushForTesting()
      try? FileManager.default.removeItem(at: storeRoot)
      dest.cleanup()
    }
    do {
      let asset = makeAsset(id: "fav-cancel-asset")
      photoLib.favoritesAssets = [asset]
      photoLib.resourcesByAssetId[asset.id] = [
        ResourceDescriptor(type: .photo, originalFilename: "IMG.HEIC")
      ]
      timelineStore.markVariantInProgress(
        assetId: asset.id, variant: .original, year: 2020, month: 2,
        relPath: "2020/02/", filename: "CONTROL.HEIC", subfolder: "preserved")
      let control = try #require(timelineStore.exportInfo(assetId: asset.id))
      let favorites = ExportPlacement.favorites()

      manager.startExportFavorites()
      try #require(await gate.waitForEnter(count: 1))
      let oldTask = try #require(manager.currentTask)
      tasks.append(oldTask)
      try #require(writer.writeCalls.count == 1)
      try #require(
        collectionStore.exportInfo(assetId: asset.id, placement: favorites)?.variants[.original]?
          .status == .inProgress)
      try #require(timelineStore.exportInfo(assetId: asset.id) == control)

      manager.cancelAndClear()
      #expect(
        collectionStore.exportInfo(assetId: asset.id, placement: favorites)?.variants[.original]
          == nil)
      #expect(timelineStore.exportInfo(assetId: asset.id) == control)
      await gate.releaseAll()
      await oldTask.value
      #expect(
        collectionStore.exportInfo(assetId: asset.id, placement: favorites)?.variants[.original]
          == nil)
      #expect(timelineStore.exportInfo(assetId: asset.id) == control)
    } catch {
      await cleanup()
      throw error
    }
    await cleanup()
  }

  // MARK: - .failed-state independence

  /// When the collection store is in `.failed` state (corrupt snapshot), `canExportTimeline`
  /// is still true and a timeline export still succeeds. The two stores' health is
  /// independent — a corrupt one does not block the other.
  @Test func failedCollectionStoreDoesNotBlockTimelineExport() async throws {
    let (
      manager, photoLib, dest, writer, _, _, collectionStore, storeRoot
    ) = try makeManager()
    defer {
      try? FileManager.default.removeItem(at: storeRoot)
      dest.cleanup()
    }

    // Force the collection store into .failed by writing a corrupt snapshot file at its
    // expected path and re-configuring.
    let collectionDir = storeRoot.appendingPathComponent("test", isDirectory: true)
    try FileManager.default.createDirectory(
      at: collectionDir, withIntermediateDirectories: true)
    let snapshotURL = collectionDir.appendingPathComponent(
      CollectionExportRecordStore.Constants.snapshotFileName)
    try Data("not valid json".utf8).write(to: snapshotURL)
    collectionStore.configure(for: "test")
    #expect(collectionStore.state == .failed)
    #expect(!manager.canExportCollection)
    #expect(manager.canExportTimeline, "timeline must remain exportable when collection is failed")

    // Timeline export proceeds normally.
    let asset = makeAsset(id: "tl-asset", year: 2025, month: 9)
    photoLib.assetsByYearMonth["2025-9"] = [asset]
    photoLib.resourcesByAssetId[asset.id] = [
      ResourceDescriptor(type: .photo, originalFilename: "IMG.HEIC")
    ]
    manager.startExportMonth(year: 2025, month: 9)
    await manager.waitForQueueDrained()

    let info = manager.exportRecordStore.exportInfo(assetId: asset.id)
    #expect(info?.variants[.original]?.status == .done)
    #expect(writer.writeCalls.count == 1)
  }

  /// Symmetric: a `.failed` timeline store does not block collection exports.
  @Test func failedTimelineStoreDoesNotBlockCollectionExport() async throws {
    let (
      manager, photoLib, dest, writer, _, timelineStore, _, storeRoot
    ) = try makeManager()
    defer {
      try? FileManager.default.removeItem(at: storeRoot)
      dest.cleanup()
    }

    // Force the timeline store into .failed.
    let timelineDir = storeRoot.appendingPathComponent("test", isDirectory: true)
    try FileManager.default.createDirectory(
      at: timelineDir, withIntermediateDirectories: true)
    let snapshotURL = timelineDir.appendingPathComponent(
      ExportRecordStore.Constants.snapshotFileName)
    try Data("garbage".utf8).write(to: snapshotURL)
    timelineStore.configure(for: "test")
    #expect(timelineStore.state == .failed)
    #expect(!manager.canExportTimeline)
    #expect(
      manager.canExportCollection,
      "collection must remain exportable when timeline is failed")

    let asset = makeAsset(id: "fav-asset")
    photoLib.favoritesAssets = [asset]
    photoLib.resourcesByAssetId[asset.id] = [
      ResourceDescriptor(type: .photo, originalFilename: "IMG.HEIC")
    ]
    manager.startExportFavorites()
    await manager.waitForQueueDrained()

    let info = manager.collectionExportRecordStore.exportInfo(
      assetId: asset.id, placement: ExportPlacement.favorites())
    #expect(info?.variants[.original]?.status == .done)
    #expect(writer.writeCalls.count == 1)
  }
}
