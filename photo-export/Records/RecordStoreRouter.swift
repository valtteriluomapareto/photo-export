import Foundation

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

  // MARK: - Writes

  func markVariantInProgress(
    assetId: String, placement: ExportPlacement, variant: ExportVariant,
    relPath: String, filename: String?
  ) {
    switch placement.kind {
    case .timeline:
      let (year, month) = placement.timelineYearMonth ?? (0, 0)
      timelineStore.markVariantInProgress(
        assetId: assetId, variant: variant,
        year: year, month: month, relPath: relPath, filename: filename)
    case .favorites, .album, .sharedAlbum:
      collectionStore.markVariantInProgress(
        assetId: assetId, placement: placement, variant: variant, filename: filename)
    }
  }

  func markVariantExported(
    assetId: String, placement: ExportPlacement, variant: ExportVariant,
    relPath: String, filename: String, exportedAt: Date
  ) {
    switch placement.kind {
    case .timeline:
      let (year, month) = placement.timelineYearMonth ?? (0, 0)
      timelineStore.markVariantExported(
        assetId: assetId, variant: variant,
        year: year, month: month, relPath: relPath,
        filename: filename, exportedAt: exportedAt)
    case .favorites, .album, .sharedAlbum:
      collectionStore.markVariantExported(
        assetId: assetId, placement: placement, variant: variant,
        filename: filename, exportedAt: exportedAt)
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
  struct ReuseSource: Equatable {
    let placement: ExportPlacement
    let filename: String
  }

  /// Finds any existing `.done` record for `(assetId, variant)` across both stores,
  /// excluding the placement we're currently writing to. Order: timeline first, then
  /// collection placements sorted by id (for deterministic test behavior). Returns nil if
  /// nothing reusable exists.
  ///
  /// Per `docs/project/plans/collections-export-plan.md` §"Reuse-Source Copy Path", any
  /// prior `.done` write is acceptable as a source — there's no preference for timeline
  /// over collection beyond the deterministic search order.
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
        return ReuseSource(placement: placement, filename: filename)
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
      return ReuseSource(placement: placement, filename: filename)
    }
    return nil
  }
}
