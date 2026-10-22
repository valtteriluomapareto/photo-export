import Combine
import Foundation
import Observation

/// Per-job and per-variant state with its own observable owner. Both this state and
/// `ExportManager` track fields separately, so a view re-renders only for values it reads.
///
/// Why this exists: during a typical run, `currentAssetFilename`, `renderActivity`,
/// `totalJobsCompleted`, and `currentJobPlacement` all change several times per
/// asset. When they lived on `ExportManager`, every change fired the manager's
/// `objectWillChange`, which propagated to every observing view —
/// `LibraryRootView`, `TimelineSidebarView` (and its `MonthRow`s), `YearContentView`
/// (with its `isMonthFullyExported` per-tile computation), `MonthContentView`. The
/// per-view body re-evaluation was cheap individually but added up while the user
/// was scrolling the asset grid: ~5 cascades per asset turned into visible jank.
///
/// The fields here are read only by `ExportProgressBar` (counters / filename /
/// render activity / messages) and `MonthRow` (`currentJobPlacement` for the
/// in-flight spinner). AutoSync's seam is preserved — it subscribes to
/// `ExportManager.exportRunStatePublisher` (the run context, running flag, queue
/// count and bulk-enqueue flag), none of which move here.
///
/// Tests that read `manager.totalJobsEnqueued` etc. continue to compile because
/// `ExportManager` keeps read-only computed forwarders.
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

  private let emptyRunMessageBridge = ObservableCombineBridge<String?>(nil)
  /// Transient toolbar/progress-bar feedback for "you clicked Export but there
  /// was nothing new to do." Cleared on any new `startExport*`, version-selection
  /// change, `cancelAndClear`, or after the timeout managed by `ExportManager`.
  var emptyRunMessage: String? {
    get {
      access(keyPath: \.emptyRunMessage)
      return emptyRunMessageBridge.value
    }
    set {
      emptyRunMessageBridge.write(newValue) { withMutation(keyPath: \.emptyRunMessage, $0) }
    }
  }
  /// `emptyRunMessage` for Combine subscribers: synchronous, delivered before the value is
  /// stored, and replaying the current value (pinned by `PublisherParityTests`).
  var emptyRunMessagePublisher: AnyPublisher<String?, Never> {
    emptyRunMessageBridge.publisher
  }

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
