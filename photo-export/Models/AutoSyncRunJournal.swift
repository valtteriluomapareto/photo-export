import Foundation

/// Crash-survivable record of an AutoSync fan-out that is currently in flight.
///
/// Written by `AutoSyncManager.startRun(spec:)` before the first sub-scope runs,
/// updated when each sub-scope becomes the active one, and deleted when the
/// fan-out completes cleanly (or is cancelled). If a journal exists on the next
/// launch's diagnostic, the previous session's AutoSync fan-out did not finish
/// — the OS killed the process mid-run.
///
/// Granularity is intentionally fan-out-level, not per-asset. `currentScope`
/// names which of the planned `scopes` was active when the kill happened
/// (`timeline` / `favorites` / `albums` / `sharedAlbums`). That is sufficient to
/// route a maintainer at the right code path for the silent-shutdown class of
/// bug surfaced by issue #112. Finer granularity (per-album, per-asset) would
/// require threading the journal into `ExportManager.runExport(context:)`,
/// which is deferred until a future bug actually needs that resolution.
///
/// Fields are categorical and never carry user data: scope kind raw values
/// (`AutoExportLibraryScope.rawValue`), trigger reason raw value
/// (`AutoSyncReason.rawValue`), ISO timestamps. The diagnostic report can be
/// pasted into a public issue without privacy review.
struct AutoSyncRunJournal: Codable, Equatable, Sendable {
  /// When the fan-out task started, captured from `AutoSyncEnvironment.clock`.
  let startedAt: Date
  /// Raw value of the `AutoSyncReason` that triggered the fan-out
  /// (`appLaunch`, `photosChanged`, etc.). String-rather-than-enum on disk
  /// so a future enum case from a newer build round-trips through an older
  /// build's decoder as the raw string rather than failing the whole decode.
  let trigger: String
  /// Raw values of the `AutoExportLibraryScope`s the fan-out plans to visit,
  /// in order. Same string-rather-than-enum rationale as `trigger`.
  let scopes: [String]
  /// Raw value of the `AutoExportLibraryScope` currently being processed,
  /// or `nil` before the first sub-scope iteration begins.
  var currentScope: String?
  /// When `currentScope` was set, captured from `AutoSyncEnvironment.clock`.
  var currentScopeStartedAt: Date?
}
