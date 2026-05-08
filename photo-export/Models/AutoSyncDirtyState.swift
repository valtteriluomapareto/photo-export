import Foundation

/// Per-scope dirty-set bookkeeping for one destination.
///
/// `pendingAssetIds` accumulates asset identifiers that need targeted re-evaluation; the
/// targeting cost cap (enforced by `recordPendingAssetId(_:costCap:)`) collapses the set
/// into `pendingFullReconciliation = true` when adding the next id would exceed the cap.
/// `pendingPlacementReconciliation` is the album-only "membership/folder/rename change"
/// flag that triggers a bounded all-albums reconciliation when targeting per-album work
/// is not feasible.
struct ScopeDirtyState: Codable, Equatable, Sendable {
  var pendingAssetIds: Set<String>
  var pendingFullReconciliation: Bool
  var pendingPlacementReconciliation: Bool

  init(
    pendingAssetIds: Set<String> = [],
    pendingFullReconciliation: Bool = false,
    pendingPlacementReconciliation: Bool = false
  ) {
    self.pendingAssetIds = pendingAssetIds
    self.pendingFullReconciliation = pendingFullReconciliation
    self.pendingPlacementReconciliation = pendingPlacementReconciliation
  }

  static let empty = ScopeDirtyState()

  var isEmpty: Bool {
    pendingAssetIds.isEmpty && !pendingFullReconciliation && !pendingPlacementReconciliation
  }

  /// Records an asset id as needing targeted re-evaluation. If `pendingFullReconciliation` is
  /// already true, this is a no-op (the full-reconciliation pass will cover the asset).
  /// Otherwise, if adding the id would push `pendingAssetIds.count` above `costCap`, the
  /// targeted set is replaced with `pendingFullReconciliation = true` and `pendingAssetIds`
  /// is cleared. Returns `true` when the cap rolled over.
  @discardableResult
  mutating func recordPendingAssetId(_ id: String, costCap: Int) -> Bool {
    if pendingFullReconciliation { return true }
    if pendingAssetIds.contains(id) { return false }
    if pendingAssetIds.count + 1 > costCap {
      pendingAssetIds.removeAll()
      pendingFullReconciliation = true
      return true
    }
    pendingAssetIds.insert(id)
    return false
  }

  /// Clears every dirty flag for this scope. Call after a successful full reconciliation.
  mutating func clearAfterSuccessfulFullReconciliation() {
    pendingAssetIds.removeAll()
    pendingFullReconciliation = false
    pendingPlacementReconciliation = false
  }

  /// Removes a set of completed asset ids from the targeted set. No-op for ids not present.
  mutating func removeCompletedAssetIds(_ ids: Set<String>) {
    pendingAssetIds.subtract(ids)
  }
}

/// Per-destination dirty state for Auto Export. Persisted alongside the per-destination
/// `lastDurablyRecordedToken` snapshot so accumulated work survives interruption, restart,
/// and disable/enable cycles.
struct AutoSyncDirtyState: Codable, Equatable, Sendable {
  /// Keyed by `AutoExportLibraryScope.rawValue` — `"timeline"`, `"favorites"`, `"albums"` —
  /// so the persisted JSON shape stays explicit and survives enum-case renames.
  var scopes: [String: ScopeDirtyState]
  var lastUpdatedAt: Date

  init(scopes: [String: ScopeDirtyState] = [:], lastUpdatedAt: Date = .distantPast) {
    self.scopes = scopes
    self.lastUpdatedAt = lastUpdatedAt
  }

  static let empty = AutoSyncDirtyState()

  var isEmpty: Bool {
    scopes.values.allSatisfy(\.isEmpty)
  }

  /// Returns the dirty state for a scope, or `.empty` if no entry exists yet. Reading is
  /// always safe — the persisted shape is sparse, so an unknown key is "no work pending."
  func scope(_ scope: AutoExportLibraryScope) -> ScopeDirtyState {
    scopes[scope.rawValue] ?? .empty
  }

  /// Stores the dirty state for a scope. Empty values are removed from the dictionary so the
  /// persisted JSON stays sparse. `lastUpdatedAt` is *not* touched — callers update it via
  /// `markUpdated(at:)` after batching mutations so a single reducer event produces one
  /// timestamp rather than one per scope mutated.
  mutating func setScope(_ scope: AutoExportLibraryScope, _ value: ScopeDirtyState) {
    if value.isEmpty {
      scopes.removeValue(forKey: scope.rawValue)
    } else {
      scopes[scope.rawValue] = value
    }
  }

  /// Sets `lastUpdatedAt`. Reducer/manager code calls this once per persisted change with
  /// the time supplied by the injected `AutoSyncClock`, so tests using `TestClock` can pin
  /// the value deterministically rather than reading wall-clock time.
  mutating func markUpdated(at date: Date) {
    lastUpdatedAt = date
  }
}
