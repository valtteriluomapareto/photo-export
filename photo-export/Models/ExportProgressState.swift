import Foundation
import Observation

/// Per-job feedback and counters with field-specific Observation dependencies.
/// Progress readers follow filenames, counters and messages; sidebar rows follow only the
/// current placement. Run ownership and AutoSync's Combine contract stay on ExportManager.
@Observable
@MainActor
final class ExportProgressState {
  var manualSummary: ManualExportSummary?
  var totalJobsEnqueued: Int = 0
  var totalJobsCompleted: Int = 0
  var currentAssetFilename: String?

  /// Active render activity for the asset currently in flight. Surfaces in the
  /// progress bar so a long edited-video render does not look like a hang. `nil`
  /// whenever no render is active (the default for static-resource writes).
  var renderActivity: RenderActivity?

  /// Transient toolbar/progress-bar feedback for "you clicked Export but there
  /// was nothing new to do." Cleared on any new `startExport*`, version-selection
  /// change, `cancelAndClear`, or after the timeout managed by `ExportManager`.
  var emptyRunMessage: String?

  /// Persistent warning attached to active queue work — e.g. "couldn't list every
  /// album, continuing with what was queued." Rendered alongside the progress
  /// bar. Distinct from `emptyRunMessage`, which only renders when the queue is
  /// empty.
  var queueWarningMessage: String?

  /// Placement of the job currently in flight. Lives here (not on `ExportManager`)
  /// because it mutates twice per asset — once at `setCurrentJob`, once at
  /// `clearCurrentJobIdentifiers`. The only reader is `MonthRow`, which lights up
  /// its `ProgressView` for the row owning the in-flight job. AutoSync does not
  /// subscribe to it.
  var currentJobPlacement: ExportPlacement?
}
