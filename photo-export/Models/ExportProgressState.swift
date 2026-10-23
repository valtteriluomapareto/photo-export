import Foundation
import Observation

/// Main-actor progress sources remain exact while the bar follows a coalesced presentation.
/// Run ownership and AutoSync's synchronous Combine contract stay on ExportManager.
@Observable
@MainActor
final class ExportProgressState {
  struct Presentation: Equatable {
    var manualSummary: ManualExportSummary?
    var totalJobsEnqueued = 0
    var totalJobsCompleted = 0
    var currentAssetFilename: String?
    var renderActivity: RenderActivity?
    var emptyRunMessage: String?
    var queueWarningMessage: String?
  }

  private(set) var presentation = Presentation()
  var manualSummary: ManualExportSummary? {
    didSet { if manualSummary != oldValue { changed(immediately: true) } }
  }
  var totalJobsEnqueued: Int = 0 {
    didSet {
      if totalJobsEnqueued != oldValue {
        changed(immediately: (oldValue > 0) != (totalJobsEnqueued > 0))
      }
    }
  }
  var totalJobsCompleted: Int = 0 {
    didSet {
      if totalJobsCompleted != oldValue {
        changed(immediately: totalJobsEnqueued > 0 && totalJobsCompleted >= totalJobsEnqueued)
      }
    }
  }
  var currentAssetFilename: String? {
    didSet { if currentAssetFilename != oldValue { changed() } }
  }

  /// Active render activity for the current asset; nil while no render is active.
  var renderActivity: RenderActivity? {
    didSet { if renderActivity != oldValue { changed() } }
  }

  /// Immediate feedback when an export request found nothing new to do.
  var emptyRunMessage: String? {
    didSet { if emptyRunMessage != oldValue { changed(immediately: true) } }
  }

  /// Persistent feedback when a partial enqueue leaves useful work to drain.
  var queueWarningMessage: String? {
    didSet { if queueWarningMessage != oldValue { changed(immediately: true) } }
  }

  /// Exact placement retained between adjacent jobs and cleared at owned stop boundaries.
  /// Sidebar activity is observed through the coordinator's per-month snapshots.
  var currentJobPlacement: ExportPlacement?

  @ObservationIgnored private let clock: any AutoSyncClock
  @ObservationIgnored private var pendingPresentation: AutoSyncCancellable?
  @ObservationIgnored private var presentationGeneration = 0
  @ObservationIgnored private var isPublishing = false
  @ObservationIgnored private var sourceUpdateDepth = 0
  @ObservationIgnored private var deferredChange = false
  @ObservationIgnored private var deferredFlush = false

  init(clock: (any AutoSyncClock)? = nil) {
    self.clock = clock ?? SystemAutoSyncClock()
  }

  private func changed(immediately: Bool = false) {
    let flush = immediately || totalJobsEnqueued == 0 || totalJobsCompleted >= totalJobsEnqueued
    if sourceUpdateDepth > 0 {
      deferredChange = true
      deferredFlush = deferredFlush || flush
      return
    }
    guard !isPublishing else { return }
    if flush {
      flushPresentation()
      return
    }
    guard pendingPresentation == nil else { return }
    presentationGeneration &+= 1
    let generation = presentationGeneration
    pendingPresentation = clock.schedule(after: 0.2) { [weak self] in
      guard let self, self.presentationGeneration == generation else { return }
      self.flushPresentation()
    }
  }

  /// Only presentation waits for an owning synchronous transition to finish. Exact source
  /// fields and Combine mirrors continue delivering in their existing order.
  func beginSourceUpdates() { sourceUpdateDepth += 1 }

  func endSourceUpdates() {
    sourceUpdateDepth -= 1
    guard sourceUpdateDepth == 0 else { return }
    let flush = deferredFlush
    let dirty = deferredChange
    deferredFlush = false
    deferredChange = false
    if flush { flushPresentation() } else if dirty { changed() }
  }

  /// Publishes the latest sources immediately at run and feedback boundaries.
  func flushPresentation() {
    if sourceUpdateDepth > 0 {
      deferredFlush = true
      return
    }
    guard !isPublishing else { return }
    presentationGeneration &+= 1
    pendingPresentation?.cancel()
    pendingPresentation = nil
    isPublishing = true
    defer { isPublishing = false }
    // A synchronous observer may cancel or replace feedback during willSet. Re-read the
    // sources after storage so the outer publication cannot restore an obsolete snapshot.
    while true {
      let next = Presentation(
        manualSummary: manualSummary, totalJobsEnqueued: totalJobsEnqueued,
        totalJobsCompleted: totalJobsCompleted, currentAssetFilename: currentAssetFilename,
        renderActivity: renderActivity, emptyRunMessage: emptyRunMessage,
        queueWarningMessage: queueWarningMessage)
      guard presentation != next else { return }
      presentation = next
    }
  }
}
