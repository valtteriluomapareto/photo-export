import Foundation

/// Why an Auto Export run was scheduled or started. Carried on `ExportRunContext` for
/// diagnostics and surfaced in the run summary so logs make it clear which trigger produced
/// a given run.
///
/// This is the trigger-side enum (what *caused* a run to be scheduled or started). The plan
/// keeps three vocabularies separate:
/// - `AutoSyncReason` (this type): what caused a debounce or run to start.
/// - `AutoSyncEvent` (lands with the reducer): inputs the reducer reacts to. Reducer events
///   like `retryTimerFired` and `manualFullExportCompleted` are *not* reasons; they are
///   their own events.
/// - `AutoSyncBlockedReason`: why Auto Export is currently blocked or waiting.
enum AutoSyncReason: String, Codable, Equatable, Sendable {
  case appLaunch
  case destinationSelected
  case destinationBecameAvailable
  case scopeSelectionChanged
  case versionSelectionChanged
  case photosChanged
  /// Fallback when the persistent-change token was expired/invalid/details-unavailable; a
  /// bounded full reconciliation runs after the 2-minute quiet window.
  case photosChangeFallback
  /// User invoked `Export Now` from the menu, status item, or Settings.
  case userExportNow

  /// User-facing short label. Single source of truth — main-window pill,
  /// menu bar item, and Settings status row all read this rather than
  /// each defining their own near-duplicate switch. Phrased as a short
  /// noun phrase so it fits inline ("Scheduled — photos changed", "Run
  /// in progress (app launch)").
  var userFacingLabel: String {
    switch self {
    case .appLaunch: return "app launch"
    case .destinationSelected: return "destination selected"
    case .destinationBecameAvailable: return "drive reconnected"
    case .scopeSelectionChanged: return "scope changed"
    case .versionSelectionChanged: return "version changed"
    case .photosChanged: return "library changed"
    case .photosChangeFallback: return "library catch-up"
    case .userExportNow: return "Export Now"
    }
  }
}

extension AutoSyncBlockedReason {
  /// User-facing short label. Single source of truth across all status
  /// surfaces. The pre-existing per-view `shortDescription` /
  /// `shortHelpText` / `shortLabel` extensions were near-duplicates with
  /// subtle wording differences.
  var userFacingLabel: String {
    switch self {
    case .photosAccessMissing: return "Photos access needed"
    case .limitedPhotosAccess: return "limited Photos access"
    case .destinationMissing: return "no destination"
    case .destinationUnavailable: return "drive disconnected"
    case .destinationUnsafe: return "destination needs review"
    case .noScopesSelected: return "pick what to export"
    case .manualExportActive: return "manual export running"
    case .importActive: return "import running"
    case .retryBackoff: return "retry backoff"
    }
  }
}
