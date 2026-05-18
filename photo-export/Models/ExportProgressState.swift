import Foundation

/// Frequently-mutating per-job / per-variant state, split off from `ExportManager`
/// so that each progress update doesn't fan out as an `ExportManager.objectWillChange`
/// storm to every view holding the manager as `@EnvironmentObject`.
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
/// `$activeRunContext / $isRunning / $queueCount` on `ExportManager`, none of
/// which move here.
///
/// Tests that read `manager.totalJobsEnqueued` etc. continue to compile because
/// `ExportManager` keeps read-only computed forwarders.
@MainActor
final class ExportProgressState: ObservableObject {
  @Published var totalJobsEnqueued: Int = 0
  @Published var totalJobsCompleted: Int = 0
  @Published var currentAssetFilename: String?

  /// Active render activity for the asset currently in flight. Surfaces in the
  /// progress bar so a long edited-video render does not look like a hang. `nil`
  /// whenever no render is active (the default for static-resource writes).
  @Published var renderActivity: RenderActivity?

  /// Transient toolbar/progress-bar feedback for "you clicked Export but there
  /// was nothing new to do." Cleared on any new `startExport*`, version-selection
  /// change, `cancelAndClear`, or after the timeout managed by `ExportManager`.
  @Published var emptyRunMessage: String?

  /// Persistent warning attached to active queue work — e.g. "couldn't list every
  /// album, continuing with what was queued." Rendered alongside the progress
  /// bar. Distinct from `emptyRunMessage`, which only renders when the queue is
  /// empty.
  @Published var queueWarningMessage: String?

  /// Placement of the job currently in flight. Lives here (not on `ExportManager`)
  /// because it mutates twice per asset — once at `setCurrentJob`, once at
  /// `clearCurrentJobIdentifiers`. The only reader is `MonthRow`, which lights up
  /// its `ProgressView` for the row owning the in-flight job. AutoSync does not
  /// subscribe to it.
  @Published var currentJobPlacement: ExportPlacement?
}
