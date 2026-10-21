import Combine
import Foundation

/// AutoSync's view of the export-run subsystem. `ExportManager` conforms in production;
/// tests inject a fake whose `runExport` resolves on demand and whose
/// `exportRunStatePublisher` can be driven by hand.
///
/// The publisher emits the current `ExportRunState` whenever it changes (run starts,
/// completes, is cancelled, or interrupted). `runExport(context:)` follows the
/// single-active-run contract: it returns when that run is terminal.
/// See docs/reference/auto-export-behavior.md#run-ownership-and-presentation.
@MainActor
protocol AutoSyncExportRunning: AnyObject {
  /// Stream of `ExportRunState` snapshots. Replays the current state on subscribe so
  /// new subscribers always have a value.
  var exportRunStatePublisher: AnyPublisher<ExportRunState, Never> { get }

  /// Stream of the user's `ExportVersionSelection` (Include Originals toggle).
  /// AutoSync needs this to honor the user's selection in background runs.
  var versionSelectionPublisher: AnyPublisher<ExportVersionSelection, Never> { get }

  /// Stream of the user's `Convert HEIC to JPEG` toggle. AutoSync
  /// re-evaluates eligibility on flip because the toggle widens
  /// `requiredVariants` for HEIC originals.
  var convertHEICToJPEGPublisher: AnyPublisher<Bool, Never> { get }

  /// Awaitable run entry point. Caller (typically AutoSyncManager) constructs the
  /// `ExportRunContext` (incl. UUID + startedAt) and awaits the terminal summary.
  func runExport(context: ExportRunContext) async -> ExportRunSummary

  /// Stops the AutoSync-sourced run in progress, if any, as `.cancelled` /
  /// `.userCancelled`. Called when the user turns Auto Export off. Synchronous and
  /// idempotent; a no-op for manual and legacy fire-and-forget runs.
  func cancelAutoSyncRun()

  /// Whether this exact recorded variant is complete for its placement. Used to
  /// prune retry entries after a matched run; a successful run summary alone cannot
  /// prove that every previously failed variant was selected and written.
  func isRetryVariantDone(
    scope: AutoSyncRetryScopeKey, assetId: String, variant: ExportVariant
  ) -> Bool

  /// Stream of every run that finished through `runExport(context:)`, regardless
  /// of source. AutoSync filters to `.manual` and dispatches
  /// `manualFullExportCompleted` to acknowledge compatible dirty work.
  /// `.autoSync` runs are still routed through the
  /// `runExport`-await return path; this publisher exists specifically to give
  /// the manager a hook into manual-run completion without polling
  /// `exportRunStatePublisher` transitions.
  var completedRunsPublisher: AnyPublisher<ExportRunSummary, Never> { get }
}
