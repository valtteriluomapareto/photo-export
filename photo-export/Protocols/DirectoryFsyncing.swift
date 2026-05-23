import Foundation

/// Best-effort directory fsync seam. The production implementation opens the
/// directory read-only and calls `fsync(2)`; failures are silent because the
/// preceding rename / unlink succeeded and durability is a best-effort
/// concern for the diagnostic journal.
///
/// Exists as a protocol so tests can record invocations and prove the journal
/// store calls `fsyncDirectory(_:)` after every save and clear. The parent-dir
/// fsync is the load-bearing detail that distinguishes this store from the
/// existing run-summary store; a future refactor that drops the call would
/// silently re-introduce the durability gap the journal was specifically
/// architected to close.
///
/// Sendable so the existential can be stored in `@MainActor`-isolated owners
/// and passed into background queues if a future implementation needs to.
protocol DirectoryFsyncing: Sendable {
  /// Best-effort fsync of `url`'s underlying directory entry. Implementations
  /// must not throw — durability is opportunistic for this caller.
  func fsyncDirectory(_ url: URL)
}

/// Production implementation: `open(O_RDONLY)` + `fsync(2)` + `close(2)`.
/// Mirrors `JSONLRecordFile.fsyncDirectory` in shape. Duplicated rather than
/// shared because `JSONLRecordFile` is generic and exposing the helper would
/// force callers to carry unused generic parameters.
struct ProductionDirectoryFsync: DirectoryFsyncing {
  func fsyncDirectory(_ url: URL) {
    let fd = open(url.path, O_RDONLY)
    if fd < 0 { return }
    defer { close(fd) }
    _ = fsync(fd)
  }
}
