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

  /// The configured history identity owns queued physical IO even if selection changes.
  func destinationId(for placement: ExportPlacement) -> String? {
    switch placement.kind {
    case .timeline: return timelineStore.destinationId
    case .favorites, .album, .sharedAlbum: return collectionStore.destinationId
    }
  }

  // MARK: - Reads

  /// Proof retained by a previously interrupted original-side write, before a retry
  /// overwrites its metadata. Compare persisted paths explicitly: placement equality is ID-only.
  func interruptedFilename(
    forAssetId assetId: String, placement: ExportPlacement, variant: ExportVariant,
    relPath: String, subfolder: String?
  ) -> String? {
    let variants: [ExportVariant: ExportVariantRecord]
    switch placement.kind {
    case .timeline:
      guard let record = timelineStore.exportInfo(assetId: assetId),
        let month = placement.timelineYearMonth,
        record.year == month.year, record.month == month.month, record.relPath == relPath
      else { return nil }
      variants = record.variants
    case .favorites, .album, .sharedAlbum:
      guard let stored = collectionStore.placement(id: placement.id),
        stored.kind == placement.kind, stored.relativePath == placement.relativePath
      else { return nil }
      variants = collectionStore.exportInfo(assetId: assetId, placement: stored)?.variants ?? [:]
    }
    guard let record = variants[variant], record.status == .failed,
      record.reason == .interrupted, record.subfolder == subfolder,
      let filename = record.filename, !filename.isEmpty,
      filename != ".", filename != "..", (filename as NSString).lastPathComponent == filename
    else { return nil }
    return filename
  }

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

  /// Whether a record other than this asset's own `variant` names `filename` in the folder
  /// the variant is written to. Every status counts, as do the asset's other variants. A
  /// timeline placement without a year and month has no folder, so every name is claimed;
  /// exports refuse such a placement before asking.
  func isFilenameClaimed(
    _ filename: String, placement: ExportPlacement, subfolder: String?,
    exceptVariant variant: ExportVariant, of assetId: String
  ) -> Bool {
    switch placement.kind {
    case .timeline:
      guard let (year, month) = placement.timelineYearMonth else { return true }
      return timelineStore.isFilenameClaimed(
        filename, year: year, month: month, subfolder: subfolder,
        exceptVariant: variant, of: assetId)
    case .favorites, .album, .sharedAlbum:
      return collectionStore.isFilenameClaimed(
        filename, placement: placement, subfolder: subfolder,
        exceptVariant: variant, of: assetId)
    }
  }

  /// Whether another asset's record names `filename` in that folder. None of `assetId`'s
  /// own variants in the placement count, so a group stem chosen for all of them can reuse
  /// names their failed or interrupted records hold.
  func isFilenameClaimed(
    _ filename: String, placement: ExportPlacement, subfolder: String?,
    exceptAsset assetId: String
  ) -> Bool {
    switch placement.kind {
    case .timeline:
      guard let (year, month) = placement.timelineYearMonth else { return true }
      return timelineStore.isFilenameClaimed(
        filename, year: year, month: month, subfolder: subfolder, exceptAsset: assetId)
    case .favorites, .album, .sharedAlbum:
      return collectionStore.isFilenameClaimed(
        filename, placement: placement, subfolder: subfolder, exceptAsset: assetId)
    }
  }

  /// Waits for preceding mutations in the affected store to become durable.
  func flush(placement: ExportPlacement) async throws {
    switch placement.kind {
    case .timeline:
      try await timelineStore.flush()
    case .favorites, .album, .sharedAlbum:
      try await collectionStore.flush()
    }
  }

  /// Retry history is sparse, so inspect only recorded retry tuples after a run.
  /// A failed store cannot acknowledge success using provisional in-memory records.
  func isRetryVariantDone(scope: AutoSyncRetryScopeKey, assetId: String, variant: ExportVariant)
    -> Bool
  {
    switch scope {
    case .timeline:
      return timelineStore.hasDurableRecords
        && timelineStore.exportInfo(assetId: assetId)?.variants[variant]?.status == .done
    case .favorites:
      return collectionVariantIsDone(
        placementId: ExportPlacement.favorites().id, assetId: assetId, variant: variant)
    case .album(let placementId), .sharedAlbum(let placementId):
      return collectionVariantIsDone(placementId: placementId, assetId: assetId, variant: variant)
    }
  }

  private func collectionVariantIsDone(placementId: String, assetId: String, variant: ExportVariant)
    -> Bool
  {
    collectionStore.hasDurableRecords
      && collectionStore.recordBodies[placementId]?[assetId]?.variants[variant.rawValue]?.status
        == .done
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

  /// Retains the destination that owns an imminent final file commit. The returned
  /// acknowledgement takes the committed filename, or `nil` when nothing was committed.
  func captureFinalCommit(
    assetId: String, placement: ExportPlacement, variant: ExportVariant,
    relPath: String, subfolder: String?, acceptsEditedFallback: Bool
  ) throws -> (_ finalFilename: String?) async -> Void {
    switch placement.kind {
    case .timeline:
      let (year, month) = placement.timelineYearMonth ?? (0, 0)
      return try timelineStore.captureFinalCommit(
        assetId: assetId, variant: variant, year: year, month: month, relPath: relPath,
        subfolder: subfolder, acceptsEditedFallback: acceptsEditedFallback)
    case .favorites, .album, .sharedAlbum:
      return try collectionStore.captureFinalCommit(
        assetId: assetId, variant: variant, placement: placement,
        subfolder: subfolder, acceptsEditedFallback: acceptsEditedFallback)
    }
  }

  func markVariantFailed(
    assetId: String, placement: ExportPlacement, variant: ExportVariant,
    error: String, reason: ExportVariantReason? = nil, at date: Date
  ) {
    switch placement.kind {
    case .timeline:
      timelineStore.markVariantFailed(
        assetId: assetId, variant: variant, error: error, reason: reason, at: date)
    case .favorites, .album, .sharedAlbum:
      collectionStore.markVariantFailed(
        assetId: assetId, placement: placement, variant: variant,
        error: error, reason: reason, at: date)
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
  ///
  /// `subfolder` carries the subfolder (relative to the placement) that the
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
  /// Any prior `.done` write is acceptable as a source — there's no preference for timeline
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
