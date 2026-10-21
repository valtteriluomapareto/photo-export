import Foundation

/// Pure decision logic for which assets need export at a placement. Callers fetch assets
/// and inject completion/retry predicates; this type returns jobs without owning stores,
/// PhotoKit access, queue mutation, or counters. `ExportManager` orchestrates preparation
/// and `ExportQueueCoordinator` admits and executes the jobs.
/// See docs/reference/architecture-conventions.md#canonical-start-entry-point-shape.
enum ExportJobPlanner {

  /// Filters `assets` to those needing export at `placement` under `selection` and
  /// returns the corresponding `ExportJob`s. An asset is dropped when either:
  ///
  /// - `isExported(asset)` returns `true` (the record store already has every required
  ///   variant `.done`, or the asset is covered by the edited-fallback case).
  /// - `shouldSkipForRetry(asset, placement, settings.selection)` returns `true` (AutoSync retry
  ///   backoff for every required variant of this asset at this placement).
  ///
  /// Check already-exported first, then the retry gate. Order is observable —
  /// `shouldSkipForRetry` bumps `skippedCount` as a side effect, so checking
  /// `isExported` first avoids inflating skip counters for assets that were never going
  /// to be queued anyway.
  static func plan(
    assets: [AssetDescriptor],
    placement: ExportPlacement,
    settings: ExportSettingsSnapshot,
    isExported: (AssetDescriptor) -> Bool,
    shouldSkipForRetry: (AssetDescriptor, ExportPlacement, ExportVersionSelection) -> Bool
  ) -> [ExportManager.ExportJob] {
    assets.compactMap { asset in
      if isExported(asset) { return nil }
      if shouldSkipForRetry(asset, placement, settings.selection) { return nil }
      return ExportManager.ExportJob(
        assetLocalIdentifier: asset.id, placement: placement, settings: settings)
    }
  }

  /// Same as `plan`, but the placement varies per asset based on the asset's
  /// `creationDate` month within `year`. Used by `enqueueYear` (a year-wide timeline
  /// export spans up to 12 placements). Assets with no `creationDate` are dropped
  /// silently — they have nowhere to land. Same predicate order as `plan`.
  static func planTimelineYear(
    assets: [AssetDescriptor],
    year: Int,
    settings: ExportSettingsSnapshot,
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
      if shouldSkipForRetry(asset, placement, settings.selection) { return nil }
      return ExportManager.ExportJob(
        assetLocalIdentifier: asset.id, placement: placement, settings: settings)
    }
  }
}
