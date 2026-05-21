import Foundation

/// Pure decision logic for "which assets need export at which placement?". Filters a
/// list of assets through two skip predicates (already-exported, AutoSync retry gate)
/// and returns the corresponding `ExportManager.ExportJob` list.
///
/// Per `docs/project/archive/software-architecture-improvement-plan.md` Phase 4a, the
/// planner is a pure `enum` (no state, no IO). Callers fetch assets from PhotoKit and
/// query record-store state via injected closures; the planner only decides whether to
/// emit a job. `ExportManager.enqueueMonth` / `.enqueueYear` / `.enqueueCollection`
/// remain the orchestrators that call PhotoKit, mutate pending-jobs state, and update
/// queue counters — but the per-asset decision lives here.
///
/// `ExportQueueCoordinator` (Phase 4b) will take ownership of the orchestration that
/// surrounds these calls; the planner is the seam they share.
enum ExportJobPlanner {

  /// Filters `assets` to those needing export at `placement` under `selection` and
  /// returns the corresponding `ExportJob`s. An asset is dropped when either:
  ///
  /// - `isExported(asset)` returns `true` (the record store already has every required
  ///   variant `.done`, or the asset is covered by the issue #22 edited-fallback case).
  /// - `shouldSkipForRetry(asset, placement, selection)` returns `true` (AutoSync retry
  ///   backoff for every required variant of this asset at this placement).
  ///
  /// Same predicate order as the pre-Phase-4a `enqueueMonth` / `enqueueCollection`
  /// bodies: already-exported check first, then retry gate. Order is observable —
  /// `shouldSkipForRetry` bumps `skippedCount` as a side effect, so checking
  /// `isExported` first avoids inflating skip counters for assets that were never going
  /// to be queued anyway.
  static func plan(
    assets: [AssetDescriptor],
    placement: ExportPlacement,
    selection: ExportVersionSelection,
    livePhotosPaired: Bool = false,
    videoLayout: ExportVideoLayout = .flat,
    isExported: (AssetDescriptor) -> Bool,
    shouldSkipForRetry: (AssetDescriptor, ExportPlacement, ExportVersionSelection) -> Bool
  ) -> [ExportManager.ExportJob] {
    assets.compactMap { asset in
      if isExported(asset) { return nil }
      if shouldSkipForRetry(asset, placement, selection) { return nil }
      return ExportManager.ExportJob(
        assetLocalIdentifier: asset.id, placement: placement, selection: selection,
        livePhotosPaired: livePhotosPaired, videoLayout: videoLayout)
    }
  }

  /// Same as `plan`, but the placement varies per asset based on the asset's
  /// `creationDate` month within `year`. Used by `enqueueYear` (a year-wide timeline
  /// export spans up to 12 placements). Assets with no `creationDate` are dropped
  /// silently — they have nowhere to land. Same predicate order as `plan`.
  static func planTimelineYear(
    assets: [AssetDescriptor],
    year: Int,
    selection: ExportVersionSelection,
    livePhotosPaired: Bool = false,
    videoLayout: ExportVideoLayout = .flat,
    isExported: (AssetDescriptor) -> Bool,
    shouldSkipForRetry: (AssetDescriptor, ExportPlacement, ExportVersionSelection) -> Bool,
    calendar: Calendar = .current
  ) -> [ExportManager.ExportJob] {
    assets.compactMap { asset in
      guard let created = asset.creationDate else { return nil }
      let month = calendar.component(.month, from: created)
      let placement = ExportPlacement.timeline(year: year, month: month)
      // NOTE: `isExported` here uses the same predicate the caller would have used inline
      // — it does NOT take a placement, because the timeline store keys records by asset
      // alone (the year/month are persisted on the record, not the lookup key).
      if isExported(asset) { return nil }
      if shouldSkipForRetry(asset, placement, selection) { return nil }
      return ExportManager.ExportJob(
        assetLocalIdentifier: asset.id, placement: placement, selection: selection,
        livePhotosPaired: livePhotosPaired, videoLayout: videoLayout)
    }
  }
}
