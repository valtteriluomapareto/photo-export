import Combine
import Foundation
import OSLog

/// Owns the queue side of export execution: pending jobs, drain loop, pause/resume/clear,
/// per-placement queue counters, and the published mirrors for queue depth + total
/// counters.
///
/// Per `docs/project/plans/software-architecture-improvement-plan.md` Phase 4b, this is
/// where `pendingJobs`, `isProcessing`, `currentTask`, `queuedCountsByPlacementId`,
/// `processQueueIfNeeded`, `processNext`, `updateQueueCount`, `pause`, `resume`, and
/// `clearPending` live. ExportManager retains `generation`, the `currentJob*` UI
/// identifiers, the per-asset bookkeeping, and the `export(job:gen:)` body itself — the
/// coordinator drives the loop and calls back via `Host` to run each job. The plan
/// originally projected `generation` storage to migrate here in Phase 5; that transfer
/// is deferred to a follow-up and the Host getters (`generation`, `isCurrent`) are a
/// permanent seam until it lands.
///
/// `@Published` state on the coordinator is mirrored on ExportManager via sinks so
/// existing views and the AutoSync `exportRunStatePublisher` keep their stable read
/// surface. The Cross-Cutting Contract's "passthrough vs stored mirror" decision was
/// applied at the AutoSync seam (passthrough where the property was new). The queue
/// state was already stored `@Published` on ExportManager, so this phase keeps that
/// shape on the manager — the coordinator's publishers feed those mirrors.
@MainActor
final class ExportQueueCoordinator: ObservableObject {

  // MARK: - Host

  /// Hooks back to ExportManager for state it still owns: generation, the export work
  /// itself, the queue-drain finalize hook, and the UI-state cleanup that runs between
  /// jobs.
  @MainActor
  protocol Host: AnyObject {
    /// Phase 0 cancellation contract. Deferred follow-up will move `generation` storage
    /// into this coordinator; until then these are a permanent seam back to the manager.
    var generation: Int { get }
    func isCurrent(_ gen: Int) -> Bool

    /// True while a bulk-album enqueue Task is still building the queue. The coordinator
    /// uses this to avoid prematurely finalizing an empty queue.
    var isEnqueueingAll: Bool { get }

    /// Drives the per-job export pipeline (resource fetch, variant write, record write).
    /// The coordinator's drain loop awaits this on a child Task.
    func performExport(job: ExportManager.ExportJob, generation: Int) async

    /// Called on the every-job-completed edge so ExportManager can finalize an awaitable
    /// run. Distinct from `clearCurrentJobIdentifiers` (which runs between jobs).
    func didDrainQueue()

    /// Sets the manager's `currentJobPlacement`, `currentJobAssetId`, and resets
    /// `currentJobVariant` to nil before the export Task starts. Placement BEFORE
    /// assetId is the load-bearing ordering rule — any cancellation cleanup that
    /// observes `currentJobAssetId` must also see the matching `currentJobPlacement`.
    func setCurrentJob(_ job: ExportManager.ExportJob)

    /// Resets `currentJobAssetId`, `currentJobVariant`, `currentJobPlacement`, and
    /// `currentAssetFilename` to nil. The coordinator can't write these directly because
    /// they're the manager's UI-state mirrors.
    func clearCurrentJobIdentifiers()
  }

  // MARK: - Published queue state (mirrored on ExportManager)

  @Published private(set) var isRunning: Bool = false
  @Published private(set) var isPaused: Bool = false
  @Published private(set) var queueCount: Int = 0
  @Published private(set) var totalJobsEnqueued: Int = 0
  @Published private(set) var totalJobsCompleted: Int = 0

  // MARK: - Internal queue state

  private(set) var pendingJobs: [ExportManager.ExportJob] = []
  /// `true` while the drain loop is actively pulling jobs off the queue. Distinct from
  /// `isRunning` (which is the published mirror): isRunning is the user-facing flag,
  /// isProcessing is the internal "loop is owning the next-job dispatch" gate that
  /// prevents reentrant `processQueueIfNeeded` calls from kicking parallel drains.
  /// Kept package-visible so existing `start*` "fresh-start condition" reads on
  /// ExportManager continue to compile.
  private(set) var isProcessing: Bool = false
  private(set) var currentTask: Task<Void, Never>?
  private(set) var queuedCountsByPlacementId: [String: Int] = [:]

  // MARK: - Dependencies

  private let logger = Logger(
    subsystem: "com.valtteriluoma.photo-export", category: "ExportQueueCoordinator")
  private weak var host: Host?

  init(host: Host) {
    self.host = host
  }

  // MARK: - Pause / resume

  /// Sets `isPaused` so the next `processNext` iteration parks the queue. The
  /// admission check (`canTogglePause`) lives on `ExportManager` — pause is also valid
  /// during the "jobs queued, run loop not started yet" window the manager handles.
  func pause() {
    isPaused = true
    logger.info("Export queue paused")
  }

  func resume() {
    guard isPaused else { return }
    isPaused = false
    logger.info("Export queue resumed")
    processQueueIfNeeded()
  }

  // MARK: - Enqueue (called by ExportManager after planning)

  /// Appends jobs to the queue, updates per-placement counters, and bumps
  /// `totalJobsEnqueued`. The caller is responsible for invoking `processQueueIfNeeded()`
  /// after enqueueing (so a single processing kick can cover multiple enqueues in a
  /// bulk-album run).
  func enqueue(_ jobs: [ExportManager.ExportJob]) {
    pendingJobs.append(contentsOf: jobs)
    totalJobsEnqueued += jobs.count
    for job in jobs {
      queuedCountsByPlacementId[job.placement.id, default: 0] += 1
    }
    updateQueueCount()
  }

  /// Reads the per-placement queue depth. Existing callers query `(year, month)` via the
  /// timeline placement id.
  func queuedCount(placementId: String) -> Int {
    queuedCountsByPlacementId[placementId, default: 0]
  }

  // MARK: - Clear

  /// Empties `pendingJobs`, decrements `totalJobsEnqueued` by the cleared count, clears
  /// the per-placement counters, and updates `queueCount`. Used by the `clearPending`
  /// ExportManager API and by the cancellation path.
  func clearPending() -> Int {
    let removed = pendingJobs.count
    pendingJobs.removeAll()
    queuedCountsByPlacementId.removeAll()
    totalJobsEnqueued = max(0, totalJobsEnqueued - removed)
    updateQueueCount()
    logger.info("Cleared \(removed) pending export jobs")
    return removed
  }

  // MARK: - Teardown (called by ExportManager.cancelAndClear / supersedeForManualRun /
  //         interruptForDestinationUnavailable)

  /// Cancels the in-flight `currentTask`, clears every queue counter, drops the queue,
  /// resets running/paused/processing flags. Does NOT bump generation — `generation`
  /// lives on `ExportManager` and is bumped there by the cancellation paths
  /// (`teardownActiveWork`, `cancelImport`).
  func teardownQueue() {
    currentTask?.cancel()
    currentTask = nil
    pendingJobs.removeAll()
    queuedCountsByPlacementId.removeAll()
    isProcessing = false
    isRunning = false
    isPaused = false
    queueCount = 0
  }

  /// Resets the published progress counters. ExportManager calls this before a fresh run
  /// starts so the UI doesn't carry counters from the previous run.
  func resetProgressCounters() {
    totalJobsEnqueued = 0
    totalJobsCompleted = 0
    queuedCountsByPlacementId.removeAll()
  }

  // MARK: - Drain loop

  /// Kicks off the drain loop if it isn't already running. Idempotent — multiple calls
  /// during a single processing window collapse into one. Also handles the empty-queue
  /// edge: when called with no pending jobs and no bulk-enqueue task in flight, the
  /// host's `didDrainQueue` fires so any `runExport` awaitable resolves.
  func processQueueIfNeeded() {
    guard !isProcessing else { return }
    guard !isPaused else { return }
    guard !pendingJobs.isEmpty else {
      // Nothing to process. If an awaitable run is in flight (e.g. `runExport` for an
      // already-complete library), the queue-drain hook in `processNext` won't fire
      // because `processNext` won't run. Finalize here so the awaiter resolves.
      //
      // Guard on `!isEnqueueingAll` so a `resume()` during the brief window between an
      // enqueueing Task starting and adding the first job (queue is empty,
      // `processQueueIfNeeded` triggered from `resume()`) doesn't prematurely resolve a
      // run that's still in its enqueue phase.
      if host?.isEnqueueingAll == false {
        host?.didDrainQueue()
      }
      return
    }
    isProcessing = true
    isRunning = true
    processNext()
  }

  private func processNext() {
    if isPaused {
      isProcessing = false
      isRunning = false
      updateQueueCount()
      logger.info("Queue paused; not starting next job")
      return
    }
    guard !pendingJobs.isEmpty else {
      isProcessing = false
      isRunning = false
      host?.clearCurrentJobIdentifiers()
      updateQueueCount()
      logger.info("Export queue drained")
      host?.didDrainQueue()
      return
    }
    let job = pendingJobs.removeFirst()
    let key = job.placement.id
    queuedCountsByPlacementId[key, default: 1] -= 1
    if queuedCountsByPlacementId[key, default: 0] <= 0 {
      queuedCountsByPlacementId.removeValue(forKey: key)
    }
    host?.setCurrentJob(job)
    updateQueueCount()
    let currentGen = host?.generation ?? 0
    currentTask = Task { [weak self, weak host] in
      await host?.performExport(job: job, generation: currentGen)
      await MainActor.run { [weak self] in
        host?.clearCurrentJobIdentifiers()
        guard let self, self.host?.isCurrent(currentGen) == true else { return }
        self.totalJobsCompleted += 1
        self.processNext()
      }
    }
  }

  // MARK: - Queue depth

  private func updateQueueCount() {
    queueCount = pendingJobs.count + (isProcessing ? 1 : 0)
  }
}
