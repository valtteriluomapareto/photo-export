import Foundation

/// Coalescing per-key cache for asset counts. Replaces Phase 2's uncached fetch with a
/// dedup'd per-key store: concurrent callers for the same key share one in-flight task,
/// and on `invalidateAll()` (driven by `PHPhotoLibraryChangeObserver`) every running
/// task is cancelled rather than stranded.
///
/// The cache is keyed by an opaque string. `PhotoLibraryManager` uses
/// `keyForCount(scope:)` / `keyForAdjustedCount(scope:)` so the same scope produces the
/// same key.
///
/// Per `docs/project/plans/collections-export-plan.md` §"PhotoLibraryService → off-main
/// counting": "A `CollectionCountCache` actor owns per-placement-id `Task<Int, Error>?`
/// handles. It exposes `count(for: placementId, fetch: () async throws -> Int) async -> Int`,
/// replacing any in-flight task for the same id (cancelling the prior). Cache
/// invalidation (`invalidateAll()`) cancels every in-flight task rather than stranding
/// them. Invalidation is called from the existing `PHPhotoLibraryChangeObserver`
/// callback."
actor CollectionCountCache {
  private struct InFlight {
    let token: UUID
    let task: Task<Int, Error>
  }

  private var inFlight: [String: InFlight] = [:]
  private var values: [String: Int] = [:]

  /// Returns the cached count for `key` if known. Otherwise starts a fetch task (or
  /// joins an existing in-flight one for the same key) and awaits it.
  ///
  /// Concurrent callers with the same key share the same Task — the second caller does
  /// not run `fetch` again. After `invalidateAll()`, a new caller starts a fresh task
  /// (the prior task's completion, if any, is discarded via the token check rather than
  /// overwriting the new task's result).
  func count(for key: String, fetch: @Sendable @escaping () async throws -> Int) async throws
    -> Int
  {
    if let cached = values[key] { return cached }
    if let existing = inFlight[key] { return try await existing.task.value }
    let token = UUID()
    let task = Task<Int, Error>(operation: fetch)
    inFlight[key] = InFlight(token: token, task: task)
    do {
      let value = try await task.value
      // Only persist if we're still the current entry. If `invalidateAll` ran (or a new
      // fetch started for the same key) our token won't match — discard the result.
      if inFlight[key]?.token == token {
        values[key] = value
        inFlight[key] = nil
      }
      return value
    } catch {
      if inFlight[key]?.token == token {
        inFlight[key] = nil
      }
      throw error
    }
  }

  /// Cancels every in-flight task and clears all cached values. Called on
  /// `PHPhotoLibraryChangeObserver.photoLibraryDidChange` so subsequent `count(for:fetch:)`
  /// calls re-fetch fresh data.
  func invalidateAll() {
    for (_, entry) in inFlight { entry.task.cancel() }
    inFlight.removeAll()
    values.removeAll()
  }
}
