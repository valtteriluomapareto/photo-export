import Combine
import Foundation

/// AutoSync's view of the export-run subsystem. `ExportManager` conforms in production;
/// tests inject a fake whose `runExport` resolves on demand and whose
/// `exportRunStatePublisher` can be driven by hand.
///
/// The publisher emits the current `ExportRunState` whenever it changes (run starts,
/// completes, is cancelled, or interrupted). `runExport(context:)` follows the
/// awaitable contract from Phase 0a — single active run, returns when terminal.
@MainActor
protocol AutoSyncExportRunning: AnyObject {
  /// Stream of `ExportRunState` snapshots. Replays the current state on subscribe so
  /// new subscribers always have a value.
  var exportRunStatePublisher: AnyPublisher<ExportRunState, Never> { get }

  /// Stream of the user's `ExportVersionSelection` (Include Originals toggle).
  /// AutoSync needs this to honor the user's selection in background runs.
  var versionSelectionPublisher: AnyPublisher<ExportVersionSelection, Never> { get }

  /// Awaitable run entry point. Caller (typically AutoSyncManager) constructs the
  /// `ExportRunContext` (incl. UUID + startedAt) and awaits the terminal summary.
  func runExport(context: ExportRunContext) async -> ExportRunSummary

  /// Stream of every run that finished through `runExport(context:)`, regardless
  /// of source. AutoSync filters to `.manual` and dispatches
  /// `manualFullExportCompleted` for the dirty-state-clearing rule in plan
  /// §"Dirty State". `.autoSync` runs are still routed through the
  /// `runExport`-await return path; this publisher exists specifically to give
  /// the manager a hook into manual-run completion without polling
  /// `exportRunStatePublisher` transitions.
  var completedRunsPublisher: AnyPublisher<ExportRunSummary, Never> { get }
}
