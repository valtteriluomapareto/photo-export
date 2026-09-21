import Foundation
import Photos
import Testing

@testable import Photo_Export

/// End-to-end tests for the Advanced Settings → Cleanup options, driven through
/// the real export pipeline:
/// - "Replace updated files": modified assets re-export and replace their
///   destination files instead of suffixing duplicates; stale variants that no
///   longer fit the selection are removed.
/// - Mirror mode (all four options on): deletions in the library and album
///   trees are mirrored into the destination and empty folders pruned.
@MainActor
struct ExportCleanupEndToEndTests {

  @MainActor
  private struct Harness {
    let manager: ExportManager
    let photoLib: FakePhotoLibraryService
    let dest: FakeExportDestination
    let writer: FakeAssetResourceWriter
    let fileSystem: FakeFileSystem
    let store: ExportRecordStore
    let collectionStore: CollectionExportRecordStore
    let storeRoot: URL
    let userDefaultsSuite: String

    func cleanup() async {
      if let checkpoint = writer.checkpoint {
        await checkpoint.releaseAll()
      }
      manager.cancelAndClear()
      store.flushForTesting()
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
      .appendingPathComponent("ExportCleanupE2E-\(UUID().uuidString)", isDirectory: true)
    let store = ExportRecordStore(baseDirectoryURL: storeRoot)
    store.configure(for: "test")
    let collectionStore = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    collectionStore.configure(for: "test")
    let suiteName = "test-ExportCleanupE2E-\(UUID().uuidString)"
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
      fileSystem: fileSystem, store: store, collectionStore: collectionStore,
      storeRoot: storeRoot, userDefaultsSuite: suiteName)
  }

  private func files(in directory: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
  }

  // MARK: - Replace updated files

  /// A modified asset re-exports and replaces the file at the same name — no
  /// "(1)" duplicate is created and the record's export date moves forward.
  @Test func replaceOverwritesInsteadOfSuffixing() async throws {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }
    harness.manager.replaceUpdatedFiles = true

    let asset = TestAssetFactory.makeAsset(
      id: "replace-1", creationDate: Date(timeIntervalSince1970: 1_000),
      modificationDate: Date(timeIntervalSince1970: 1_000))
    harness.photoLib.assetsByYearMonth["2025-1"] = [asset]
    harness.photoLib.resourcesByAssetId[asset.id] = [
      TestAssetFactory.makeResource(originalFilename: "IMG_0001.HEIC")
    ]

    harness.manager.startExportMonth(year: 2025, month: 1)
    await harness.manager.waitForQueueDrained()

    let monthDir = harness.dest.rootURL.appendingPathComponent("2025/01")
    #expect(files(in: monthDir) == ["IMG_0001.HEIC"])
    let firstRecord = harness.store.exportInfo(assetId: asset.id)
    #expect(firstRecord?.variants[.original]?.status == .done)

    // The asset changes in Photos after the export (modification date later
    // than the recorded export timestamp).
    let modified = TestAssetFactory.makeAsset(
      id: "replace-1", creationDate: Date(timeIntervalSince1970: 1_000),
      modificationDate: Date().addingTimeInterval(60))
    harness.photoLib.assetsByYearMonth["2025-1"] = [modified]

    harness.manager.startExportMonth(year: 2025, month: 1)
    await harness.manager.waitForQueueDrained()

    // The stale asset was actually re-exported (replaced, not duplicated).
    #expect(harness.writer.writeCalls.count == 2)
    #expect(
      files(in: monthDir) == ["IMG_0001.HEIC"],
      "got \(files(in: monthDir)) — replace mode must not suffix duplicates")
    let secondRecord = harness.store.exportInfo(assetId: asset.id)
    #expect(secondRecord?.variants[.original]?.status == .done)
    let firstDate = firstRecord?.variants[.original]?.exportDate
    let secondDate = secondRecord?.variants[.original]?.exportDate
    #expect((secondDate?.timeIntervalSince1970 ?? 0) >= (firstDate?.timeIntervalSince1970 ?? 0))
  }

  /// With the option off (default), a modified asset is skipped entirely —
  /// today's additive behavior is preserved.
  @Test func replaceOptionOffSkipsModifiedAsset() async throws {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }
    #expect(!harness.manager.replaceUpdatedFiles)

    let asset = TestAssetFactory.makeAsset(
      id: "replace-off", creationDate: Date(timeIntervalSince1970: 1_000),
      modificationDate: Date(timeIntervalSince1970: 1_000))
    harness.photoLib.assetsByYearMonth["2025-1"] = [asset]
    harness.photoLib.resourcesByAssetId[asset.id] = [
      TestAssetFactory.makeResource(originalFilename: "IMG_0001.HEIC")
    ]

    harness.manager.startExportMonth(year: 2025, month: 1)
    await harness.manager.waitForQueueDrained()
    let firstCount = harness.writer.writeCalls.count
    #expect(firstCount == 1)

    let modified = TestAssetFactory.makeAsset(
      id: "replace-off", creationDate: Date(timeIntervalSince1970: 1_000),
      modificationDate: Date().addingTimeInterval(60))
    harness.photoLib.assetsByYearMonth["2025-1"] = [modified]

    harness.manager.startExportMonth(year: 2025, month: 1)
    await harness.manager.waitForQueueDrained()

    #expect(
      harness.writer.writeCalls.count == firstCount,
      "option off: no re-export of the modified asset")
  }

  /// An asset that gains an edit after export: under `.edited` selection the
  /// stale natural-stem original is removed and the edit takes its place.
  @Test func gainedEditRemovesStaleOriginalAndWritesEdit() async throws {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }
    // The stale-original removal is the deletion half, so it rides on
    // "Remove deleted files"; replace governs overwrite-vs-keep on rewrite.
    harness.manager.replaceUpdatedFiles = true
    harness.manager.removeDeletedFiles = true

    let assetId = "gained-edit"
    var asset = TestAssetFactory.makeAsset(
      id: assetId, creationDate: Date(timeIntervalSince1970: 1_000),
      modificationDate: Date(timeIntervalSince1970: 1_000))
    harness.photoLib.assetsByYearMonth["2025-1"] = [asset]
    harness.photoLib.resourcesByAssetId[assetId] = [
      TestAssetFactory.makeResource(originalFilename: "IMG_0001.HEIC")
    ]

    harness.manager.startExportMonth(year: 2025, month: 1)
    await harness.manager.waitForQueueDrained()
    let monthDir = harness.dest.rootURL.appendingPathComponent("2025/01")
    #expect(files(in: monthDir) == ["IMG_0001.HEIC"])

    // The user edits the asset in Photos: adjustments on, edited resource
    // available, modification date bumped.
    asset = TestAssetFactory.makeAsset(
      id: assetId, creationDate: Date(timeIntervalSince1970: 1_000),
      hasAdjustments: true, modificationDate: Date().addingTimeInterval(60))
    harness.photoLib.assetsByYearMonth["2025-1"] = [asset]
    harness.photoLib.resourcesByAssetId[assetId] = [
      TestAssetFactory.makeResource(originalFilename: "IMG_0001.HEIC"),
      TestAssetFactory.makeResource(
        type: .fullSizePhoto, originalFilename: "FullRender.JPG"),
    ]

    harness.manager.startExportMonth(year: 2025, month: 1)
    await harness.manager.waitForQueueDrained()

    // The pre-edit original is gone; the edit is the only file left.
    #expect(
      files(in: monthDir) == ["IMG_0001.JPG"],
      "got \(files(in: monthDir))")
    let record = harness.store.exportInfo(assetId: assetId)
    #expect(record?.variants[.edited]?.status == .done)
    #expect(record?.variants[.original] == nil)
  }

  /// The issue #22 `_orig` fallback re-writes at the same stem on repeat runs —
  /// no "(1)" suffix accumulates while the edit stays unavailable.
  @Test func fallbackRewritesSameStemOnRepeat() async throws {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }
    harness.manager.replaceUpdatedFiles = true

    let assetId = "fallback-repeat"
    var asset = TestAssetFactory.makeAsset(
      id: assetId, creationDate: Date(timeIntervalSince1970: 1_000),
      hasAdjustments: true, modificationDate: Date(timeIntervalSince1970: 1_000))
    harness.photoLib.assetsByYearMonth["2025-1"] = [asset]
    // Adjusted asset with no edited-side resource → the edited write fails and
    // the fallback writes the original to the `_orig` slot.
    harness.photoLib.resourcesByAssetId[assetId] = [
      TestAssetFactory.makeResource(originalFilename: "IMG_0001.JPG")
    ]

    harness.manager.startExportMonth(year: 2025, month: 1)
    await harness.manager.waitForQueueDrained()
    let monthDir = harness.dest.rootURL.appendingPathComponent("2025/01")
    #expect(files(in: monthDir) == ["IMG_0001_orig.JPG"])

    // Asset "changes" again; Photos still has no edited resource.
    asset = TestAssetFactory.makeAsset(
      id: assetId, creationDate: Date(timeIntervalSince1970: 1_000),
      hasAdjustments: true, modificationDate: Date().addingTimeInterval(60))
    harness.photoLib.assetsByYearMonth["2025-1"] = [asset]

    harness.manager.startExportMonth(year: 2025, month: 1)
    await harness.manager.waitForQueueDrained()

    #expect(
      files(in: monthDir) == ["IMG_0001_orig.JPG"],
      "got \(files(in: monthDir)) — the fallback must rewrite, not suffix")
    let record = harness.store.exportInfo(assetId: assetId)
    #expect(record?.variants[.original]?.status == .done)
    #expect(
      record?.variants[.edited]?.lastError
        == ExportVariantRecovery.editedUnavailableOriginalBackedUpMessage)
  }

  // MARK: - Mirror mode (all four options on)

  /// Full mirroring run: an asset deleted from the library loses its file and
  /// record; a deleted album loses folder, files, records, and placement; an
  /// emptied month loses its empty folder tree.
  ///
  /// Uses the awaitable `runExport(context:)` API for the bulk scopes: the
  /// fire-and-forget `startExportAll` + `waitForQueueDrained` combination can
  /// starve the bulk-enqueue Task behind a resolved `currentTask` await in the
  /// shared test helper.
  @Test func mirrorModeDeletesRemovedAssetsAlbumsAndFolders() async throws {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }
    harness.manager.replaceUpdatedFiles = true
    harness.manager.removeDeletedFiles = true
    #expect(harness.manager.isMirrorMode)

    // Creation dates must sit in the intended months so `planTimelineYear`
    // buckets them correctly: January → 2025/01, mid-February → 2025/02.
    let janDate = Date(timeIntervalSince1970: 1_735_732_800)  // 2025-01-01T12:00Z
    let febDate = Date(timeIntervalSince1970: 1_739_606_400)  // 2025-02-15T12:00Z
    let stay = TestAssetFactory.makeAsset(
      id: "stay", creationDate: janDate,
      modificationDate: Date(timeIntervalSince1970: 1_000))
    let vanish = TestAssetFactory.makeAsset(
      id: "vanish", creationDate: janDate,
      modificationDate: Date(timeIntervalSince1970: 2_000))
    let doomed = TestAssetFactory.makeAsset(
      id: "doomed", creationDate: febDate,
      modificationDate: Date(timeIntervalSince1970: 3_000))
    harness.photoLib.assetsByYearMonth["2025-1"] = [stay, vanish]
    harness.photoLib.assetsByYearMonth["2025-2"] = [doomed]
    for asset in [stay, vanish, doomed] {
      harness.photoLib.resourcesByAssetId[asset.id] = [
        TestAssetFactory.makeResource(originalFilename: "\(asset.id.uppercased()).HEIC")
      ]
    }
    harness.photoLib.yearCounts = [(year: 2025, count: 3)]

    // Collections: album "Trip" with one asset.
    let tripAlbum = PhotoCollectionDescriptor(
      id: "album:album-trip", localIdentifier: "album-trip", title: "Trip", kind: .album,
      pathComponents: [], children: [])
    let tripAsset = TestAssetFactory.makeAsset(
      id: "trip-asset", creationDate: janDate,
      modificationDate: Date(timeIntervalSince1970: 4_000))
    harness.photoLib.collectionTree = [tripAlbum]
    harness.photoLib.assetsByAlbumLocalId["album-trip"] = [tripAsset]
    harness.photoLib.resourcesByAssetId[tripAsset.id] = [
      TestAssetFactory.makeResource(originalFilename: "TRIP.HEIC")
    ]

    // First pass: everything exports.
    _ = await harness.manager.runExport(
      context: ExportRunContext(
        source: .manual, visibility: .userVisible, scope: .timelineFullLibrary,
        selection: .edited))
    _ = await harness.manager.runExport(
      context: ExportRunContext(
        source: .manual, visibility: .userVisible, scope: .allAlbumsFull, selection: .edited))

    let janDir = harness.dest.rootURL.appendingPathComponent("2025/01")
    let febDir = harness.dest.rootURL.appendingPathComponent("2025/02")
    let tripDir = harness.dest.rootURL.appendingPathComponent("Collections/Albums/Trip")
    #expect(files(in: janDir) == ["STAY.HEIC", "VANISH.HEIC"])
    #expect(files(in: febDir) == ["DOOMED.HEIC"])
    #expect(files(in: tripDir) == ["TRIP.HEIC"])

    // Now the library changes: "vanish" and "doomed" are deleted, the Trip
    // album is gone.
    harness.photoLib.assetsByYearMonth["2025-1"] = [stay]
    harness.photoLib.assetsByYearMonth["2025-2"] = []
    harness.photoLib.collectionTree = []
    harness.photoLib.assetsByAlbumLocalId["album-trip"] = []

    _ = await harness.manager.runExport(
      context: ExportRunContext(
        source: .manual, visibility: .userVisible, scope: .timelineFullLibrary,
        selection: .edited))
    _ = await harness.manager.runExport(
      context: ExportRunContext(
        source: .manual, visibility: .userVisible, scope: .allAlbumsFull, selection: .edited))

    // 2025/01 lost its deleted file; 2025/02 emptied out and its folder tree
    // is gone; the Trip album folder is removed entirely.
    #expect(files(in: janDir) == ["STAY.HEIC"])
    #expect(!harness.dest.rootURL.appendingPathComponent("2025/02").doesDirectoryExist)
    #expect(!tripDir.doesDirectoryExist)
    #expect(harness.store.exportInfo(assetId: "vanish") == nil)
    #expect(harness.store.exportInfo(assetId: "doomed") == nil)
    #expect(harness.store.exportInfo(assetId: "stay") != nil)
    // The stale placement's records and metadata are gone.
    let stalePlacements = harness.collectionStore.recordBodies.keys.filter {
      $0.contains("album-trip")
    }
    #expect(stalePlacements.isEmpty)
  }

  /// Scope contract: typed runs (Export Month here) are scoped to their own
  /// export type — a month run must not touch album areas. Export All is the
  /// exception by design: its scope is the whole library, so its reconcile
  /// covers collection areas too.
  @Test func folderCleanupIsScopedToTheExportType() async throws {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }
    harness.manager.removeDeletedFiles = true

    // Album "Trip" with one asset exports first.
    let tripAlbum = PhotoCollectionDescriptor(
      id: "album:album-trip", localIdentifier: "album-trip", title: "Trip", kind: .album,
      pathComponents: [], children: [])
    let tripAsset = TestAssetFactory.makeAsset(
      id: "trip-asset", creationDate: Date(timeIntervalSince1970: 1_735_732_800),
      modificationDate: Date(timeIntervalSince1970: 1_000))
    harness.photoLib.collectionTree = [tripAlbum]
    harness.photoLib.assetsByAlbumLocalId["album-trip"] = [tripAsset]
    harness.photoLib.resourcesByAssetId[tripAsset.id] = [
      TestAssetFactory.makeResource(originalFilename: "TRIP.HEIC")
    ]
    // Timeline: one month, one asset.
    let asset = TestAssetFactory.makeAsset(
      id: "tl-1", creationDate: Date(timeIntervalSince1970: 1_735_732_800),
      modificationDate: Date(timeIntervalSince1970: 2_000))
    harness.photoLib.assetsByYearMonth["2025-1"] = [asset]
    harness.photoLib.resourcesByAssetId[asset.id] = [
      TestAssetFactory.makeResource(originalFilename: "TL1.HEIC")
    ]
    harness.photoLib.yearCounts = [(year: 2025, count: 2)]

    harness.manager.startExportMonth(year: 2025, month: 1)
    await harness.manager.waitForQueueDrained()
    _ = await harness.manager.runExport(
      context: ExportRunContext(
        source: .manual, visibility: .userVisible, scope: .allAlbumsFull, selection: .edited))

    let tripDir = harness.dest.rootURL.appendingPathComponent("Collections/Albums/Trip")
    let monthDir = harness.dest.rootURL.appendingPathComponent("2025/01")
    #expect(tripDir.doesDirectoryExist)
    #expect(monthDir.doesDirectoryExist)

    // The album is deleted in Photos; the timeline also loses its only asset.
    harness.photoLib.collectionTree = []
    harness.photoLib.assetsByYearMonth["2025-1"] = []
    harness.photoLib.assetsByAlbumLocalId["album-trip"] = []

    // A typed run (Export Month) cleans its own month but leaves the album
    // area alone.
    harness.manager.startExportMonth(year: 2025, month: 1)
    await harness.manager.waitForQueueDrained()
    #expect(tripDir.doesDirectoryExist, "month run must not prune album folders")
    #expect(
      harness.dest.rootURL.appendingPathComponent("2025").doesDirectoryExist,
      "the year folder is above a month run's deletion ceiling and must survive")
    #expect(harness.store.exportInfo(assetId: "tl-1") == nil)

    // Export All is the whole-library run: its reconcile covers collection
    // areas too, so the stale album goes — and its year sweep deletes up to
    // the year folder, so the emptied `2025` goes as well.
    _ = await harness.manager.runExport(
      context: ExportRunContext(
        source: .manual, visibility: .userVisible, scope: .timelineFullLibrary,
        selection: .edited))
    #expect(!tripDir.doesDirectoryExist, "full run must remove the stale album folder")
    #expect(
      !harness.dest.rootURL.appendingPathComponent("2025").doesDirectoryExist,
      "full run may delete up to the year folders")
    let stalePlacements = harness.collectionStore.recordBodies.keys.filter {
      $0.contains("album-trip")
    }
    #expect(stalePlacements.isEmpty)
  }

  /// An emptied timeline month is pruned by an Export Month run — the run's
  /// own scope — even when nothing was enqueued.
  @Test func emptiedMonthFolderPrunedByMonthRun() async throws {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }
    harness.manager.removeDeletedFiles = true

    let asset = TestAssetFactory.makeAsset(
      id: "solo", creationDate: Date(timeIntervalSince1970: 1_735_732_800),
      modificationDate: Date(timeIntervalSince1970: 1_000))
    harness.photoLib.assetsByYearMonth["2025-1"] = [asset]
    harness.photoLib.resourcesByAssetId[asset.id] = [
      TestAssetFactory.makeResource(originalFilename: "SOLO.HEIC")
    ]
    harness.manager.startExportMonth(year: 2025, month: 1)
    await harness.manager.waitForQueueDrained()
    let monthDir = harness.dest.rootURL.appendingPathComponent("2025/01")
    #expect(monthDir.doesDirectoryExist)

    // The library loses the asset; the next Export Month run deletes the
    // file ("Remove deleted files") and prunes the emptied folder.
    harness.photoLib.assetsByYearMonth["2025-1"] = []
    harness.manager.startExportMonth(year: 2025, month: 1)
    await harness.manager.waitForQueueDrained()

    #expect(!monthDir.doesDirectoryExist)
    #expect(harness.store.exportInfo(assetId: "solo") == nil)
  }

  /// The automatic folder-structure cleanup (implied by "Remove deleted
  /// files") must apply to **every** export scope, not just the timeline.
  /// Album run: after the album's assets are removed from the album in
  /// Photos, the "Remove deleted files" pass empties the album folder and the
  /// run-end empty-folder walk removes it.
  @Test func folderCleanupAppliesToAlbumRuns() async throws {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }
    harness.manager.removeDeletedFiles = true

    let album = PhotoCollectionDescriptor(
      id: "album:album-trip", localIdentifier: "album-trip", title: "Trip", kind: .album,
      pathComponents: [], children: [])
    let a = TestAssetFactory.makeAsset(
      id: "trip-a", creationDate: Date(timeIntervalSince1970: 1_735_732_800),
      modificationDate: Date(timeIntervalSince1970: 1_000))
    let b = TestAssetFactory.makeAsset(
      id: "trip-b", creationDate: Date(timeIntervalSince1970: 1_735_732_800),
      modificationDate: Date(timeIntervalSince1970: 2_000))
    harness.photoLib.collectionTree = [album]
    harness.photoLib.assetsByAlbumLocalId["album-trip"] = [a, b]
    for asset in [a, b] {
      harness.photoLib.resourcesByAssetId[asset.id] = [
        TestAssetFactory.makeResource(originalFilename: "\(asset.id.uppercased()).HEIC")
      ]
    }

    _ = await harness.manager.runExport(
      context: ExportRunContext(
        source: .manual, visibility: .userVisible, scope: .allAlbumsFull, selection: .edited))
    let tripDir = harness.dest.rootURL.appendingPathComponent("Collections/Albums/Trip")
    #expect(tripDir.doesDirectoryExist)

    // Both photos are removed from the album (album itself still exists).
    harness.photoLib.assetsByAlbumLocalId["album-trip"] = []

    _ = await harness.manager.runExport(
      context: ExportRunContext(
        source: .manual, visibility: .userVisible, scope: .allAlbumsFull, selection: .edited))

    #expect(
      !tripDir.doesDirectoryExist,
      "album-scope run must prune the emptied album folder, not just timeline months")
  }

  /// All three Cleanup options must work for **shared-album** runs too:
  /// (a) a modified asset is re-exported and replaced, (b) assets removed from
  /// the shared album lose their files and records, (c) a deleted shared
  /// album's folder, records, and placement are removed.
  @Test func cleanupOptionsWorkForSharedAlbumRuns() async throws {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }
    harness.manager.replaceUpdatedFiles = true
    harness.manager.removeDeletedFiles = true
    #expect(harness.manager.isMirrorMode)

    let shared = PhotoCollectionDescriptor(
      id: "shared:shared-1", localIdentifier: "shared-1", title: "Family", kind: .sharedAlbum,
      pathComponents: [], children: [])
    let a = TestAssetFactory.makeAsset(
      id: "s-a", creationDate: Date(timeIntervalSince1970: 1_735_732_800),
      modificationDate: Date(timeIntervalSince1970: 1_000))
    let b = TestAssetFactory.makeAsset(
      id: "s-b", creationDate: Date(timeIntervalSince1970: 1_735_732_800),
      modificationDate: Date(timeIntervalSince1970: 2_000))
    harness.photoLib.collectionTree = [shared]
    harness.photoLib.assetsBySharedAlbumLocalId["shared-1"] = [a, b]
    // Shared albums serve downscaled JPEG resources only.
    for asset in [a, b] {
      harness.photoLib.resourcesByAssetId[asset.id] = [
        TestAssetFactory.makeResource(type: .photo, originalFilename: "\(asset.id.uppercased()).JPG")
      ]
    }

    _ = await harness.manager.runExport(
      context: ExportRunContext(
        source: .manual, visibility: .userVisible, scope: .allSharedAlbumsFull,
        selection: .edited))
    let sharedDir = harness.dest.rootURL.appendingPathComponent("Collections/Shared Albums/Family")
    let resolvedPlacement = harness.collectionStore.placements.values.first {
      $0.collectionLocalIdentifier == "shared-1"
    }
    #expect(resolvedPlacement != nil)
    #expect(files(in: sharedDir) == ["S-A.JPG", "S-B.JPG"])

    // (a) "s-a" is edited in Photos after its export; (b) "s-b" is removed
    // from the shared album.
    let aModified = TestAssetFactory.makeAsset(
      id: "s-a", creationDate: Date(timeIntervalSince1970: 1_735_732_800),
      modificationDate: Date().addingTimeInterval(60))
    harness.photoLib.assetsBySharedAlbumLocalId["shared-1"] = [aModified]

    _ = await harness.manager.runExport(
      context: ExportRunContext(
        source: .manual, visibility: .userVisible, scope: .allSharedAlbumsFull,
        selection: .edited))

    // The removed asset's file is gone; the modified asset was replaced at
    // the same name (no "(1)" duplicate).
    #expect(
      files(in: sharedDir) == ["S-A.JPG"],
      "got \(files(in: sharedDir))")
    #expect(harness.writer.writeCalls.count == 3)
    #expect(
      harness.collectionStore.exportInfo(assetId: "s-b", placement: resolvedPlacement!) == nil)

    // (c) The shared album is deleted in Photos; an Export All Shared Albums
    // run removes its folder, records, and placement.
    harness.photoLib.collectionTree = []
    harness.photoLib.assetsBySharedAlbumLocalId["shared-1"] = []

    _ = await harness.manager.runExport(
      context: ExportRunContext(
        source: .manual, visibility: .userVisible, scope: .allSharedAlbumsFull,
        selection: .edited))

    #expect(!sharedDir.doesDirectoryExist)
    #expect(
      harness.collectionStore.placements.values.first {
        $0.collectionLocalIdentifier == "shared-1"
      } == nil)
  }

  /// Same guarantees for Favorites runs: (a) a modified asset is re-exported
  /// and replaced, (b) unfavorites lose their files and records, and (c) the
  /// run-end walk prunes the emptied folder.
  @Test func cleanupOptionsWorkForFavoritesRuns() async throws {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }
    harness.manager.replaceUpdatedFiles = true
    harness.manager.removeDeletedFiles = true
    #expect(harness.manager.isMirrorMode)

    let asset = TestAssetFactory.makeAsset(
      id: "fav-1", creationDate: Date(timeIntervalSince1970: 1_735_732_800),
      modificationDate: Date(timeIntervalSince1970: 1_000))
    harness.photoLib.favoritesAssets = [asset]
    harness.photoLib.resourcesByAssetId[asset.id] = [
      TestAssetFactory.makeResource(originalFilename: "FAV.HEIC")
    ]

    _ = await harness.manager.runExport(
      context: ExportRunContext(
        source: .manual, visibility: .userVisible, scope: .favoritesFull, selection: .edited))
    let favDir = harness.dest.rootURL.appendingPathComponent("Collections/Favorites")
    #expect(favDir.doesDirectoryExist)

    // (a) The asset is edited in Photos but stays a favorite.
    let modified = TestAssetFactory.makeAsset(
      id: "fav-1", creationDate: Date(timeIntervalSince1970: 1_735_732_800),
      modificationDate: Date().addingTimeInterval(60))
    harness.photoLib.favoritesAssets = [modified]

    _ = await harness.manager.runExport(
      context: ExportRunContext(
        source: .manual, visibility: .userVisible, scope: .favoritesFull, selection: .edited))

    #expect(harness.writer.writeCalls.count == 2, "modified favorite is re-exported")
    #expect(files(in: favDir) == ["FAV.HEIC"], "replaced at the same name, no duplicate")

    // (b)+(c) The asset is unfavorited: file, record, and folder go.
    harness.photoLib.favoritesAssets = []

    _ = await harness.manager.runExport(
      context: ExportRunContext(
        source: .manual, visibility: .userVisible, scope: .favoritesFull, selection: .edited))

    #expect(
      !favDir.doesDirectoryExist,
      "favorites run must prune the emptied Favorites folder")
  }

  /// The user-reported scenario: the library becomes completely empty (no
  /// images, no albums), but `Collections/Albums/<X>`, `Collections/Favorites`,
  /// and timeline folders persist. A single Export All run in mirror mode
  /// reconciles the whole destination — emptying it except the root.
  @Test func exportAllEmptiesDestinationForEmptyLibrary() async throws {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }
    harness.manager.replaceUpdatedFiles = true
    harness.manager.removeDeletedFiles = true
    #expect(harness.manager.isMirrorMode)

    // Seed everything: one timeline asset, one album with an asset, one favorite.
    let tl = TestAssetFactory.makeAsset(
      id: "tl", creationDate: Date(timeIntervalSince1970: 1_735_732_800),
      modificationDate: Date(timeIntervalSince1970: 1_000))
    harness.photoLib.assetsByYearMonth["2025-1"] = [tl]
    harness.photoLib.resourcesByAssetId["tl"] = [
      TestAssetFactory.makeResource(originalFilename: "TL.HEIC")
    ]
    harness.photoLib.yearCounts = [(year: 2025, count: 3)]

    let album = PhotoCollectionDescriptor(
      id: "album:album-familie", localIdentifier: "album-familie", title: "Familie",
      kind: .album, pathComponents: [], children: [])
    let albumAsset = TestAssetFactory.makeAsset(
      id: "fam", creationDate: Date(timeIntervalSince1970: 1_735_732_800),
      modificationDate: Date(timeIntervalSince1970: 2_000))
    harness.photoLib.collectionTree = [album]
    harness.photoLib.assetsByAlbumLocalId["album-familie"] = [albumAsset]
    harness.photoLib.resourcesByAssetId["fam"] = [
      TestAssetFactory.makeResource(originalFilename: "FAM.HEIC")
    ]

    let fav = TestAssetFactory.makeAsset(
      id: "fav", creationDate: Date(timeIntervalSince1970: 1_735_732_800),
      modificationDate: Date(timeIntervalSince1970: 3_000))
    harness.photoLib.favoritesAssets = [fav]
    harness.photoLib.resourcesByAssetId["fav"] = [
      TestAssetFactory.makeResource(originalFilename: "FAV.HEIC")
    ]

    // First pass: all three areas exported.
    _ = await harness.manager.runExport(
      context: ExportRunContext(
        source: .manual, visibility: .userVisible, scope: .timelineFullLibrary,
        selection: .edited))
    _ = await harness.manager.runExport(
      context: ExportRunContext(
        source: .manual, visibility: .userVisible, scope: .allAlbumsFull, selection: .edited))
    _ = await harness.manager.runExport(
      context: ExportRunContext(
        source: .manual, visibility: .userVisible, scope: .favoritesFull, selection: .edited))
    #expect(
      files(in: harness.dest.rootURL.appendingPathComponent("2025/01"))
        == ["TL.HEIC"])
    #expect(
      files(in: harness.dest.rootURL.appendingPathComponent("Collections/Albums/Familie"))
        == ["FAM.HEIC"])
    #expect(
      files(in: harness.dest.rootURL.appendingPathComponent("Collections/Favorites"))
        == ["FAV.HEIC"])

    // The library becomes completely empty — no images, no albums.
    harness.photoLib.assetsByYearMonth = [:]
    harness.photoLib.yearCounts = []
    harness.photoLib.collectionTree = []
    harness.photoLib.assetsByAlbumLocalId = [:]
    harness.photoLib.favoritesAssets = []

    // A single Export All reconciles the whole destination.
    _ = await harness.manager.runExport(
      context: ExportRunContext(
        source: .manual, visibility: .userVisible, scope: .timelineFullLibrary,
        selection: .edited))

    let remaining = (try? FileManager.default.contentsOfDirectory(
      atPath: harness.dest.rootURL.path)) ?? ["?"]
    #expect(
      remaining.isEmpty,
      "destination must mirror the empty library; got \(remaining)")
    #expect(harness.store.recordsById.isEmpty, "timeline records all reconciled away")
    #expect(harness.collectionStore.recordBodies.isEmpty, "collection records all reconciled away")
  }

  /// Reproduces the user flow through the actual Export Favorites **button**
  /// (`startExportFavorites`, not the awaitable API): export, edit the
  /// favorited photo in Photos, click the button again → the outdated file is
  /// replaced at the same name.
  @Test func replaceWorksThroughFavoritesButtonFlow() async throws {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }
    // Both Danger Zone options, matching the user's settings: the pre-edit
    // HEIC original's removal is the deletion half.
    harness.manager.replaceUpdatedFiles = true
    harness.manager.removeDeletedFiles = true

    let asset = TestAssetFactory.makeAsset(
      id: "fav-btn", creationDate: Date(timeIntervalSince1970: 1_735_732_800),
      modificationDate: Date(timeIntervalSince1970: 1_000))
    harness.photoLib.favoritesAssets = [asset]
    harness.photoLib.resourcesByAssetId[asset.id] = [
      TestAssetFactory.makeResource(originalFilename: "FAVBTN.HEIC")
    ]
    // The edited render the pipeline picks for the `.edited` variant after
    // the user's edit.
    let editedResource = TestAssetFactory.makeResource(
      type: .fullSizePhoto, originalFilename: "FAVBTNEdit.JPG")

    // First click.
    harness.manager.startExportFavorites()
    await harness.manager.waitForQueueDrained()
    let favDir = harness.dest.rootURL.appendingPathComponent("Collections/Favorites")
    #expect(files(in: favDir) == ["FAVBTN.HEIC"])
    let firstRecord = harness.collectionStore.placements.values.first
    #expect(firstRecord != nil)
    #expect(harness.writer.writeCalls.count == 1)

    // The user edits the favorited photo in Photos (modification date moves
    // past the export timestamp), then clicks the button again.
    let edited = TestAssetFactory.makeAsset(
      id: "fav-btn", creationDate: Date(timeIntervalSince1970: 1_735_732_800),
      hasAdjustments: true, modificationDate: Date().addingTimeInterval(60))
    harness.photoLib.favoritesAssets = [edited]
    harness.photoLib.resourcesByAssetId[asset.id] = [
      TestAssetFactory.makeResource(originalFilename: "FAVBTN.HEIC"),
      editedResource,
    ]

    harness.manager.startExportFavorites()
    await harness.manager.waitForQueueDrained()

    #expect(
      harness.writer.writeCalls.count == 2,
      "the edited favorite must be re-exported; got \(harness.writer.writeCalls.count) writes")
    // The edit renders as JPEG: the pre-edit HEIC original (not required
    // under `.edited` selection) is gone, the edit takes the natural stem.
    #expect(
      files(in: favDir) == ["FAVBTN.JPG"],
      "got \(files(in: favDir)) — the edit replaces, no duplicate")
  }

  /// User-reported: edit a photo, export it, then **revert the edit** in
  /// Photos — the outdated edited file must be replaced by the original on
  /// the next export (required set flips `.edited` → `.original`; the stale
  /// edit file is trash via "Remove deleted files").
  @Test func revertedEditReplacesEditedFileWithOriginal() async throws {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }
    harness.manager.replaceUpdatedFiles = true
    harness.manager.removeDeletedFiles = true
    #expect(harness.manager.isMirrorMode)

    let assetId = "revert-1"
    var asset = TestAssetFactory.makeAsset(
      id: assetId, creationDate: Date(timeIntervalSince1970: 1_735_732_800),
      hasAdjustments: true, modificationDate: Date(timeIntervalSince1970: 1_000))
    harness.photoLib.assetsByYearMonth["2025-1"] = [asset]
    harness.photoLib.resourcesByAssetId[assetId] = [
      TestAssetFactory.makeResource(originalFilename: "IMG_0001.HEIC"),
      TestAssetFactory.makeResource(type: .fullSizePhoto, originalFilename: "EditRender.JPG"),
    ]

    harness.manager.startExportMonth(year: 2025, month: 1)
    await harness.manager.waitForQueueDrained()
    let monthDir = harness.dest.rootURL.appendingPathComponent("2025/01")
    #expect(files(in: monthDir) == ["IMG_0001.JPG"])

    // The user reverts the edit: adjustments gone, modification date bumps.
    asset = TestAssetFactory.makeAsset(
      id: assetId, creationDate: Date(timeIntervalSince1970: 1_735_732_800),
      modificationDate: Date().addingTimeInterval(60))
    harness.photoLib.assetsByYearMonth["2025-1"] = [asset]

    harness.manager.startExportMonth(year: 2025, month: 1)
    await harness.manager.waitForQueueDrained()

    // The outdated edited file is trashed; the original takes the stem.
    #expect(
      files(in: monthDir) == ["IMG_0001.HEIC"],
      "got \(files(in: monthDir)) — the reverted asset must end up as the original")
    #expect(
      harness.fileSystem.trashCalls.contains { $0.lastPathComponent == "IMG_0001.JPG" })
    let record = harness.store.exportInfo(assetId: assetId)
    #expect(record?.variants[.edited] == nil)
    #expect(record?.variants[.original]?.status == .done)
  }

  /// User-reported: moving an album from one parent folder to another left
  /// the old placement in place and doubled the export. The stale-path check
  /// (placement id vs the resolver's candidate id for the album's CURRENT
  /// path) removes the old folder; the album re-exports at the new location.
  @Test func movedAlbumOldFolderRemovedAndNotDoubled() async throws {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }
    harness.manager.removeDeletedFiles = true

    let albumAsset = TestAssetFactory.makeAsset(
      id: "fam", creationDate: Date(timeIntervalSince1970: 1_735_732_800),
      modificationDate: Date(timeIntervalSince1970: 1_000))
    harness.photoLib.resourcesByAssetId["fam"] = [
      TestAssetFactory.makeResource(originalFilename: "FAM.HEIC")
    ]

    // Folder "Trips" containing album "Familie".
    func folder(_ id: String, _ title: String, children: [PhotoCollectionDescriptor])
      -> PhotoCollectionDescriptor
    {
      PhotoCollectionDescriptor(
        id: "folder:\(id)", localIdentifier: id, title: title, kind: .folder,
        pathComponents: [], children: children)
    }
    harness.photoLib.collectionTree = [
      folder("trips", "Trips", children: [
        PhotoCollectionDescriptor(
          id: "album:album-familie", localIdentifier: "album-familie", title: "Familie",
          kind: .album, pathComponents: ["Trips"], children: [])
      ])
    ]
    harness.photoLib.assetsByAlbumLocalId["album-familie"] = [albumAsset]

    _ = await harness.manager.runExport(
      context: ExportRunContext(
        source: .manual, visibility: .userVisible, scope: .allAlbumsFull, selection: .edited))
    let oldDir = harness.dest.rootURL.appendingPathComponent("Collections/Albums/Trips/Familie")
    #expect(files(in: oldDir) == ["FAM.HEIC"])

    // The album is moved to folder "Urlaub" (same collection id, new path).
    harness.photoLib.collectionTree = [
      folder("urlaub", "Urlaub", children: [
        PhotoCollectionDescriptor(
          id: "album:album-familie", localIdentifier: "album-familie", title: "Familie",
          kind: .album, pathComponents: ["Urlaub"], children: [])
      ])
    ]

    _ = await harness.manager.runExport(
      context: ExportRunContext(
        source: .manual, visibility: .userVisible, scope: .allAlbumsFull, selection: .edited))

    // The old folder is gone; the album exports once, at the new location.
    #expect(
      !oldDir.doesDirectoryExist,
      "the moved album's old placement folder must be removed")
    #expect(
      files(in: harness.dest.rootURL.appendingPathComponent("Collections/Albums/Urlaub/Familie"))
        == ["FAM.HEIC"])
    let placements = harness.collectionStore.placements.values.filter {
      $0.collectionLocalIdentifier == "album-familie"
    }
    #expect(placements.count == 1, "old placement removed, new one created — no doubling")
    #expect(placements.first?.relativePath.contains("Urlaub") == true)
  }

  /// User-reported: a photo's date changes so it moves from year 2025 to
  /// year 2026, leaving 2025 empty — the old `2025` folder must not survive.
  /// Export All's orphan-month sweep (recorded months under years the
  /// library no longer reports) deletes the stale file and the emptied year
  /// tree.
  @Test func dateChangedToNewYearRemovesOldYearFolder() async throws {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }
    harness.manager.replaceUpdatedFiles = true
    harness.manager.removeDeletedFiles = true

    let asset = TestAssetFactory.makeAsset(
      id: "dated", creationDate: Date(timeIntervalSince1970: 1_735_732_800),  // 2025-01
      modificationDate: Date(timeIntervalSince1970: 1_000))
    harness.photoLib.assetsByYearMonth["2025-1"] = [asset]
    harness.photoLib.resourcesByAssetId[asset.id] = [
      TestAssetFactory.makeResource(originalFilename: "DATED.HEIC")
    ]
    harness.photoLib.yearCounts = [(year: 2025, count: 1)]

    harness.manager.startExportAll()
    await harness.manager.waitForQueueDrained()
    let oldDir = harness.dest.rootURL.appendingPathComponent("2025/01")
    #expect(files(in: oldDir) == ["DATED.HEIC"])

    // The date changes to 2026; 2025 has no photos anymore.
    let moved = TestAssetFactory.makeAsset(
      id: "dated", creationDate: Date(timeIntervalSince1970: 1_767_226_800),  // 2026-01
      modificationDate: Date().addingTimeInterval(60))
    harness.photoLib.assetsByYearMonth = ["2026-1": [moved]]
    harness.photoLib.yearCounts = [(year: 2026, count: 1)]

    harness.manager.startExportAll()
    await harness.manager.waitForQueueDrained()

    #expect(
      !harness.dest.rootURL.appendingPathComponent("2025").doesDirectoryExist,
      "the emptied old year tree must be removed by Export All")
    #expect(
      files(in: harness.dest.rootURL.appendingPathComponent("2026/01")) == ["DATED.HEIC"])
    #expect(harness.store.exportInfo(assetId: "dated") != nil)
    let record = harness.store.exportInfo(assetId: "dated")
    #expect(record?.year == 2026 && record?.month == 1)
  }

  /// Cleanup alone doesn't invent work: an unchanged library re-exported in
  /// mirror mode enqueues nothing.
  @Test func mirrorModeUnchangedLibraryEnqueuesNothing() async throws {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }
    harness.manager.replaceUpdatedFiles = true
    harness.manager.removeDeletedFiles = true

    let asset = TestAssetFactory.makeAsset(
      id: "stable", creationDate: Date(timeIntervalSince1970: 1_735_732_800),
      modificationDate: Date(timeIntervalSince1970: 1_000))
    harness.photoLib.assetsByYearMonth["2025-1"] = [asset]
    harness.photoLib.resourcesByAssetId[asset.id] = [
      TestAssetFactory.makeResource(originalFilename: "IMG_0001.HEIC")
    ]
    harness.photoLib.yearCounts = [(year: 2025, count: 1)]

    _ = await harness.manager.runExport(
      context: ExportRunContext(
        source: .manual, visibility: .userVisible, scope: .timelineFullLibrary,
        selection: .edited))
    let firstCount = harness.writer.writeCalls.count
    #expect(firstCount == 1)

    _ = await harness.manager.runExport(
      context: ExportRunContext(
        source: .manual, visibility: .userVisible, scope: .timelineFullLibrary,
        selection: .edited))

    #expect(harness.writer.writeCalls.count == firstCount, "unchanged library: no re-export")
    #expect(
      files(in: harness.dest.rootURL.appendingPathComponent("2025/01")) == ["IMG_0001.HEIC"])
  }
}
