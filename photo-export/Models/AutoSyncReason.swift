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
}
