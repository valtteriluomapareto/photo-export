import Foundation

/// Why an Auto Export run was scheduled or started. Carried on `ExportRunContext` for diagnostics
/// and surfaced in the run summary so logs make it clear which trigger produced a given run.
///
/// This is the trigger-side enum (what caused the run). Blocking states like
/// `photosAccessMissing` / `destinationUnsafe` belong to a separate `AutoSyncBlockedReason`
/// enum that lands with the AutoSyncManager state machine.
enum AutoSyncReason: String, Codable, Equatable, Sendable {
  case appLaunch
  case destinationSelected
  case destinationBecameAvailable
  case scopeSelectionChanged
  case versionSelectionChanged
  case photosChanged
  case photosChangeFallback
  case retryTimerFired
  case manualExportNow
}
