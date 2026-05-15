import Foundation
import Photos
import Testing

@testable import Photo_Export

@MainActor
struct CollectionExportRecordStoreTests {

  // MARK: - Fixtures

  private func makeStore() throws -> (URL, CollectionExportRecordStore) {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("CollectionStore-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = CollectionExportRecordStore(baseDirectoryURL: dir)
    return (dir, store)
  }

  private func favoritesPlacement() -> ExportPlacement {
    ExportPlacement.favorites(createdAt: Date(timeIntervalSince1970: 1_700_000_000))
  }

  private func albumPlacement(
    id: String = "abc-123",
    placementId: String = "collections:album:hash16:hash8"
  ) -> ExportPlacement {
    ExportPlacement(
      kind: .album,
      id: placementId,
      displayName: "Family/Trip 2024",
      collectionLocalIdentifier: id,
      relativePath: "Collections/Albums/Family/Trip 2024/",
      createdAt: Date(timeIntervalSince1970: 1_700_000_001)
    )
  }

  private func sharedAlbumPlacement(
    id: String = "shared-1",
    placementId: String = "collections:shared-album:h16:h8"
  ) -> ExportPlacement {
    ExportPlacement(
      kind: .sharedAlbum,
      id: placementId,
      displayName: "Family",
      collectionLocalIdentifier: id,
      relativePath: "Collections/Shared Albums/Family/",
      createdAt: Date(timeIntervalSince1970: 1_700_000_003)
    )
  }

  private func sampleAsset(id: String = "asset-1") -> AssetDescriptor {
    AssetDescriptor(
      id: id,
      creationDate: Date(timeIntervalSince1970: 1_700_000_002),
      mediaType: .image,
      pixelWidth: 100,
      pixelHeight: 100,
      duration: 0,
      hasAdjustments: false
    )
  }

  // MARK: - Empty / first-launch behavior

  /// Plan §"Phase 1 exit criteria": "Collection store loads empty on first launch and writes
  /// its first snapshot only when something is upserted."
  @Test func emptyOnFirstLaunch() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    store.configure(for: "dest-empty")
    #expect(store.placements.isEmpty)
    #expect(store.recordBodies.isEmpty)

    // No snapshot file written yet.
    let snapshotPath = dir.appendingPathComponent("dest-empty/collection-records.json").path
    #expect(!FileManager.default.fileExists(atPath: snapshotPath))
  }

  @Test func nilDestinationClearsState() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    store.configure(for: "dest-x")
    store.upsertPlacement(favoritesPlacement())
    #expect(!store.placements.isEmpty)

    store.configure(for: nil)
    #expect(store.placements.isEmpty)
    #expect(store.recordBodies.isEmpty)
  }

  // MARK: - Routing invariant: rejects .timeline

  /// The collection store rejects `.timeline` placements at every entry point — three
  /// layers of defense uphold the disjoint-key-space invariant:
  /// 1. `accept(_:)` on every mutation API,
  /// 2. snapshot-decode filter in `configure(for:)`,
  /// 3. log-replay filter in `apply(.upsertPlacement)`.
  /// Each test below exercises one of those paths and verifies the store remained empty
  /// (or unchanged), proving the routing-bug protection.

  private func timelinePlacement() -> ExportPlacement {
    ExportPlacement.timeline(
      year: 2025, month: 6, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
  }

  @Test func upsertPlacementRejectsTimeline() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    store.configure(for: "dest-reject-1")
    let timeline = timelinePlacement()
    store.upsertPlacement(timeline)
    #expect(store.placements.isEmpty)
    #expect(store.placement(id: timeline.id) == nil)
  }

  @Test func upsertScopedRecordRejectsTimeline() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    store.configure(for: "dest-reject-2")
    let timeline = timelinePlacement()
    let record = ScopedExportRecord(
      placement: timeline, assetId: "a",
      variants: [
        .original: ExportVariantRecord(
          filename: "x.heic", status: .done, exportDate: Date(), lastError: nil)
      ]
    )
    store.upsert(record)
    #expect(store.recordBodies.isEmpty)
  }

  @Test func markVariantInProgressRejectsTimeline() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    store.configure(for: "dest-reject-3")
    store.markVariantInProgress(
      assetId: "a", placement: timelinePlacement(), variant: .original, filename: nil)
    #expect(store.recordBodies.isEmpty)
  }

  @Test func markVariantExportedRejectsTimeline() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    store.configure(for: "dest-reject-4")
    store.markVariantExported(
      assetId: "a", placement: timelinePlacement(), variant: .original,
      filename: "x.heic", exportedAt: Date())
    #expect(store.recordBodies.isEmpty)
  }

  @Test func markVariantFailedRejectsTimeline() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    store.configure(for: "dest-reject-5")
    store.markVariantFailed(
      assetId: "a", placement: timelinePlacement(), variant: .original,
      error: "test", at: Date())
    #expect(store.recordBodies.isEmpty)
  }

  @Test func removeVariantRejectsTimeline() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    store.configure(for: "dest-reject-6")
    // Pre-populate via favorites placement so we can prove the .timeline call doesn't
    // mutate state.
    let favorites = favoritesPlacement()
    store.upsertPlacement(favorites)
    store.markVariantExported(
      assetId: "a", placement: favorites, variant: .original,
      filename: "x.heic", exportedAt: Date())
    let beforeBodies = store.recordBodies
    store.removeVariant(assetId: "a", placement: timelinePlacement(), variant: .original)
    #expect(store.recordBodies == beforeBodies)
  }

  @Test func removeAssetRejectsTimeline() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    store.configure(for: "dest-reject-7")
    let favorites = favoritesPlacement()
    store.upsertPlacement(favorites)
    store.markVariantExported(
      assetId: "a", placement: favorites, variant: .original,
      filename: "x.heic", exportedAt: Date())
    let beforeBodies = store.recordBodies
    store.remove(assetId: "a", placement: timelinePlacement())
    #expect(store.recordBodies == beforeBodies)
  }

  @Test func deletePlacementForUnknownIdIsAllowed() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    store.configure(for: "dest-reject-9")
    // No-op delete for an unknown id is harmless and emits a delete log line; verify the
    // call doesn't crash and state stays empty.
    store.deletePlacement(id: "collections:album:unknown")
    #expect(store.placements.isEmpty)
    #expect(store.recordBodies.isEmpty)
  }

  @Test func placementsMatchingTimelineReturnsEmpty() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    store.configure(for: "dest-reject-10")
    store.upsertPlacement(favoritesPlacement())
    #expect(store.placements(matching: .timeline).isEmpty)
  }

  @Test func readApisRejectTimeline() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    store.configure(for: "dest-reject-11")
    let timeline = timelinePlacement()
    let asset = sampleAsset()

    #expect(store.exportInfo(assetId: asset.id, placement: timeline) == nil)
    #expect(!store.isExported(asset: asset, placement: timeline, selection: .edited))
    let summary = store.summary(for: timeline)
    #expect(summary.exportedCount == 0)
    #expect(summary.totalCount == 0)
    let monthSummary = store.monthSummary(
      assets: [asset], placement: timeline, selection: .edited)
    #expect(monthSummary.exportedCount == 0)
    #expect(monthSummary.status == .notExported)
  }

  /// Snapshot-decode defense: hand-craft a snapshot file containing a `.timeline`
  /// placement and verify it's dropped on load.
  @Test func snapshotDecodeFiltersTimelinePlacements() throws {
    let (dir, _) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let destDir = dir.appendingPathComponent("dest-corrupt", isDirectory: true)
    try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

    // Build a tampered snapshot that mixes a .favorites placement (legitimate) with a
    // .timeline placement (illegal). The .timeline entry's records should be dropped
    // along with its placement metadata.
    let timeline = timelinePlacement()
    let favorites = favoritesPlacement()
    let body = CollectionExportRecordStore.RecordBody(
      variants: [
        ExportVariant.original.rawValue: ExportVariantRecord(
          filename: "x.heic", status: .done, exportDate: Date(timeIntervalSince1970: 1),
          lastError: nil)
      ]
    )
    let tampered = CollectionExportRecordStore.Snapshot(
      version: CollectionExportRecordStore.Constants.snapshotVersion,
      placements: [timeline.id: timeline, favorites.id: favorites],
      records: [
        timeline.id: ["a": body],
        favorites.id: ["b": body],
      ]
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(tampered)
    let snapshotURL = destDir.appendingPathComponent(
      CollectionExportRecordStore.Constants.snapshotFileName)
    try data.write(to: snapshotURL)

    // Configure a fresh store against the tampered file and assert the .timeline
    // placement and its records are dropped while .favorites survives.
    let store = CollectionExportRecordStore(baseDirectoryURL: dir)
    store.configure(for: "dest-corrupt")
    #expect(store.state == .ready, "snapshot is structurally valid; load should succeed")
    #expect(store.placement(id: timeline.id) == nil)
    #expect(store.placement(id: favorites.id) == favorites)
    #expect(store.recordBodies[timeline.id] == nil)
    #expect(store.recordBodies[favorites.id]?["b"] == body)
  }

  /// Log-replay defense: write an `upsertPlacement` log line for a `.timeline` placement
  /// and verify it's dropped on replay.
  @Test func logReplayFiltersTimelinePlacements() throws {
    let (dir, _) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let destDir = dir.appendingPathComponent("dest-log-corrupt", isDirectory: true)
    try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

    let timeline = timelinePlacement()
    let logLine = CollectionExportRecordStore.LogOp.upsertPlacement(
      placementId: timeline.id, placement: timeline)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(logLine) + Data("\n".utf8)
    let logURL = destDir.appendingPathComponent(
      CollectionExportRecordStore.Constants.logFileName)
    try data.write(to: logURL)

    let store = CollectionExportRecordStore(baseDirectoryURL: dir)
    store.configure(for: "dest-log-corrupt")
    #expect(store.state == .ready)
    #expect(store.placements.isEmpty, ".timeline placement must be dropped on log replay")
  }

  // MARK: - Placement metadata

  @Test func upsertPlacementPersists() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    store.configure(for: "dest-1")
    let p = favoritesPlacement()
    store.upsertPlacement(p)
    #expect(store.placement(id: p.id) == p)
    #expect(store.placements(matching: .favorites) == [p])
    #expect(store.placements(matching: .album).isEmpty)
  }

  @Test func deletePlacementRemovesPlacementAndRecords() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    store.configure(for: "dest-2")
    let album = albumPlacement()
    store.upsertPlacement(album)
    store.markVariantExported(
      assetId: "a", placement: album, variant: .original,
      filename: "IMG_0001.HEIC", exportedAt: Date())
    #expect(store.placement(id: album.id) != nil)
    #expect(store.recordBodies[album.id]?.count == 1)

    store.deletePlacement(id: album.id)
    #expect(store.placement(id: album.id) == nil)
    #expect(store.recordBodies[album.id] == nil)
  }

  // MARK: - Variant lifecycle

  @Test func variantLifecycleInProgressDoneFailedRemove() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    store.configure(for: "dest-3")
    let p = albumPlacement()
    store.upsertPlacement(p)

    // .inProgress → .done → .failed → remove
    store.markVariantInProgress(
      assetId: "a", placement: p, variant: .original, filename: nil)
    var info = store.exportInfo(assetId: "a", placement: p)
    #expect(info?.variants[.original]?.status == .inProgress)

    store.markVariantExported(
      assetId: "a", placement: p, variant: .original,
      filename: "IMG_0001.HEIC", exportedAt: Date(timeIntervalSince1970: 1))
    info = store.exportInfo(assetId: "a", placement: p)
    #expect(info?.variants[.original]?.status == .done)
    #expect(info?.variants[.original]?.filename == "IMG_0001.HEIC")

    store.markVariantFailed(
      assetId: "a", placement: p, variant: .edited, error: "Edited resource unavailable",
      at: Date(timeIntervalSince1970: 2))
    info = store.exportInfo(assetId: "a", placement: p)
    #expect(info?.variants[.original]?.status == .done)
    #expect(info?.variants[.edited]?.status == .failed)

    store.removeVariant(assetId: "a", placement: p, variant: .edited)
    info = store.exportInfo(assetId: "a", placement: p)
    #expect(info?.variants[.edited] == nil)
    #expect(info?.variants[.original]?.status == .done)
  }

  /// `removeVariant` removes the whole record once the last variant is gone.
  @Test func removeVariantRemovesRecordWhenLastVariantGone() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    store.configure(for: "dest-4")
    let p = albumPlacement()
    store.upsertPlacement(p)
    store.markVariantInProgress(
      assetId: "a", placement: p, variant: .original, filename: nil)
    store.removeVariant(assetId: "a", placement: p, variant: .original)
    #expect(store.exportInfo(assetId: "a", placement: p) == nil)
  }

  // MARK: - isExported under selection

  @Test func isExportedUnderSelectionEdited() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    store.configure(for: "dest-isexp")
    let p = albumPlacement()
    store.upsertPlacement(p)
    let asset = sampleAsset()  // hasAdjustments: false → requires .original

    #expect(!store.isExported(asset: asset, placement: p, selection: .edited))
    store.markVariantExported(
      assetId: asset.id, placement: p, variant: .original,
      filename: "IMG_0001.HEIC", exportedAt: Date())
    #expect(store.isExported(asset: asset, placement: p, selection: .edited))
  }

  // MARK: - Persistence: load after restart

  @Test func persistenceSurvivesRestart() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    store.configure(for: "dest-restart")
    let p = albumPlacement()
    store.upsertPlacement(p)
    store.markVariantExported(
      assetId: "asset-1", placement: p, variant: .original,
      filename: "IMG_0001.HEIC", exportedAt: Date(timeIntervalSince1970: 12345))
    store.flushForTesting()

    // New store instance against the same baseDirectoryURL replays the log.
    let store2 = CollectionExportRecordStore(baseDirectoryURL: dir)
    store2.configure(for: "dest-restart")
    #expect(store2.placement(id: p.id)?.id == p.id)
    let info = store2.exportInfo(assetId: "asset-1", placement: p)
    #expect(info?.variants[.original]?.status == .done)
    #expect(info?.variants[.original]?.filename == "IMG_0001.HEIC")
  }

  // MARK: - Summary

  @Test func summaryPartialAndComplete() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    store.configure(for: "dest-sum")
    let p = albumPlacement()
    store.upsertPlacement(p)
    store.markVariantExported(
      assetId: "a", placement: p, variant: .original, filename: "A.HEIC",
      exportedAt: Date())
    store.markVariantInProgress(
      assetId: "b", placement: p, variant: .original, filename: nil)

    let partial = store.summary(for: p)
    #expect(partial.totalCount == 2)
    #expect(partial.exportedCount == 1)
    #expect(partial.status == .partial)

    store.markVariantExported(
      assetId: "b", placement: p, variant: .original, filename: "B.HEIC",
      exportedAt: Date())
    let complete = store.summary(for: p)
    #expect(complete.totalCount == 2)
    #expect(complete.exportedCount == 2)
    #expect(complete.status == .complete)
  }

  // MARK: - In-flight recovery on load

  /// Plan §"In-flight recovery on load": collection store mirrors the timeline pass — any
  /// `.inProgress` becomes `.failed` with the recoverable-error message. In-memory only;
  /// no eager persistence.
  @Test func inFlightRecoveryConvertsInProgressToFailed() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    store.configure(for: "dest-recover")
    let p = albumPlacement()
    store.upsertPlacement(p)
    store.markVariantInProgress(
      assetId: "asset-1", placement: p, variant: .original, filename: nil)
    store.flushForTesting()

    // Fresh store reloads from log — recovery pass converts the `.inProgress` to `.failed`.
    let store2 = CollectionExportRecordStore(baseDirectoryURL: dir)
    store2.configure(for: "dest-recover")
    let info = store2.exportInfo(assetId: "asset-1", placement: p)
    #expect(info?.variants[.original]?.status == .failed)
    #expect(info?.variants[.original]?.lastError == ExportVariantRecovery.interruptedMessage)
  }

  // MARK: - Cross-placement isolation

  /// Records under different placements are independent: writes to one placement don't
  /// touch the other, even for the same asset id.
  @Test func recordsUnderDifferentPlacementsAreIndependent() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    store.configure(for: "dest-iso")
    let fav = favoritesPlacement()
    let alb = albumPlacement()
    store.upsertPlacement(fav)
    store.upsertPlacement(alb)
    let assetId = "shared-asset"
    store.markVariantExported(
      assetId: assetId, placement: fav, variant: .original,
      filename: "fav-name.HEIC", exportedAt: Date())
    store.markVariantFailed(
      assetId: assetId, placement: alb, variant: .original,
      error: "boom", at: Date())

    let favInfo = store.exportInfo(assetId: assetId, placement: fav)
    let albInfo = store.exportInfo(assetId: assetId, placement: alb)
    #expect(favInfo?.variants[.original]?.status == .done)
    #expect(favInfo?.variants[.original]?.filename == "fav-name.HEIC")
    #expect(albInfo?.variants[.original]?.status == .failed)
    #expect(albInfo?.variants[.original]?.lastError == "boom")
  }

  // MARK: - Corruption recovery

  /// Plan §"Recovery on Corruption": a corrupt snapshot transitions the store to `.failed`
  /// and leaves the corrupt file in place on disk so Quit-and-relaunch reproduces `.failed`.
  /// Only `resetToEmpty()` renames the file out of the way.
  @Test func corruptSnapshotEntersFailedStateWithFilePreserved() throws {
    let (dir, _) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    // Write a corrupt snapshot under dest-corrupt before the store ever sees it.
    let destDir = dir.appendingPathComponent("dest-corrupt")
    try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
    let snapshotURL = destDir.appendingPathComponent(
      CollectionExportRecordStore.Constants.snapshotFileName)
    try Data("not valid json".utf8).write(to: snapshotURL)

    let store = CollectionExportRecordStore(baseDirectoryURL: dir)
    store.configure(for: "dest-corrupt")
    #expect(store.state == .failed)
    #expect(store.placements.isEmpty)
    #expect(store.recordBodies.isEmpty)
    #expect(FileManager.default.fileExists(atPath: snapshotURL.path))

    // resetToEmpty renames the corrupt file out of the way and writes a fresh empty
    // snapshot at the canonical path. Both files exist after the call.
    store.resetToEmpty()
    #expect(store.state == .ready)
    let contents = try FileManager.default.contentsOfDirectory(atPath: destDir.path)
    let brokenFiles = contents.filter { $0.contains(".broken-") }
    #expect(brokenFiles.count == 1)
    let newSnapshot = try Data(contentsOf: snapshotURL)
    let decoded = try JSONDecoder().decode(CollectionExportRecordStore.Snapshot.self, from: newSnapshot)
    #expect(decoded.placements.isEmpty)
    #expect(decoded.records.isEmpty)
  }

  /// `resetToEmpty()` on a `.ready` store is a no-op (defensive — a generic alert handler
  /// can call it without first checking state).
  @Test func resetToEmptyOnReadyStoreIsNoop() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    store.configure(for: "dest-noop")
    #expect(store.state == .ready)
    let p = albumPlacement()
    store.upsertPlacement(p)
    #expect(store.placement(id: p.id) != nil)

    store.resetToEmpty()
    // State unchanged; in-memory state preserved.
    #expect(store.state == .ready)
    #expect(store.placement(id: p.id) != nil)
  }

  /// Quit-and-relaunch path: a `.failed` store re-loads the same corrupt file on the next
  /// configure and stays `.failed`. There is no silent reset.
  @Test func relaunchOnCorruptSnapshotStaysFailed() throws {
    let (dir, _) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let destDir = dir.appendingPathComponent("dest-relaunch")
    try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
    let snapshotURL = destDir.appendingPathComponent(
      CollectionExportRecordStore.Constants.snapshotFileName)
    try Data("garbage".utf8).write(to: snapshotURL)

    let store1 = CollectionExportRecordStore(baseDirectoryURL: dir)
    store1.configure(for: "dest-relaunch")
    #expect(store1.state == .failed)

    // "Relaunch" by constructing a fresh store against the same dir.
    let store2 = CollectionExportRecordStore(baseDirectoryURL: dir)
    store2.configure(for: "dest-relaunch")
    #expect(store2.state == .failed)
    #expect(FileManager.default.fileExists(atPath: snapshotURL.path))
  }

  // MARK: - Orphan record skip on replay

  /// Plan §"Collection Store Format → Loader applies log entries in order": an upsertRecord
  /// referencing an unknown placementId is logged and skipped (defends against truncated
  /// logs). Without this, a partial write that loses the `upsertPlacement` line but
  /// preserves a later `upsertRecord` line would replay an orphan record under a placement
  /// id with no metadata — and the next compaction would freeze the orphan into the
  /// snapshot.
  @Test func replaySkipsRecordsForUnknownPlacements() throws {
    let (dir, _) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let destDir = dir.appendingPathComponent("dest-orphan")
    try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
    let logURL = destDir.appendingPathComponent(
      CollectionExportRecordStore.Constants.logFileName)

    // Hand-craft a log with an upsertRecord whose placement was never written (simulating
    // a truncated log).
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let orphanOp = CollectionExportRecordStore.LogOp.upsertRecord(
      placementId: "collections:album:missing",
      assetId: "asset-1",
      body: CollectionExportRecordStore.RecordBody(
        variants: [
          ExportVariant.original.rawValue: ExportVariantRecord(
            filename: "IMG.HEIC", status: .done, exportDate: Date(), lastError: nil)
        ])
    )
    var logBytes = try encoder.encode(orphanOp)
    logBytes.append(0x0A)
    try logBytes.write(to: logURL)

    let store = CollectionExportRecordStore(baseDirectoryURL: dir)
    store.configure(for: "dest-orphan")

    // The orphan record was skipped — no placement, no record.
    #expect(store.placement(id: "collections:album:missing") == nil)
    #expect(store.recordBodies["collections:album:missing"] == nil)
  }

  // MARK: - ExportPlacement Codable round-trip

  @Test func exportPlacementCodableRoundTrip() throws {
    let original = albumPlacement(id: "abc-rt")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(original)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(ExportPlacement.self, from: data)
    #expect(decoded == original)  // manual Hashable/Equatable is over `id` only
    #expect(decoded.kind == original.kind)
    #expect(decoded.displayName == original.displayName)
    #expect(decoded.collectionLocalIdentifier == original.collectionLocalIdentifier)
    #expect(decoded.relativePath == original.relativePath)
    #expect(decoded.createdAt == original.createdAt)
  }

  // MARK: - Shared-album placement routing

  /// Shared-album placements pass `accept(_:)` and survive snapshot persistence.
  /// Pins the gate against a regression that re-narrowed it to user-album +
  /// favorites (which `.timeline` was originally the sole exclusion against).
  @Test func sharedAlbumPlacementSurvivesAcceptAndPersistence() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    store.configure(for: "dest-shared")
    let placement = sharedAlbumPlacement()
    store.upsertPlacement(placement)
    store.flushForTesting()

    #expect(store.placement(id: placement.id)?.kind == .sharedAlbum)
    #expect(store.placements(matching: .sharedAlbum).count == 1)
  }

  /// `recordCount(in:)` discriminates user albums from shared albums even when
  /// the underlying `collectionLocalIdentifier` is identical. The matching is
  /// `(kind, collectionLocalIdentifier)` — `.album(id:)` must not pick up a
  /// `.sharedAlbum` placement and vice versa. Same id across both kinds is
  /// unlikely in production (PhotoKit hands out distinct identifiers per
  /// collection class), but the invariant is what guards us against a future
  /// kind-collapse refactor.
  @Test func recordCountDiscriminatesUserAndSharedByKindNotJustId() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    store.configure(for: "dest-count")

    let sharedId = "shared-1"
    let userAlbum = albumPlacement(
      id: sharedId, placementId: "collections:album:h16:h8")
    let sharedAlbum = sharedAlbumPlacement(id: sharedId)
    store.upsertPlacement(userAlbum)
    store.upsertPlacement(sharedAlbum)
    store.markVariantExported(
      assetId: "asset-album", placement: userAlbum, variant: .original,
      filename: "asset-album.jpg",
      exportedAt: Date(timeIntervalSince1970: 1_700_000_010))
    store.markVariantExported(
      assetId: "asset-shared", placement: sharedAlbum, variant: .original,
      filename: "asset-shared.jpg",
      exportedAt: Date(timeIntervalSince1970: 1_700_000_011))
    store.flushForTesting()

    #expect(store.recordCount(in: .album(collectionLocalId: sharedId)) == 1)
    #expect(store.recordCount(in: .sharedAlbum(collectionLocalId: sharedId)) == 1)
    #expect(store.recordCount(in: .any) == 2)
  }
}
