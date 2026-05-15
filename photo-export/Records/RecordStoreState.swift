import Foundation

/// Per-record-store load state. Both `ExportRecordStore` (timeline) and
/// `CollectionExportRecordStore` (favorites + albums) publish their own state.
///
/// Per `docs/project/plans/collections-export-plan.md` §"Recovery on Corruption":
/// - `.unconfigured` — `configure(for:)` has not been called with a destination id yet,
///   or it was called with `nil`. Reads return empty; writes silently no-op.
/// - `.ready` — snapshot decoded cleanly (or was absent); log replay succeeded. The store
///   accepts reads and writes normally.
/// - `.failed` — the snapshot file is present on disk but failed to decode. The corrupt
///   file is **left at its original path** (deferred-rename rule); reads return empty;
///   writes silently no-op (`assertionFailure` in debug). Only `resetToEmpty()` clears
///   the corrupt file (renaming it to `<name>.broken-<ISO8601>`) and transitions the
///   store back to `.ready`. The corruption alert UI that calls `resetToEmpty()` lives in
///   Phase 4; before then a `.failed` store is a silent state observable in tests.
///
/// Failure isolation: each store publishes its own state. A `.failed` collection store
/// does **not** put the timeline store in `.failed`, and vice versa.
enum RecordStoreState: Sendable, Equatable {
  case unconfigured
  case ready
  case failed
}
