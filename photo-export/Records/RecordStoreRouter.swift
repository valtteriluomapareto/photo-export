import Foundation
import os

/// The single place that switches on `ExportPlacement.Kind` to dispatch record-store
/// operations between `ExportRecordStore` (timeline) and `CollectionExportRecordStore`
/// (favorites, albums, shared albums). Replaces eight inline `switch placement.kind`
/// blocks that previously lived in `ExportManager`.
///
/// The router owns every kind of dispatch — reads, writes, cancellation cleanup, and
/// reuse-source lookup — so a new placement kind only requires touching the cases here,
/// not eight disparate sites in `ExportManager`. The router is **not** pure: it carries
/// injected references to both stores and is `@MainActor` to match the stores' isolation.
/// Contracts and extension recipe live in `docs/reference/architecture-conventions.md`
/// §Adding a new export placement kind.
@MainActor
final class RecordStoreRouter {

  private let logger = Logger(
    subsystem: "com.valtteriluoma.photo-export", category: "RecordStoreRouter")
  private let timelineStore: ExportRecordStore
  private let collectionStore: CollectionExportRecordStore

  init(
    timelineStore: ExportRecordStore,
    collectionStore: CollectionExportRecordStore
  ) {
    self.timelineStore = timelineStore
    self.collectionStore = collectionStore
  }

  // MARK: - Reads

  /// Variants currently recorded for `assetId` at `placement`, regardless of status.
  /// Empty dictionary if no record exists in the relevant store.
  func variants(
    forAssetId assetId: String, placement: ExportPlacement
  ) -> [ExportVariant: ExportVariantRecord] {
    switch placement.kind {
    case .timeline:
      return timelineStore.exportInfo(assetId: assetId)?.variants ?? [:]
    case .favorites, .album, .sharedAlbum:
      return collectionStore.exportInfo(assetId: assetId, placement: placement)?
        .variants ?? [:]
    }
  }

  /// Every recorded `(assetId, variants)` pair under `placement`, regardless of
  /// variant status. Drives the cleanup passes ("Remove deleted files" and
  /// the stale-album half of the folder-structure cleanup it implies), which
  /// diff this list against the library and delete the difference.
  ///
  /// Timeline scope: the store is asset-keyed, so the pass filters
  /// `recordsById` on the record's persisted `(year, month)` matching the
  /// placement — O(records) per call. Collection scope: a direct
  /// `recordBodies[placementId]` lookup. Cleanup calls this once per scope
  /// per run, so the linear timeline pass is bounded by one sweep per
  /// exported year/month rather than per asset.
  func recordedVariantsByAsset(
    placement: ExportPlacement
  ) -> [String: [ExportVariant: ExportVariantRecord]] {
    switch placement.kind {
    case .timeline:
      guard let (year, month) = placement.timelineYearMonth else { return [:] }
      var result: [String: [ExportVariant: ExportVariantRecord]] = [:]
      for (assetId, record) in timelineStore.recordsById
      where record.year == year && record.month == month {
        result[assetId] = record.variants
      }
      return result
    case .favorites, .album, .sharedAlbum:
      guard let bodies = collectionStore.recordBodies[placement.id] else { return [:] }
      var result: [String: [ExportVariant: ExportVariantRecord]] = [:]
      for (assetId, body) in bodies {
        result[assetId] = body.typedVariants
      }
      return result
    }
  }

  /// One record per asset with a matching `year` field, carrying its persisted
  /// month. Year-scope cleanup ("Remove deleted files" for an Export Year run)
  /// uses this single O(records) pass instead of twelve per-month placements:
  /// the per-asset month lets the caller bucket-match against the fetched
  /// month buckets, so an asset whose record month drifted from its current
  /// creation month is still recognized as stale.
  struct TimelineRecordedAsset {
    let assetId: String
    let year: Int
    let month: Int
    let variants: [ExportVariant: ExportVariantRecord]
  }

  func timelineRecordedAssets(year: Int) -> [TimelineRecordedAsset] {
    timelineStore.recordsById.compactMap { assetId, record in
      guard record.year == year else { return nil }
      return TimelineRecordedAsset(
        assetId: assetId, year: record.year, month: record.month, variants: record.variants)
    }
  }

  /// Distinct `(year, month)` pairs that have at least one timeline record,
  /// sorted for deterministic iteration. The full-library reconcile ("Export
  /// All") uses this to find orphaned months — records under years the
  /// library no longer reports — whose files the per-year loop never visits.
  func timelineRecordedYearMonths() -> [(year: Int, month: Int)] {
    var seen = Set<String>()
    var pairs: [(year: Int, month: Int)] = []
    for record in timelineStore.recordsById.values {
      let key = "\(record.year)-\(record.month)"
      if seen.insert(key).inserted {
        pairs.append((year: record.year, month: record.month))
      }
    }
    return pairs.sorted { lhs, rhs in
      lhs.year != rhs.year ? lhs.year < rhs.year : lhs.month < rhs.month
    }
  }

  /// All collection placement metadata currently known to the store, kind included.
  /// "Remove empty albums" diffs this list against the fetched collection tree.
  func collectionPlacements() -> [ExportPlacement] {
    Array(collectionStore.placements.values)
  }

  /// Count of recorded assets under a collection placement (any variant status).
  /// Used by stale-placement cleanup to report how many records a
  /// `deletePlacement` removes.
  func collectionRecordCount(placementId: String) -> Int {
    collectionStore.recordBodies[placementId]?.count ?? 0
  }

  /// The on-disk directory (relative to the destination root, trailing slash)
  /// recorded for the asset's variants at `placement`. Timeline records carry
  /// their own relPath — the year/month folder where the file was actually
  /// written, which can differ from the current placement after a date change
  /// moved the asset to another year. Collection records live at the
  /// placement's path. `nil` when no record exists.
  func recordedDirectory(
    assetId: String, placement: ExportPlacement
  ) -> String? {
    switch placement.kind {
    case .timeline:
      return timelineStore.exportInfo(assetId: assetId)?.relPath
    case .favorites, .album, .sharedAlbum:
      return placement.relativePath
    }
  }

  // MARK: - Writes

  func markVariantInProgress(
    assetId: String, placement: ExportPlacement, variant: ExportVariant,
    relPath: String, filename: String?, subfolder: String? = nil
  ) {
    switch placement.kind {
    case .timeline:
      let (year, month) = placement.timelineYearMonth ?? (0, 0)
      timelineStore.markVariantInProgress(
        assetId: assetId, variant: variant,
        year: year, month: month, relPath: relPath, filename: filename,
        subfolder: subfolder)
    case .favorites, .album, .sharedAlbum:
      collectionStore.markVariantInProgress(
        assetId: assetId, placement: placement, variant: variant, filename: filename,
        subfolder: subfolder)
    }
  }

  func markVariantExported(
    assetId: String, placement: ExportPlacement, variant: ExportVariant,
    relPath: String, filename: String, exportedAt: Date, subfolder: String? = nil
  ) {
    switch placement.kind {
    case .timeline:
      let (year, month) = placement.timelineYearMonth ?? (0, 0)
      timelineStore.markVariantExported(
        assetId: assetId, variant: variant,
        year: year, month: month, relPath: relPath,
        filename: filename, exportedAt: exportedAt, subfolder: subfolder)
    case .favorites, .album, .sharedAlbum:
      collectionStore.markVariantExported(
        assetId: assetId, placement: placement, variant: variant,
        filename: filename, exportedAt: exportedAt, subfolder: subfolder)
    }
  }

  func markVariantFailed(
    assetId: String, placement: ExportPlacement, variant: ExportVariant,
    error: String, at date: Date
  ) {
    switch placement.kind {
    case .timeline:
      timelineStore.markVariantFailed(
        assetId: assetId, variant: variant, error: error, at: date)
    case .favorites, .album, .sharedAlbum:
      collectionStore.markVariantFailed(
        assetId: assetId, placement: placement, variant: variant,
        error: error, at: date)
    }
  }

  // MARK: - Removal

  /// Deletes an asset's entire record at `placement` (all variants, any status).
  /// Used by the cleanup passes for assets that no longer exist in the library —
  /// their remaining variants can never be retried, so keeping the record would
  /// only preserve dead state.
  func removeRecord(assetId: String, placement: ExportPlacement) {
    switch placement.kind {
    case .timeline:
      timelineStore.remove(assetId: assetId)
    case .favorites, .album, .sharedAlbum:
      collectionStore.remove(assetId: assetId, placement: placement)
    }
  }

  /// Removes a single variant's record entry without touching the rest of the
  /// asset's record. Used by "Replace updated files" when a variant falls out of
  /// the current selection's required set (e.g. an asset gained an edit, so its
  /// `.original`-only record is no longer what `.edited` selection wants on disk).
  func removeVariantRecord(
    assetId: String, placement: ExportPlacement, variant: ExportVariant
  ) {
    switch placement.kind {
    case .timeline:
      timelineStore.removeVariant(assetId: assetId, variant: variant)
    case .favorites, .album, .sharedAlbum:
      collectionStore.removeVariant(
        assetId: assetId, placement: placement, variant: variant)
    }
  }

  /// Deletes a collection placement's metadata together with every record under
  /// it. Used by the stale-album half of the automatic folder-structure
  /// cleanup for placements whose source album no longer exists in the
  /// library. No-op (with an error log) when handed a
  /// `.timeline` placement — the collection store rejects those kinds, and the
  /// timeline store has no placement metadata to delete.
  func removePlacement(id: String, kind: ExportPlacement.Kind) {
    guard kind != .timeline else {
      logger.error(
        "RecordStoreRouter.removePlacement called for a .timeline placement \(id, privacy: .public); routing bug — drop and ignore."
      )
      return
    }
    collectionStore.deletePlacement(id: id)
  }

  // MARK: - Cancellation cleanup

  /// Removes the `(assetId, variant)` record at `placement` if and only if its status is
  /// `.inProgress`. No-op when no record exists or the variant is in any other state.
  /// Used by both the `cancelAndClear` teardown path and the variant loop's
  /// `CancellationError` catch block; both previously open-coded the placement-kind
  /// switch.
  func removeInProgressVariant(
    assetId: String, placement: ExportPlacement, variant: ExportVariant
  ) {
    let current = variants(forAssetId: assetId, placement: placement)
    guard current[variant]?.status == .inProgress else { return }
    switch placement.kind {
    case .timeline:
      timelineStore.removeVariant(assetId: assetId, variant: variant)
    case .favorites, .album, .sharedAlbum:
      collectionStore.removeVariant(
        assetId: assetId, placement: placement, variant: variant)
    }
  }

  // MARK: - Reuse-source lookup

  /// A `(asset, variant)` pair already exported under another placement. The reuse-source
  /// copy path uses this to copy the existing file rather than re-fetching the asset from
  /// PhotoKit. On APFS, `FileManager.copyItem` performs copy-on-write so the duplicate
  /// uses no extra bytes; on non-APFS it's a real copy.
  ///
  /// `subfolder` (issue #38) carries the subfolder (relative to the placement) that the
  /// *source* variant was written into — `nil` for records written under the historical
  /// flat layout, `"videos"` for standalone-video variants written with the subfolder
  /// layout. Read per-variant from the source record so a mid-life toggle flip can't
  /// mis-locate a file: the source file lives where the writer originally put it,
  /// regardless of the current `videoLayout` setting.
  struct ReuseSource: Equatable {
    let placement: ExportPlacement
    let filename: String
    let subfolder: String?
  }

  /// Finds any existing `.done` record for `(assetId, variant)` across both stores,
  /// excluding the placement we're currently writing to. Order: timeline first, then
  /// collection placements sorted by id (for deterministic test behavior). Returns nil if
  /// nothing reusable exists.
  ///
  /// Per `docs/project/archive/collections-export-plan.md` §"Reuse-Source Copy Path", any
  /// prior `.done` write is acceptable as a source — there's no preference for timeline
  /// over collection beyond the deterministic search order.
  ///
  /// The returned `ReuseSource.subfolder` is read off the matched variant record (NOT
  /// asset-wide), so a mid-life-toggle asset with `.original` at bare path and `.edited`
  /// in `videos/` returns the per-variant truth.
  func findReuseSource(
    assetId: String, variant: ExportVariant, currentPlacement: ExportPlacement
  ) -> ReuseSource? {
    // 1) Timeline store (skip if we're currently writing to a timeline placement).
    if currentPlacement.kind != .timeline {
      if let record = timelineStore.exportInfo(assetId: assetId),
        let variantRec = record.variants[variant],
        variantRec.status == .done,
        let filename = variantRec.filename
      {
        let placement = ExportPlacement.timeline(year: record.year, month: record.month)
        return ReuseSource(
          placement: placement, filename: filename, subfolder: variantRec.subfolder)
      }
    }
    // 2) Collection placements, sorted for deterministic behavior.
    let sortedIds = collectionStore.recordBodies.keys.sorted()
    for placementId in sortedIds {
      if placementId == currentPlacement.id { continue }
      guard let placement = collectionStore.placement(id: placementId) else { continue }
      guard
        let body = collectionStore.recordBodies[placementId],
        let assetBody = body[assetId],
        let variantRec = assetBody.variants[variant.rawValue],
        variantRec.status == .done,
        let filename = variantRec.filename
      else { continue }
      return ReuseSource(
        placement: placement, filename: filename, subfolder: variantRec.subfolder)
    }
    return nil
  }
}
