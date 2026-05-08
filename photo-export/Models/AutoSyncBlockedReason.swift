import Foundation

/// Why Auto Export is currently blocked or waiting. Distinct from `AutoSyncReason` (which
/// names the *trigger* that scheduled a run) — these are the conditions that prevent a run
/// from starting or scheduling.
///
/// Mapped 1:1 to the State Model section of the auto-sync plan.
enum AutoSyncBlockedReason: String, Codable, Equatable, CaseIterable, Sendable {
  /// Photos authorization missing (`.notDetermined` or `.denied`). The user must grant
  /// access in System Settings before Auto Export can run.
  case photosAccessMissing

  /// Photos authorization is `.limited` and the visible selection is empty. A non-empty
  /// limited library runs Auto Export normally with the limited-access notice visible —
  /// this case is reserved for "nothing visible to export."
  case limitedPhotosAccess

  /// No destination is currently selected.
  case destinationMissing

  /// Destination is selected but its volume is not mounted or its bookmark cannot be
  /// resolved. Resolves to `idle` once the drive becomes reachable again.
  case destinationUnavailable

  /// Destination is reachable but the safety scan blocks automatic runs (e.g., non-empty
  /// existing backup with no matching records, or a low-confidence identity that the user
  /// has not confirmed).
  case destinationUnsafe

  /// User has Auto Export enabled but every scope (Timeline / Favorites / Albums) is off.
  /// Settings copy must direct the user to enable at least one scope.
  case noScopesSelected

  /// A manual export is currently active. Auto-sync defers and re-evaluates after the
  /// manual run drains.
  case manualExportActive

  /// Import Existing Backup is currently running. Same defer-and-reevaluate behavior as
  /// `manualExportActive`.
  case importActive

  /// At least one variant is sitting in retry backoff and there is no other work eligible
  /// for export. Becomes `idle` when the backoff window elapses.
  case retryBackoff
}
