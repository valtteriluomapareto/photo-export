import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Phase 1 unit tests for `RecordStoreRouter`. The router is the only place that
/// switches on `ExportPlacement.Kind` for record-store dispatch — these tests pin the
/// dispatch table so a future placement kind cannot be quietly added without updating
/// the router (and a corresponding test below).
///
/// Uses real `ExportRecordStore` and `CollectionExportRecordStore` instances against
/// temp-dir roots. The router's logic is dispatch only; observed-effect testing through
/// real stores is cheaper than mocking and closer to integration behavior.
@MainActor
struct RecordStoreRouterTests {

  // MARK: - Harness

  @MainActor
  private struct Harness {
    let router: RecordStoreRouter
    let timeline: ExportRecordStore
    let collection: CollectionExportRecordStore
    let root: URL

    func cleanup() {
      timeline.flushForTesting()
      collection.flushForTesting()
      try? FileManager.default.removeItem(at: root)
    }
  }

  private func makeHarness() -> Harness {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("RecordStoreRouter-\(UUID().uuidString)", isDirectory: true)
    let timeline = ExportRecordStore(baseDirectoryURL: root)
    timeline.configure(for: "test")
    let collection = CollectionExportRecordStore(baseDirectoryURL: root)
    collection.configure(for: "test")
    let router = RecordStoreRouter(timelineStore: timeline, collectionStore: collection)
    return Harness(router: router, timeline: timeline, collection: collection, root: root)
  }

  // MARK: - Placement fixtures

  private func favorites() -> ExportPlacement { .favorites() }
  private func album(_ id: String) -> ExportPlacement {
    ExportPlacement(
      kind: .album,
      id: "collections:album:\(id)",
      displayName: "Album \(id)",
      collectionLocalIdentifier: id,
      relativePath: "Collections/Albums/Album-\(id)/",
      createdAt: Date(timeIntervalSince1970: 1_700_000_000))
  }
  private func sharedAlbum(_ id: String) -> ExportPlacement {
    ExportPlacement(
      kind: .sharedAlbum,
      id: "collections:shared-album:\(id)",
      displayName: "Shared \(id)",
      collectionLocalIdentifier: id,
      relativePath: "Collections/Shared Albums/Shared-\(id)/",
      createdAt: Date(timeIntervalSince1970: 1_700_000_001))
  }
  private func timeline(year: Int = 2025, month: Int = 7) -> ExportPlacement {
    .timeline(year: year, month: month)
  }

  // MARK: - Reads

  @Test func variants_timelinePlacement_readsFromTimelineStore() {
    let h = makeHarness()
    defer { h.cleanup() }

    h.timeline.markVariantExported(
      assetId: "a1", variant: .original,
      year: 2025, month: 7, relPath: "2025/07/",
      filename: "IMG_0001.HEIC", exportedAt: Date())

    let variants = h.router.variants(forAssetId: "a1", placement: timeline())
    #expect(variants[.original]?.status == .done)
    #expect(variants[.original]?.filename == "IMG_0001.HEIC")
  }

  @Test func variants_collectionPlacement_readsFromCollectionStore() {
    let h = makeHarness()
    defer { h.cleanup() }

    let placement = favorites()
    h.collection.upsertPlacement(placement)
    h.collection.markVariantExported(
      assetId: "a1", placement: placement, variant: .original,
      filename: "IMG_0001.HEIC", exportedAt: Date())

    let variants = h.router.variants(forAssetId: "a1", placement: placement)
    #expect(variants[.original]?.status == .done)
  }

  @Test func variants_missingRecord_returnsEmptyDict() {
    let h = makeHarness()
    defer { h.cleanup() }
    #expect(h.router.variants(forAssetId: "missing", placement: timeline()).isEmpty)
    #expect(h.router.variants(forAssetId: "missing", placement: favorites()).isEmpty)
  }

  // Timeline year/month plumb-through: a non-2025/7 placement must persist its year and
  // month onto the stored record, not the `(0,0)` fallback the router uses when
  // `timelineYearMonth` returns nil.
  @Test func markVariantExported_timelinePreservesYearMonthFromPlacement() {
    let h = makeHarness()
    defer { h.cleanup() }
    let placement = timeline(year: 2019, month: 12)
    h.router.markVariantExported(
      assetId: "a", placement: placement, variant: .original,
      relPath: "2019/12/", filename: "X.HEIC", exportedAt: Date())

    let record = h.timeline.exportInfo(assetId: "a")
    #expect(record?.year == 2019)
    #expect(record?.month == 12)
    #expect(record?.relPath == "2019/12/")
  }

  // MARK: - Writes — dispatch coverage

  @Test func markVariantInProgress_dispatchesByPlacementKind() {
    let h = makeHarness()
    defer { h.cleanup() }

    // Timeline → timeline store.
    h.router.markVariantInProgress(
      assetId: "tl", placement: timeline(), variant: .original,
      relPath: "2025/07/", filename: "IMG_TL.HEIC")
    #expect(h.timeline.exportInfo(assetId: "tl")?.variants[.original]?.status == .inProgress)

    // Favorites → collection store, not timeline.
    let fav = favorites()
    h.collection.upsertPlacement(fav)
    h.router.markVariantInProgress(
      assetId: "fav", placement: fav, variant: .original,
      relPath: fav.relativePath, filename: "FAV.HEIC")
    #expect(h.collection.exportInfo(assetId: "fav", placement: fav)?.variants[.original]?.status
      == .inProgress)
    #expect(h.timeline.exportInfo(assetId: "fav") == nil)
  }

  @Test func markVariantExported_dispatchesByPlacementKind() {
    let h = makeHarness()
    defer { h.cleanup() }

    let alb = album("vacation")
    h.collection.upsertPlacement(alb)
    let now = Date()
    h.router.markVariantExported(
      assetId: "a1", placement: alb, variant: .edited,
      relPath: alb.relativePath, filename: "v.HEIC", exportedAt: now)

    let body = h.collection.exportInfo(assetId: "a1", placement: alb)
    #expect(body?.variants[.edited]?.status == .done)
    #expect(body?.variants[.edited]?.filename == "v.HEIC")
    #expect(h.timeline.exportInfo(assetId: "a1") == nil)
  }

  @Test func markVariantFailed_dispatchesByPlacementKind() {
    let h = makeHarness()
    defer { h.cleanup() }

    let shared = sharedAlbum("vac-shared")
    h.collection.upsertPlacement(shared)
    h.router.markVariantFailed(
      assetId: "a1", placement: shared, variant: .original,
      error: "disk full", at: Date())

    let body = h.collection.exportInfo(assetId: "a1", placement: shared)
    #expect(body?.variants[.original]?.status == .failed)
    #expect(body?.variants[.original]?.lastError == "disk full")
    #expect(h.timeline.exportInfo(assetId: "a1") == nil)
  }

  // MARK: - Cancellation cleanup

  @Test func removeInProgressVariant_removesOnlyInProgressVariants() {
    let h = makeHarness()
    defer { h.cleanup() }

    // Timeline path: in-progress → removed.
    h.router.markVariantInProgress(
      assetId: "tl", placement: timeline(), variant: .original,
      relPath: "2025/07/", filename: nil)
    h.router.removeInProgressVariant(
      assetId: "tl", placement: timeline(), variant: .original)
    #expect(h.timeline.exportInfo(assetId: "tl")?.variants[.original] == nil)

    // Timeline path: .done is NOT removed (only .inProgress is).
    h.router.markVariantExported(
      assetId: "done", placement: timeline(), variant: .original,
      relPath: "2025/07/", filename: "D.HEIC", exportedAt: Date())
    h.router.removeInProgressVariant(
      assetId: "done", placement: timeline(), variant: .original)
    #expect(h.timeline.exportInfo(assetId: "done")?.variants[.original]?.status == .done)
  }

  @Test func removeInProgressVariant_collectionStore_sameContract() {
    let h = makeHarness()
    defer { h.cleanup() }
    let alb = album("a")
    h.collection.upsertPlacement(alb)

    h.router.markVariantInProgress(
      assetId: "in", placement: alb, variant: .original,
      relPath: alb.relativePath, filename: nil)
    h.router.removeInProgressVariant(
      assetId: "in", placement: alb, variant: .original)
    #expect(h.collection.exportInfo(assetId: "in", placement: alb) == nil)

    h.router.markVariantExported(
      assetId: "kept", placement: alb, variant: .original,
      relPath: alb.relativePath, filename: "K.HEIC", exportedAt: Date())
    h.router.removeInProgressVariant(
      assetId: "kept", placement: alb, variant: .original)
    #expect(h.collection.exportInfo(assetId: "kept", placement: alb)?
      .variants[.original]?.status == .done)
  }

  @Test func removeInProgressVariant_missingRecord_isNoOp() {
    let h = makeHarness()
    defer { h.cleanup() }
    h.router.removeInProgressVariant(
      assetId: "ghost", placement: timeline(), variant: .original)
    // Just expect no crash; no record to assert on.
  }

  /// `.failed` variants must be preserved across cancellation cleanup. Only `.inProgress`
  /// gets removed — `.done` and `.failed` survive (existing failures carry retry context
  /// AutoSync needs and the variant-recovery UI renders).
  @Test func removeInProgressVariant_preservesFailedVariants() {
    let h = makeHarness()
    defer { h.cleanup() }

    // Timeline path
    h.router.markVariantFailed(
      assetId: "tlf", placement: timeline(), variant: .original,
      error: "disk full", at: Date())
    h.router.removeInProgressVariant(
      assetId: "tlf", placement: timeline(), variant: .original)
    #expect(h.timeline.exportInfo(assetId: "tlf")?.variants[.original]?.status == .failed)

    // Collection path
    let alb = album("alb")
    h.collection.upsertPlacement(alb)
    h.router.markVariantFailed(
      assetId: "cf", placement: alb, variant: .original,
      error: "asset missing", at: Date())
    h.router.removeInProgressVariant(
      assetId: "cf", placement: alb, variant: .original)
    #expect(h.collection.exportInfo(assetId: "cf", placement: alb)?
      .variants[.original]?.status == .failed)
  }

  // MARK: - Reuse-source lookup

  @Test func findReuseSource_findsTimelineDoneFromCollectionPlacement() {
    let h = makeHarness()
    defer { h.cleanup() }
    let now = Date()
    h.timeline.markVariantExported(
      assetId: "shared", variant: .original,
      year: 2025, month: 7, relPath: "2025/07/",
      filename: "X.HEIC", exportedAt: now)

    let alb = album("ALB")
    h.collection.upsertPlacement(alb)
    let reuse = h.router.findReuseSource(
      assetId: "shared", variant: .original, currentPlacement: alb)
    #expect(reuse?.filename == "X.HEIC")
    if case .timeline = reuse?.placement.kind {} else {
      Issue.record("Expected timeline placement; got \(String(describing: reuse?.placement))")
    }
  }

  @Test func findReuseSource_skipsTimelineWhenCurrentIsTimeline() {
    let h = makeHarness()
    defer { h.cleanup() }
    h.timeline.markVariantExported(
      assetId: "x", variant: .original,
      year: 2025, month: 7, relPath: "2025/07/",
      filename: "X.HEIC", exportedAt: Date())
    let reuse = h.router.findReuseSource(
      assetId: "x", variant: .original, currentPlacement: timeline())
    #expect(reuse == nil, "timeline placement must not reuse from itself")
  }

  @Test func findReuseSource_findsCollectionDoneFromTimelinePlacement() {
    let h = makeHarness()
    defer { h.cleanup() }
    let alb = album("from-album")
    h.collection.upsertPlacement(alb)
    h.collection.markVariantExported(
      assetId: "z", placement: alb, variant: .original,
      filename: "Z.HEIC", exportedAt: Date())
    let reuse = h.router.findReuseSource(
      assetId: "z", variant: .original, currentPlacement: timeline())
    #expect(reuse?.filename == "Z.HEIC")
    #expect(reuse?.placement.kind == .album)
  }

  @Test func findReuseSource_excludesCurrentCollectionPlacement() {
    let h = makeHarness()
    defer { h.cleanup() }
    let alb = album("self")
    h.collection.upsertPlacement(alb)
    h.collection.markVariantExported(
      assetId: "z", placement: alb, variant: .original,
      filename: "Z.HEIC", exportedAt: Date())
    let reuse = h.router.findReuseSource(
      assetId: "z", variant: .original, currentPlacement: alb)
    #expect(reuse == nil, "current placement must be excluded from reuse search")
  }

  @Test func findReuseSource_returnsNilWhenNoDoneRecord() {
    let h = makeHarness()
    defer { h.cleanup() }
    #expect(h.router.findReuseSource(
      assetId: "nothing", variant: .original, currentPlacement: timeline()) == nil)
  }

  @Test func findReuseSource_prefersTimelineOverCollection() {
    // Plan: "Order: timeline first, then collection placements sorted by id."
    let h = makeHarness()
    defer { h.cleanup() }
    h.timeline.markVariantExported(
      assetId: "z", variant: .original,
      year: 2025, month: 7, relPath: "2025/07/",
      filename: "TL.HEIC", exportedAt: Date())
    let alb = album("alb")
    h.collection.upsertPlacement(alb)
    h.collection.markVariantExported(
      assetId: "z", placement: alb, variant: .original,
      filename: "COLL.HEIC", exportedAt: Date())

    // Current placement is shared album → not a timeline, so timeline IS searched first.
    let shared = sharedAlbum("share")
    h.collection.upsertPlacement(shared)
    let reuse = h.router.findReuseSource(
      assetId: "z", variant: .original, currentPlacement: shared)
    #expect(reuse?.filename == "TL.HEIC", "timeline must be preferred over collection")
  }
}
