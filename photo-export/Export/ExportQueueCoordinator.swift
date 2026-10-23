import Combine
import Foundation
import OSLog
import Observation
import os

/// Owns pending jobs, the drain loop, pause/resume/clear, per-placement queue counts,
/// and published queue counters. Owns the cooperative cancellation generation and its
/// `isCurrent(_:)`, `throwIfCancelledOrStale(_:)`, and `bumpGeneration()` helpers.
///
/// `ExportManager` retains current-job identifiers and per-asset bookkeeping; the
/// coordinator calls its narrow `Host` to run each job and finalize the queue.
/// Synchronous sinks mirror published state onto the manager so SwiftUI and AutoSync
/// observe consistent transitions. See docs/reference/architecture-conventions.md.
@MainActor
final class ExportQueueCoordinator: ObservableObject {

  // MARK: - Host

  /// Hooks back to ExportManager for state it still owns: the export work itself,
  /// the queue-drain finalize hook, and the UI-state cleanup that runs between jobs.
  /// Cancellation stays on the coordinator; the manager forwards to its generation
  /// helpers instead of extending this Host protocol.
  @MainActor
  protocol Host: AnyObject {
    /// True while a bulk-album enqueue Task is still building the queue. The coordinator
    /// uses this to avoid prematurely finalizing an empty queue.
    var isEnqueueingAll: Bool { get }

    /// Drives the per-job export pipeline (resource fetch, variant write, record write).
    /// The coordinator's drain loop awaits this on a child Task.
    func performExport(job: ExportManager.ExportJob, generation: Int) async

    /// Called on the every-job-completed edge so ExportManager can finalize an awaitable
    /// run. Distinct from `clearCurrentJobIdentifiers` (which runs between jobs).
    func didDrainQueue()

    /// Brackets a complete synchronous queue transition so presentation callbacks run
    /// only after its counters, dispatch ownership and mirrors have committed.
    func beginProgressUpdates()
    func endProgressUpdates()

    /// Reports changed pending or in-flight contents after their synchronous updates.
    func queueContentsDidChange()

    /// Sets the manager's `currentJobPlacement`, `currentJobAssetId`, and resets
    /// `currentJobVariant` to nil before the export Task starts. Placement BEFORE
    /// assetId is the load-bearing ordering rule — any cancellation cleanup that
    /// observes `currentJobAssetId` must also see the matching `currentJobPlacement`.
    func setCurrentJob(_ job: ExportManager.ExportJob)

    /// Clears completed-job identifiers, retaining placement only between adjacent jobs.
    /// Pause, drain and teardown clear placement so its activity indicator stops.
    func clearCurrentJobIdentifiers(keepingPlacement: Bool)
  }

  // MARK: - Published queue state (mirrored on ExportManager)

  @Published private(set) var isRunning: Bool = false {
    // Must stay synchronous — no Publisher.send, no actor hops — so the
    // AutoSync seam's seven-step characterization sequence keeps its shape.
    didSet {
      guard isRunning != oldValue else { return }
      if isRunning {
        runInterval = Self.signposter.beginInterval("ExportRun")
        runWatchdog.begin()
      } else if let state = runInterval {
        runWatchdog.end()
        Self.signposter.endInterval("ExportRun", state)
        runInterval = nil
      }
    }
  }
  @Published private(set) var isPaused: Bool = false
  @Published private(set) var queueCount: Int = 0
  @Published private(set) var totalJobsEnqueued: Int = 0
  @Published private(set) var totalJobsCompleted: Int = 0

  /// `OSSignposter` for Instruments time-profile traces of export runs.
  /// Begin/end intervals around the `isRunning` state transition so a trace
  /// can pinpoint how long a drain loop took, irrespective of which `start*`
  /// entry point opened it. Mirrors the pattern at
  /// `PhotoLibraryPersistentChangeAdapter.signposter`.
  private static let signposter = OSSignposter(
    subsystem: Logger.appSubsystem,
    category: "Export.Run")
  private var runInterval: OSSignpostIntervalState?
  private let runWatchdog: ExportRunWatchdog

  // MARK: - Cooperative cancellation

  /// Generation counter bumped by every cancellation transition
  /// (`cancelAndClear`, `supersedeForManualRun`, `interruptForDestinationUnavailable`,
  /// `cancelImport`). Async work captures `let gen = generation` synchronously before
  /// the first `await` and re-checks `isCurrent(gen)` after every hop; a mid-flight
  /// bump returns false and the work bails out cooperatively.
  ///
  /// `clearPending()` (queue-only drop) does NOT bump generation — in-flight work
  /// keeps its `gen` and finishes normally.
  private(set) var generation: Int = 0

  /// Returns `true` if `gen` matches the current generation — i.e. the run that
  /// captured it has not been cancelled/superseded since.
  func isCurrent(_ gen: Int) -> Bool {
    generation == gen
  }

  /// Throws `CancellationError` if the Task is cancelled OR if `gen` is stale.
  /// Async work that needs to fail-stop rather than silently bail uses this in
  /// place of `guard isCurrent(gen) else { return }`.
  func throwIfCancelledOrStale(_ gen: Int) throws {
    try Task.checkCancellation()
    guard isCurrent(gen) else { throw CancellationError() }
  }

  /// Bumps the generation. Called by the cancellation transitions on
  /// `ExportManager` (which routes through here) and by `ImportCoordinator`'s
  /// cancel path (which holds a direct reference).
  func bumpGeneration() {
    generation += 1
  }

  // MARK: - Internal queue state

  private var jobStorage: [ExportManager.ExportJob] = []
  private var jobHead = 0
  var pendingJobs: ArraySlice<ExportManager.ExportJob> { jobStorage[jobHead...] }

  /// A month observes only its own queued and active state, published atomically.
  @Observable
  final class MonthQueueState {
    struct Snapshot: Equatable {
      var queued = 0
      var isActive = false
    }
    var snapshot = Snapshot()
  }
  private var monthStates: [String: MonthQueueState] = [:]
  private var activePlacementId: String?
  private var placementRevision = 0

  func monthState(placementId: String) -> MonthQueueState {
    if let state = monthStates[placementId] { return state }
    let state = MonthQueueState()
    state.snapshot = .init(
      queued: queuedCountsByPlacementId[placementId, default: 0],
      isActive: activePlacementId == placementId)
    monthStates[placementId] = state
    return state
  }

  func setActivePlacement(_ placementId: String?) {
    guard activePlacementId != placementId else { return }
    let old = activePlacementId
    activePlacementId = placementId
    if let old { refreshMonthState(old) }
    if let placementId { refreshMonthState(placementId) }
  }

  private func refreshMonthState(_ id: String) {
    guard let state = monthStates[id] else { return }
    // Observation callbacks run before storage and can synchronously cancel the run.
    // Reconcile again after each write so an outer setter cannot restore stale activity.
    while true {
      let next = MonthQueueState.Snapshot(
        queued: queuedCountsByPlacementId[id, default: 0],
        isActive: activePlacementId == id)
      guard state.snapshot != next else { return }
      state.snapshot = next
    }
  }

  private func removePendingJobs() {
    jobStorage.removeAll(keepingCapacity: true)
    jobHead = 0
  }
  /// `true` while the drain loop is actively pulling jobs off the queue. Distinct from
  /// `isRunning` (which is the published mirror): isRunning is the user-facing flag,
  /// isProcessing is the internal "loop is owning the next-job dispatch" gate that
  /// prevents reentrant `processQueueIfNeeded` calls from kicking parallel drains.
  /// Kept package-visible so existing `start*` "fresh-start condition" reads on
  /// ExportManager continue to compile.
  private(set) var isProcessing: Bool = false
  private(set) var currentTask: Task<Void, Never>?
  private(set) var queuedCountsByPlacementId: [String: Int] = [:]

  /// Compares the pending count, processing task and per-placement revision without
  /// retaining the dictionary across its next mutation.
  private struct QueueFingerprint: Equatable {
    let pendingJobCount: Int
    let isProcessing: Bool
    let currentTask: Task<Void, Never>?
    let placementRevision: Int
  }

  private var queueFingerprint: QueueFingerprint {
    QueueFingerprint(
      pendingJobCount: pendingJobs.count, isProcessing: isProcessing, currentTask: currentTask,
      placementRevision: placementRevision)
  }

  private func notifyQueueContentsChanged(since previous: QueueFingerprint) {
    guard queueFingerprint != previous else { return }
    for id in monthStates.keys { refreshMonthState(id) }
    host?.queueContentsDidChange()
  }

  // MARK: - Dependencies

  private let logger = Logger.app(.exportQueueCoordinator)
  private weak var host: Host?

  init(host: Host, watchdogEnabled: Bool = false) {
    self.host = host
    self.runWatchdog = ExportRunWatchdog(enabled: watchdogEnabled)
  }

  // MARK: - Pause / resume

  /// Sets `isPaused` so the next `processNext` iteration parks the queue. The
  /// admission check (`canTogglePause`) lives on `ExportManager` — pause is also valid
  /// during the "jobs queued, run loop not started yet" window the manager handles.
  func pause() {
    host?.beginProgressUpdates()
    defer { host?.endProgressUpdates() }
    isPaused = true
    logger.info("Export queue paused")
  }

  func resume() {
    host?.beginProgressUpdates()
    defer { host?.endProgressUpdates() }
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
    host?.beginProgressUpdates()
    defer { host?.endProgressUpdates() }
    let previous = queueFingerprint
    jobStorage.append(contentsOf: jobs)
    if !jobs.isEmpty { placementRevision &+= 1 }
    totalJobsEnqueued += jobs.count
    for job in jobs {
      queuedCountsByPlacementId[job.placement.id, default: 0] += 1
    }
    updateQueueCount()
    notifyQueueContentsChanged(since: previous)
  }

  /// Reads the per-placement queue depth. Existing callers query `(year, month)` via the
  /// timeline placement id.
  func queuedCount(placementId: String) -> Int {
    monthState(placementId: placementId).snapshot.queued
  }

  // MARK: - Clear

  /// Empties `pendingJobs`, decrements `totalJobsEnqueued` by the cleared count, clears
  /// the per-placement counters, and updates `queueCount`. Used by the `clearPending`
  /// ExportManager API and by the cancellation path.
  func clearPending() -> Int {
    host?.beginProgressUpdates()
    defer { host?.endProgressUpdates() }
    let previous = queueFingerprint
    let removed = pendingJobs.count
    removePendingJobs()
    if !queuedCountsByPlacementId.isEmpty { placementRevision &+= 1 }
    queuedCountsByPlacementId.removeAll()
    totalJobsEnqueued = max(0, totalJobsEnqueued - removed)
    updateQueueCount()
    notifyQueueContentsChanged(since: previous)
    logger.info("Cleared \(removed) pending export jobs")
    return removed
  }

  // MARK: - Teardown (called by ExportManager.cancelAndClear / supersedeForManualRun /
  //         interruptForDestinationUnavailable)

  /// Cancels the in-flight `currentTask`, clears every queue counter, drops the queue,
  /// resets running/paused/processing flags. Does NOT bump generation — callers that
  /// also want the cancellation seam to fire call `bumpGeneration()` separately. This
  /// split lets `clearPending` (queue-only drop, no cancellation of in-flight work)
  /// share the queue teardown logic.
  func teardownQueue() {
    host?.beginProgressUpdates()
    defer { host?.endProgressUpdates() }
    let previous = queueFingerprint
    currentTask?.cancel()
    currentTask = nil
    removePendingJobs()
    if !queuedCountsByPlacementId.isEmpty { placementRevision &+= 1 }
    queuedCountsByPlacementId.removeAll()
    isProcessing = false
    isRunning = false
    isPaused = false
    setActivePlacement(nil)
    queueCount = 0
    notifyQueueContentsChanged(since: previous)
  }

  /// Resets the published progress counters. ExportManager calls this before a fresh run
  /// starts so the UI doesn't carry counters from the previous run.
  func resetProgressCounters() {
    host?.beginProgressUpdates()
    defer { host?.endProgressUpdates() }
    let previous = queueFingerprint
    totalJobsEnqueued = 0
    totalJobsCompleted = 0
    if !queuedCountsByPlacementId.isEmpty { placementRevision &+= 1 }
    queuedCountsByPlacementId.removeAll()
    notifyQueueContentsChanged(since: previous)
  }

  // MARK: - Drain loop

  /// Kicks off the drain loop if it isn't already running. Idempotent — multiple calls
  /// during a single processing window collapse into one. Also handles the empty-queue
  /// edge: when called with no pending jobs and no bulk-enqueue task in flight, the
  /// host's `didDrainQueue` fires so any `runExport` awaitable resolves.
  func processQueueIfNeeded() {
    host?.beginProgressUpdates()
    defer { host?.endProgressUpdates() }
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
    host?.beginProgressUpdates()
    defer { host?.endProgressUpdates() }
    let previous = queueFingerprint
    if isPaused {
      isProcessing = false
      isRunning = false
      host?.clearCurrentJobIdentifiers(keepingPlacement: false)
      updateQueueCount()
      notifyQueueContentsChanged(since: previous)
      logger.info("Queue paused; not starting next job")
      return
    }
    guard !pendingJobs.isEmpty else {
      isProcessing = false
      isRunning = false
      host?.clearCurrentJobIdentifiers(keepingPlacement: false)
      updateQueueCount()
      notifyQueueContentsChanged(since: previous)
      logger.info("Export queue drained")
      host?.didDrainQueue()
      return
    }
    let currentGen = generation
    let job = jobStorage[jobHead]
    jobHead += 1
    if jobHead == jobStorage.count { removePendingJobs() }
    placementRevision &+= 1
    let key = job.placement.id
    queuedCountsByPlacementId[key, default: 1] -= 1
    if queuedCountsByPlacementId[key, default: 0] <= 0 {
      queuedCountsByPlacementId.removeValue(forKey: key)
    }
    host?.setCurrentJob(job)
    guard isCurrent(currentGen) else { return }
    updateQueueCount()
    guard isCurrent(currentGen) else { return }
    currentTask = Task(priority: .utility) { [weak self, weak host] in
      guard let self, self.isCurrent(currentGen) else { return }
      await host?.performExport(job: job, generation: currentGen)
      await MainActor.run { [weak self] in
        guard let self, self.isCurrent(currentGen) else { return }
        host?.beginProgressUpdates()
        defer { host?.endProgressUpdates() }
        host?.clearCurrentJobIdentifiers(keepingPlacement: true)
        self.totalJobsCompleted += 1
        self.processNext()
      }
    }
    notifyQueueContentsChanged(since: previous)
  }

  // MARK: - Queue depth

  private func updateQueueCount() {
    queueCount = pendingJobs.count + (isProcessing ? 1 : 0)
  }
}
