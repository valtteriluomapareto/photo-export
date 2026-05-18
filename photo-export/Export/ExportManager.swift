import AppKit
import Combine
import Foundation
import Photos
import SwiftUI
import os

@MainActor
final class ExportManager: ObservableObject {
  /// User-facing persistence key for the active version selection.
  static let versionSelectionDefaultsKey = "exportVersionSelection"

  /// How long the "already exported" toolbar message stays visible before it auto-clears.
  /// Long enough to read, short enough that subsequent work doesn't show stale state.
  static let emptyRunMessageDuration: TimeInterval = 6

  struct ExportJob: Equatable {
    let assetLocalIdentifier: String
    /// The placement this job is exporting under. Drives:
    /// - Which on-disk folder the asset lands in (`placement.relativePath`).
    /// - Which record store records the result (timeline → `exportRecordStore`,
    ///   `.favorites`/`.album` → `collectionExportRecordStore`); see *Routing record
    ///   mutations to the right store* in the plan.
    let placement: ExportPlacement
    /// Selection snapshot at enqueue time. Deterministic within a single job even if the user
    /// toggles selection mid-run.
    let selection: ExportVersionSelection

    /// Year derived from the placement. Defined for timeline jobs; returns `0` for
    /// `.favorites`/`.album`/`.sharedAlbum` placements where year/month is not part of
    /// the on-disk path (the destination uses `placement.relativePath` directly).
    var year: Int { placement.timelineYearMonth?.year ?? 0 }
    var month: Int { placement.timelineYearMonth?.month ?? 0 }
  }

  // MARK: - Published State (Export)
  @Published private(set) var isRunning: Bool = false
  @Published private(set) var queueCount: Int = 0
  @Published private(set) var isPaused: Bool = false

  /// Frequently-mutating progress-bar state lives here so the per-asset filename and
  /// per-job counter updates don't trigger `ExportManager.objectWillChange` storms.
  /// See `ExportProgressState` for the rationale and tests-still-pass forwarders below.
  let progressState = ExportProgressState()

  /// Forwarders to `progressState`. Read-only at the manager surface so callers that
  /// always treated these as `private(set)` continue to compile; internal writes go
  /// through `progressState.foo = …` directly.
  var totalJobsEnqueued: Int { progressState.totalJobsEnqueued }
  var totalJobsCompleted: Int { progressState.totalJobsCompleted }
  var currentAssetFilename: String? { progressState.currentAssetFilename }
  var renderActivity: RenderActivity? { progressState.renderActivity }
  var emptyRunMessage: String? { progressState.emptyRunMessage }
  var queueWarningMessage: String? { progressState.queueWarningMessage }

  private var emptyRunMessageTask: Task<Void, Never>?

  /// Which variants the pipeline writes for each asset. Persisted to `UserDefaults` so the
  /// choice survives restart and stays globally consistent regardless of destination.
  @Published var versionSelection: ExportVersionSelection {
    didSet {
      userDefaults.set(
        versionSelection.rawValue, forKey: Self.versionSelectionDefaultsKey)
      // The "already exported" copy is scoped to the previous selection — under a new
      // selection the user may have new work, so the message would be misleading.
      clearEmptyRunMessage()
    }
  }

  /// Toolbar/onboarding-friendly view of `versionSelection`. Off ↔ `.edited`, on ↔
  /// `.editedWithOriginals`. Mutations route back through `versionSelection` so
  /// `@Published` observation and `UserDefaults` persistence flow through one source.
  var includeOriginals: Bool {
    get { versionSelection == .editedWithOriginals }
    set { versionSelection = newValue ? .editedWithOriginals : .edited }
  }

  // MARK: - Published State (Import)
  @Published private(set) var isImporting: Bool = false
  @Published private(set) var importStage: BackupScanner.ImportStage?
  @Published var importResult: ImportReport?

  // MARK: - Awaitable run lifecycle (auto-sync Phase 0a)

  /// The `ExportRunContext` of the run currently in flight, or `nil` when idle. Set by
  /// `runExport(context:)`; cleared when the run reaches a terminal state. Callers
  /// observing this property see exactly one transition `nil → context → nil` per
  /// awaitable run; no event is emitted for runs started via the existing fire-and-forget
  /// `start*` methods.
  @Published private(set) var activeRunContext: ExportRunContext?

  /// Composite run-state observable for AutoSync. Republishes whenever the active
  /// context, the running flag, the queue depth, or the bulk-enqueue flag changes
  /// — so the fire-and-forget `start*` methods (which never set `activeRunContext`)
  /// still register as `isManualActive` while the queue is processing them OR
  /// while the bulk dispatcher is mid-enqueue but hasn't appended its first job
  /// yet. Without `isEnqueueingAll` in the tuple, AutoSync could observe `.idle`
  /// during the window between `isEnqueueingAll = true` and the first
  /// `pendingJobs.append`, and race to start its own background run on top of a
  /// user-initiated bulk export. See issue #67 item 4a.
  var exportRunStatePublisher: AnyPublisher<ExportRunState, Never> {
    Publishers.CombineLatest4($activeRunContext, $isRunning, $queueCount, $isEnqueueingAll)
      .map { context, isRunning, queueCount, isEnqueueingAll in
        let manualFireAndForget =
          context == nil && (isRunning || queueCount > 0 || isEnqueueingAll)
        return ExportRunState(
          activeContext: context,
          isManualActive: context?.source == .manual || manualFireAndForget,
          isAutoSyncActive: context?.source == .autoSync
        )
      }
      .removeDuplicates()
      .eraseToAnyPublisher()
  }

  /// Combine publisher for `versionSelection` so AutoSync can subscribe to user
  /// changes (Include Originals toggle). Without this, the reducer would default
  /// to `.edited` regardless of the user's actual setting.
  var versionSelectionPublisher: AnyPublisher<ExportVersionSelection, Never> {
    $versionSelection.eraseToAnyPublisher()
  }

  /// Combine publisher for the import flag.
  var isImportingPublisher: AnyPublisher<Bool, Never> {
    $isImporting.eraseToAnyPublisher()
  }

  /// Emits an `ExportRunSummary` whenever a `runExport(context:)` run reaches a
  /// terminal state. Used by AutoSync to detect manual-run completion (so it
  /// can clear compatible dirty state per plan §"Dirty State"). Fire-and-forget
  /// runs initiated via the legacy `startExport*` methods do not flow through
  /// this publisher — they don't build a context or summary. Phase 4 will
  /// migrate manual UI actions to `runExport(context:)` so this hook covers
  /// the complete set of manual completions.
  private let completedRunsSubject = PassthroughSubject<ExportRunSummary, Never>()
  var completedRunsPublisher: AnyPublisher<ExportRunSummary, Never> {
    completedRunsSubject.eraseToAnyPublisher()
  }

  /// AutoSync retry-eligibility hook. Closure returns `true` when the
  /// `(assetId, placement, variant)` is eligible to attempt at `now` — i.e.
  /// no retry entry exists, or `nextEligibleAt <= now`. Plan §"Retry and
  /// Failure Policy": "Retry evaluation belongs at enqueue time."
  ///
  /// `nil` means "no AutoSync retry policy installed"; all variants are
  /// eligible. Manual exports use this default — they never gate on the
  /// AutoSync retry store. Wired by `PhotoExportApp` to read from
  /// `AutoSyncManager.currentRetryState`.
  ///
  /// `@MainActor` annotation on the closure type makes the isolation
  /// explicit at the type level — the production wiring reads from
  /// `AutoSyncManager.currentRetryState`, which is `@MainActor`-isolated,
  /// so the closure can only be safely invoked on the main actor. The
  /// `ExportManager` enqueue paths that call it are already `@MainActor`,
  /// so this is a no-op at runtime but prevents future off-main callers
  /// from compiling.
  var autoSyncEligibilityCheck: (@MainActor (String, ExportPlacement, ExportVariant, Date) -> Bool)?

  private struct ActiveRunBookkeeping {
    let totalJobsEnqueuedAtStart: Int
    let totalJobsCompletedAtStart: Int
    let continuation: CheckedContinuation<ExportRunSummary, Never>
    /// Variant-failure count accumulated during this run. Bumped from
    /// `recordVariantFailed`. Reported as `ExportRunSummary.failedCount`; a non-zero
    /// value also flips a `.completed` queue-drain finalize to `.failed`.
    var failedCount: Int = 0
    /// Structured per-variant failure detail accumulated during this run.
    /// AutoSync reads `ExportRunSummary.failures` to record into
    /// `AutoSyncRetryState`; the Export Issues UI reads it to group by
    /// category. Mirror of `failedCount` but with full context — count
    /// should equal `failures.count` modulo any legacy sentinel paths.
    var failures: [ExportRunFailureDetail] = []
    /// Asset count skipped at enqueue time by the AutoSync retry-eligibility
    /// gate (plan §"Phase 3"): "ineligible variants count as `skippedCount`
    /// with a retry reason in the run summary." Reported on the summary;
    /// the per-variant detail is reconstructable from `AutoSyncRetryState`.
    var skippedCount: Int = 0
    /// Set when a bulk-album enqueue (`enqueueBulkAlbumExport`) threw partway
    /// through and the catch block elected to drain the partial queue instead
    /// of cancelling. Without this, the natural queue-drain finalize would
    /// resolve the run as `.completed` — and `AutoSyncReducer.coveredScopes`
    /// would then clear the scope's dirty flag, hiding the albums that the
    /// enqueue loop never reached from the next reconciliation pass. The flag
    /// flips `finalizeActiveRun`'s `.completed` to `.failed` so the dirty
    /// state survives and the next change-event-driven debounce retries.
    var partialBulkScan: Bool = false
  }
  private var activeRunBookkeeping: ActiveRunBookkeeping?

  /// Whether the export queue is active (has pending/in-flight work).
  var hasActiveExportWork: Bool {
    isRunning || queueCount > 0 || isEnqueueingAll
  }

  /// Whether the pause/resume toolbar control should accept clicks. Pausing is meaningful
  /// whenever there is work that *would* run — both the run-loop case (`isRunning`) and the
  /// "jobs queued, run loop not started yet" window (`queueCount > 0`) that opens between
  /// `enqueue*` appending jobs and `processQueueIfNeeded()` flipping `isRunning` to true.
  /// Without this, the pause button shows up during the second case but `pause()` no-ops,
  /// leaving the user unable to park a partially-enqueued batch.
  var canTogglePause: Bool {
    isRunning || queueCount > 0
  }

  /// `true` when a manual export action (Export Year, Export Month, Export Folder,
  /// Export Album, toolbar Cmd+E) should present the "Auto Export is running"
  /// supersede confirmation instead of dispatching immediately. The toolbar primary
  /// action and the in-pane `AutoSyncAwareExportButton`s both consult this so they
  /// behave consistently.
  var manualExportShouldConfirmSupersede: Bool {
    activeRunContext?.source == .autoSync
  }

  // MARK: - Dependencies
  private let logger = Logger(subsystem: "com.valtteriluoma.photo-export", category: "Export")
  let photoLibraryService: any PhotoLibraryService
  let exportDestination: any ExportDestination
  let exportRecordStore: ExportRecordStore
  let collectionExportRecordStore: CollectionExportRecordStore
  /// Single place that switches on `ExportPlacement.Kind` for record-store dispatch
  /// (reads, writes, cancellation cleanup, reuse-source lookup). Initialised in `init`
  /// once both stores are bound.
  let recordStoreRouter: RecordStoreRouter
  /// Owns destination URL and filename decisions: stem allocation, `_orig` companion
  /// naming, inherited group stem, unique-filename collision suffixing. Initialised in
  /// `init` against the same `fileSystem` the rest of the pipeline uses.
  let destinationResolver: ExportDestinationResolver
  /// Owns single-variant write path (resource selection, temp/move, reuse-source copy,
  /// rendered-media write, timestamps, record write). Initialised at the end of `init`
  /// once all dependencies + `self` are available.
  ///
  /// IUO because of the `host: self` cycle: `VariantExporter` is constructed with
  /// `host: self` so it can call back for the cancellation seam, UI-state mutations, and
  /// bookkeeping-aware failure recording — but `self` isn't usable until every stored
  /// property has a value. The IUO is assigned at the end of `init` (before init exits)
  /// and never reassigned thereafter; it retires whenever the Host protocol shrinks
  /// to zero callbacks that need `self` (a future refactor task — not load-bearing).
  private(set) var variantExporter: VariantExporter!
  let assetResourceWriter: any AssetResourceWriter
  // `var` rather than `let` so we can rebind it at the end of `init` with a
  // callback that captures `self` weakly. Swift forbids referencing `self`
  // (even weakly) before all stored properties are assigned, so the
  // production renderer is wired in two steps: a provisional no-op
  // callback during initialisation, then a live callback once `self` is
  // ready. Functionally a `let`; the `var` is purely for the init order.
  // DO NOT change this back to `let` without re-examining the closure
  // capture in `init` — the rebind is the whole point.
  private(set) var mediaRenderer: any MediaRenderer
  let fileSystem: any FileSystemService

  /// True when the **timeline** store is ready to accept writes. Timeline `startExport*`
  /// methods short-circuit when false, preventing the silent-false-success case where the
  /// pipeline would write files to disk while the store's `append` silently no-ops because
  /// `state != .ready` (either `.unconfigured` or `.failed`).
  ///
  /// Phase 3 adds `canExportCollection` for the `.favorites`/`.album` start methods. The
  /// two are deliberately independent so a `.failed` collection store does not block
  /// timeline export and vice versa — the disjoint-key-spaces rationale (a failed
  /// favorites export can't corrupt timeline records) extends to the start-side guards.
  var canExportTimeline: Bool {
    exportRecordStore.state == .ready
  }

  /// True when the **collection** store is ready. Used by Phase 3's
  /// `startExportFavorites`/`startExportAlbum` start methods.
  var canExportCollection: Bool {
    collectionExportRecordStore.state == .ready
  }

  // MARK: - Internals

  /// Owns `pendingJobs`, `isProcessing`, `currentTask`, the per-placement queue
  /// counters, and the drain loop. ExportManager forwards reads via computed properties
  /// below (for call-site stability) and forwards control calls (`pause`, `resume`,
  /// `clearPending`, `processQueueIfNeeded`). The @Published mirrors on this manager
  /// (`isRunning`, `isPaused`, `queueCount`, `totalJobsEnqueued`, `totalJobsCompleted`)
  /// are kept in sync with the coordinator's own publishers via sinks established in
  /// `init` — so existing UI bindings and the AutoSync `exportRunStatePublisher` keep
  /// emitting from the same `ExportManager` source.
  ///
  /// IUO for the same `host: self` cycle as `variantExporter` (see that property above)
  /// — `self` must be fully initialized before the coordinator can hold it as Host.
  private(set) var queueCoordinator: ExportQueueCoordinator!

  /// Owns the Import Existing Backup flow. Phase 5 extraction. `isImporting` and
  /// `importStage` on this manager are sink-driven mirrors of the coordinator's
  /// publishers (same shape as the queue coordinator mirrors). `importResult` stays
  /// writable on the manager because external callers (test code) sometimes reset it
  /// directly; the coordinator writes through `Host.setImportResult`.
  private(set) var importCoordinator: ImportCoordinator!
  private var importCancellables: Set<AnyCancellable> = []
  private var queueCancellables: Set<AnyCancellable> = []

  // Forwarders to the coordinator's internal state. Kept on ExportManager so existing
  // test reads (`manager.pendingJobs`, `manager.currentTask`,
  // `manager.queuedCountsByPlacementId`) and the "fresh-start condition" check in the
  // `start*` methods (`!isProcessing`) don't have to thread through `queueCoordinator`.
  var pendingJobs: [ExportJob] { queueCoordinator.pendingJobs }
  var currentTask: Task<Void, Never>? { queueCoordinator.currentTask }
  var queuedCountsByPlacementId: [String: Int] { queueCoordinator.queuedCountsByPlacementId }
  var isProcessing: Bool { queueCoordinator.isProcessing }

  private(set) var currentJobAssetId: String?
  private(set) var currentJobVariant: ExportVariant?
  /// The placement of the job currently in flight. Set in `processNext()` *before*
  /// `currentJobAssetId` and reset everywhere `currentJobAssetId` is reset, so any
  /// cancellation cleanup that observes `currentJobAssetId` is guaranteed to see the
  /// matching placement. Used by both the `cancelAndClear` and run-loop catch-block
  /// cleanup paths to route the `removeVariant` call to the correct store via
  /// `placement.kind`.
  ///
  /// The observable storage lives on `progressState` so that the per-job mutation
  /// (set on job start, cleared on job end — twice per asset) doesn't fan out as
  /// `ExportManager.objectWillChange` to every view holding the manager. The only
  /// SwiftUI reader is `MonthRow`'s in-flight spinner; it subscribes to
  /// `ExportProgressState` directly. This forwarder keeps internal write sites in
  /// the manager unchanged. `private(set)` preserves the pre-extraction surface —
  /// only the manager (and a `setCurrentJob` / `clearCurrentJobIdentifiers` it
  /// owns) may mutate the in-flight placement.
  private(set) var currentJobPlacement: ExportPlacement? {
    get { progressState.currentJobPlacement }
    set { progressState.currentJobPlacement = newValue }
  }
  /// Forwarder to `queueCoordinator.generation`. The Phase-0 cancellation storage
  /// moved to `ExportQueueCoordinator` in issue #67 item 2; this computed property
  /// preserves `manager.generation` as a stable read surface for tests and
  /// in-module callers.
  var generation: Int { queueCoordinator.generation }
  /// `@Published` so AutoSync's `exportRunStatePublisher` can include the
  /// bulk-enqueue window (after the dispatcher flips this true but before the
  /// first job lands in `pendingJobs`) in its idle/active decision. Issue #67
  /// item 4a — without this, AutoSync would race to start a background run
  /// during the multi-select / Export-All dispatcher's mid-enqueue window.
  @Published private(set) var isEnqueueingAll: Bool = false
  /// Forwarder to the import coordinator's task handle so existing test reads
  /// (`manager.importTask`) and the `waitForImportCompletion` test helper continue to
  /// resolve against the same in-flight Task.
  var importTask: Task<Void, Never>? { importCoordinator?.importTask }

  /// Backing store for `versionSelection`. Mirrors the injected-`UserDefaults`
  /// pattern used by `ExportDestinationManager` so tests can hand a per-suite
  /// instance and stop sharing `UserDefaults.standard` across concurrently-running
  /// `@MainActor` test suites — the cross-suite race that PR #29 papered over
  /// with `.serialized`.
  private let userDefaults: UserDefaults

  init(
    photoLibraryService: any PhotoLibraryService,
    exportDestination: any ExportDestination,
    exportRecordStore: ExportRecordStore,
    collectionExportRecordStore: CollectionExportRecordStore? = nil,
    assetResourceWriter: any AssetResourceWriter = ProductionAssetResourceWriter(),
    mediaRenderer: (any MediaRenderer)? = nil,
    fileSystem: any FileSystemService = FileIOService(),
    userDefaults: UserDefaults = .standard
  ) {
    self.userDefaults = userDefaults
    self.photoLibraryService = photoLibraryService
    self.exportDestination = exportDestination
    self.exportRecordStore = exportRecordStore
    // Default to a fresh collection store backed by the same on-disk root as the timeline
    // store. Tests typically pass `nil` and get a default-rooted store; production wires
    // an injected one from `photo_exportApp` so both stores share the destination's
    // `<App Support>/<bundleId>/ExportRecords/<destinationId>/` directory.
    self.collectionExportRecordStore = collectionExportRecordStore ?? CollectionExportRecordStore()
    self.recordStoreRouter = RecordStoreRouter(
      timelineStore: self.exportRecordStore,
      collectionStore: self.collectionExportRecordStore)
    self.assetResourceWriter = assetResourceWriter
    self.fileSystem = fileSystem
    self.destinationResolver = ExportDestinationResolver(fileSystem: fileSystem)
    // Provisional renderer — gives `self.mediaRenderer` a value so all
    // stored properties are initialised before we capture `self` below.
    if let mediaRenderer {
      self.mediaRenderer = mediaRenderer
    } else {
      self.mediaRenderer = ProductionMediaRenderer { _ in }
    }
    if let raw = userDefaults.string(forKey: Self.versionSelectionDefaultsKey),
      let saved = ExportVersionSelection(rawValue: raw)
    {
      self.versionSelection = saved
    } else {
      self.versionSelection = .edited
    }
    // `self` is fully initialised now — rebind the default renderer with
    // a callback that routes render activity back to `renderActivity`.
    if mediaRenderer == nil {
      self.mediaRenderer = ProductionMediaRenderer { @Sendable [weak self] activity in
        Task { @MainActor [weak self] in
          self?.progressState.renderActivity = activity
        }
      }
    }
    // Coordinator is constructed first so it can be injected into VariantExporter
    // and ImportCoordinator. Both reach the Phase-0 cancellation seam (generation /
    // isCurrent / throwIfCancelledOrStale) through this reference rather than
    // through their Host protocols (issue #67 item 2).
    self.queueCoordinator = ExportQueueCoordinator(host: self)
    self.variantExporter = VariantExporter(
      host: self,
      queueCoordinator: self.queueCoordinator,
      destinationResolver: self.destinationResolver,
      recordStoreRouter: self.recordStoreRouter,
      assetResourceWriter: self.assetResourceWriter,
      mediaRenderer: self.mediaRenderer,
      fileSystem: self.fileSystem,
      exportDestination: self.exportDestination)
    // Mirror the coordinator's published queue state onto ExportManager so existing
    // `manager.isRunning` / `.queueCount` / etc. readers and the AutoSync
    // `exportRunStatePublisher` keep emitting from the same source. Sinks fire
    // synchronously on the `@MainActor` since both objects are MainActor-bound.
    self.queueCoordinator.$isRunning
      .sink { [weak self] in self?.isRunning = $0 }
      .store(in: &queueCancellables)
    self.queueCoordinator.$isPaused
      .sink { [weak self] in self?.isPaused = $0 }
      .store(in: &queueCancellables)
    self.queueCoordinator.$queueCount
      .sink { [weak self] in self?.queueCount = $0 }
      .store(in: &queueCancellables)
    self.queueCoordinator.$totalJobsEnqueued
      .sink { [weak self] in self?.progressState.totalJobsEnqueued = $0 }
      .store(in: &queueCancellables)
    self.queueCoordinator.$totalJobsCompleted
      .sink { [weak self] in self?.progressState.totalJobsCompleted = $0 }
      .store(in: &queueCancellables)
    self.importCoordinator = ImportCoordinator(host: self, queueCoordinator: self.queueCoordinator)
    self.importCoordinator.$isImporting
      .sink { [weak self] in self?.isImporting = $0 }
      .store(in: &importCancellables)
    self.importCoordinator.$importStage
      .sink { [weak self] in self?.importStage = $0 }
      .store(in: &importCancellables)
  }

  // MARK: - Lifetime contract
  //
  // `ExportManager` is owned by `PhotoExportApp` as an `@StateObject` for the entire
  // app lifetime, so a pending `runExport` continuation effectively cannot outlive the
  // process. Tests must call `cancelAndClear()` (or `interruptForDestinationUnavailable()`)
  // during teardown to resolve any active run before the harness drops its reference —
  // otherwise the `CheckedContinuation` will trap when deallocated unresumed. There is
  // no `deinit`-side cleanup because reaching @MainActor state from a nonisolated
  // deinit would require `MainActor.assumeIsolated`, which itself traps off-main, and
  // resolving the trap with weak references is not possible (continuation is a value
  // type that cannot be `weak`-referenced).

  // MARK: - Public API
  func startExportMonth(year: Int, month: Int) {
    guard !isImporting else {
      logger.warning("startExportMonth ignored: import in progress")
      return
    }
    guard canExportTimeline else {
      logger.error(
        "startExportMonth ignored: timeline store state=\(String(describing: self.exportRecordStore.state), privacy: .public) (need .ready)"
      )
      return
    }
    // Snapshot the active selection synchronously so a picker flip before the async enqueue
    // lands (after `fetchAssets` returns) cannot change the mode that was visible at click
    // time. The picker in the toolbar is also gated on `hasActiveExportWork` for clarity, but
    // this snapshot is the correctness guarantee.
    let selection = versionSelection
    clearEmptyRunMessage()
    clearQueueWarningMessage()
    // Only reset progress counters when the queue is truly idle. "Paused
    // with pending jobs" satisfies `!isRunning && !isProcessing` but is
    // not idle — resetting the counter there detaches the visible
    // `done/total` from `pendingJobs.count`, so the user sees a counter
    // for the new work while the queue actually drains the leftover
    // paused jobs first.
    if !isRunning && !isProcessing && pendingJobs.isEmpty { resetProgressCounters() }
    let gen = generation
    Task { [weak self] in
      guard let self, self.isCurrent(gen) else { return }
      do {
        let outcome = try await enqueueMonth(
          year: year, month: month, selection: selection, generation: gen)
        guard self.isCurrent(gen) else { return }
        switch outcome {
        case .enqueued, .unauthorized:
          break
        case .alreadyComplete:
          setEmptyRunMessage("This month is already exported.")
        }
        processQueueIfNeeded()
      } catch {
        logger.error(
          "Failed to enqueue month export: \(String(describing: error), privacy: .public)"
        )
      }
    }
  }

  func startExportYear(year: Int) {
    guard !isImporting else {
      logger.warning("startExportYear ignored: import in progress")
      return
    }
    guard canExportTimeline else {
      logger.error(
        "startExportYear ignored: timeline store state=\(String(describing: self.exportRecordStore.state), privacy: .public)"
      )
      return
    }
    let selection = versionSelection
    clearEmptyRunMessage()
    clearQueueWarningMessage()
    if !isRunning && !isProcessing && pendingJobs.isEmpty { resetProgressCounters() }
    let gen = generation
    Task { [weak self] in
      guard let self, self.isCurrent(gen) else { return }
      do {
        let outcome = try await enqueueYear(
          year: year, selection: selection, generation: gen)
        guard self.isCurrent(gen) else { return }
        switch outcome {
        case .enqueued, .unauthorized:
          break
        case .alreadyComplete:
          setEmptyRunMessage("This year is already exported.")
        }
        processQueueIfNeeded()
      } catch {
        logger.error(
          "Failed to enqueue year export: \(String(describing: error), privacy: .public)"
        )
      }
    }
  }

  func startExportAll(selectionOverride: ExportVersionSelection? = nil) {
    guard !isImporting else {
      logger.warning("startExportAll ignored: import in progress")
      return
    }
    guard canExportTimeline else {
      logger.error(
        "startExportAll ignored: timeline store state=\(String(describing: self.exportRecordStore.state), privacy: .public)"
      )
      return
    }
    guard !isEnqueueingAll else { return }
    // selectionOverride lets `runExport(context:)` honor the run context's selection
    // without mutating the user-visible toolbar `versionSelection`.
    let selection = selectionOverride ?? versionSelection
    clearEmptyRunMessage()
    clearQueueWarningMessage()
    isEnqueueingAll = true
    // Same idle check as the other start functions: a paused queue with
    // pending jobs must not reset the counter — Export All accumulates
    // onto whatever is already queued. Users who want a clean slate
    // should cancel first.
    if !isRunning && !isProcessing && pendingJobs.isEmpty { resetProgressCounters() }
    let gen = generation
    runBulkExportTask(
      generation: gen,
      logTag: "startExportAll",
      emptyDoneMessage: { "Everything in this destination is already exported." },
      partialScanWarning: {
        "Couldn't list every year. Continuing with the photos already queued."
      },
      body: { [weak self] in
        guard let self else { return .stale }
        let allYears = try self.photoLibraryService.availableYears()
        let result = try await self.runBulkEnqueueLoop(items: allYears, generation: gen) { year in
          try await self.enqueueYear(year: year, selection: selection, generation: gen)
        }
        return result.completed ? .completed(result.totals) : .stale
      }
    )
  }

  /// Outcome of an enqueue scan over a month, year, or library. Either real work was
  /// queued, every asset in scope is already done, or the Photos library is not
  /// accessible and we cannot scan at all (the latter is a defensive case — the export
  /// button is gated on `isAuthorized` in the UI, so users should not reach this path).
  private enum EnqueueOutcome: Equatable {
    case enqueued(Int)
    case alreadyComplete
    case unauthorized
  }

  /// Multi-select bulk export across an arbitrary mix of years and months on the
  /// timeline. Caller supplies the normalized buckets from `TimelineSelectionBuckets`
  /// — year supersedes month-in-same-year is already applied. Each item runs through
  /// the existing `enqueueYear` / `enqueueMonth` helper so dedup against the record
  /// store is shared with the single-select paths.
  func startExportTimelineSelection(
    years: [Int],
    months: [TimelineSelectionBuckets.TimelineMonth],
    selectionOverride: ExportVersionSelection? = nil
  ) {
    guard !isImporting else {
      logger.warning("startExportTimelineSelection ignored: import in progress")
      return
    }
    guard canExportTimeline else {
      logger.error(
        "startExportTimelineSelection ignored: timeline store state=\(String(describing: self.exportRecordStore.state), privacy: .public)"
      )
      return
    }
    guard !isEnqueueingAll else { return }
    if years.isEmpty && months.isEmpty {
      setEmptyRunMessage("No timeline items selected.")
      return
    }
    let selection = selectionOverride ?? versionSelection
    clearEmptyRunMessage()
    clearQueueWarningMessage()
    isEnqueueingAll = true
    if !isRunning && !isProcessing && pendingJobs.isEmpty { resetProgressCounters() }
    let gen = generation
    runBulkExportTask(
      generation: gen,
      logTag: "startExportTimelineSelection",
      emptyDoneMessage: { "Everything in the selection is already exported." },
      partialScanWarning: {
        "Couldn't scan every item in the selection. Continuing with the photos already queued."
      },
      body: { [weak self] in
        guard let self else { return .stale }
        let yearsResult = try await self.runBulkEnqueueLoop(items: years, generation: gen) { year in
          try await self.enqueueYear(year: year, selection: selection, generation: gen)
        }
        guard yearsResult.completed else { return .stale }
        let monthsResult = try await self.runBulkEnqueueLoop(
          items: months, generation: gen, startingFrom: yearsResult.totals
        ) { m in
          try await self.enqueueMonth(
            year: m.year, month: m.month, selection: selection, generation: gen)
        }
        return monthsResult.completed ? .completed(monthsResult.totals) : .stale
      }
    )
  }

  // MARK: - Collection start methods (Phase 3)

  /// Starts an export of the user's Favorites. Routes through the resolver so the
  /// placement is the canonical `collections:favorites`. Gated on
  /// `canExportCollection`; the timeline store's state is not consulted (collection and
  /// timeline exports are independent under the disjoint-key-spaces rationale).
  func startExportFavorites(selectionOverride: ExportVersionSelection? = nil) {
    guard !isImporting else {
      logger.warning("startExportFavorites ignored: import in progress")
      return
    }
    guard canExportCollection else {
      logger.error(
        "startExportFavorites ignored: collection store state=\(String(describing: self.collectionExportRecordStore.state), privacy: .public) (need .ready)"
      )
      return
    }
    let selection = selectionOverride ?? versionSelection
    clearEmptyRunMessage()
    clearQueueWarningMessage()
    if !isRunning && !isProcessing && pendingJobs.isEmpty { resetProgressCounters() }
    let gen = generation
    Task { [weak self] in
      guard let self, self.isCurrent(gen) else { return }
      do {
        let outcome = try await enqueueCollection(
          selection: .favorites, scope: .favorites, selectionMode: selection, generation: gen)
        guard self.isCurrent(gen) else { return }
        switch outcome {
        case .enqueued, .unauthorized:
          break
        case .alreadyComplete:
          setEmptyRunMessage("Favorites are already exported.")
        }
        processQueueIfNeeded()
      } catch {
        logger.error(
          "Failed to enqueue favorites export: \(String(describing: error), privacy: .public)"
        )
        if pendingJobs.isEmpty {
          finalizeActiveRun(result: .failed, cancelReason: nil)
        }
      }
    }
  }

  /// Collections sidebar surfaces. AutoSync passes `selectionOverride` so a scheduled
  /// run honours the AutoSync version selection regardless of the current UI toggle.
  func startExportAllAlbums(selectionOverride: ExportVersionSelection? = nil) {
    enqueueBulkAlbumExport(
      source: .allAlbums,
      logTag: "startExportAllAlbums",
      emptyMessage: "No albums to export.",
      allDoneMessage: "All albums in this destination are already exported.",
      selectionOverride: selectionOverride
    )
  }

  /// Batch action for every iCloud shared album. Used by Auto Export's
  /// `.sharedAlbums` scope and any future "Export All Shared Albums" UI surface.
  /// Mirrors `startExportAllAlbums` but routes through the `.sharedAlbum` placement
  /// kind so each batch member writes to `Collections/Shared Albums/<title>/` at
  /// reduced fidelity (one downscaled JPEG per asset).
  func startExportAllSharedAlbums(selectionOverride: ExportVersionSelection? = nil) {
    enqueueBulkAlbumExport(
      source: .allSharedAlbums,
      logTag: "startExportAllSharedAlbums",
      emptyMessage: "No shared albums to export.",
      allDoneMessage: "All shared albums in this destination are already exported.",
      selectionOverride: selectionOverride
    )
  }

  /// Starts an export of every user album under a single folder, recursively. Each
  /// descendant album resolves to its own `ExportPlacement` exactly as if the user had
  /// opened the album individually and clicked Export Album — folders are not their own
  /// placements, they only group children, and `pathComponents` on each album already
  /// encodes the parent folder hierarchy in the on-disk path.
  func startExportFolder(folderId: String) {
    enqueueBulkAlbumExport(
      source: .folder(folderId: folderId),
      logTag: "startExportFolder",
      emptyMessage: "This folder has no albums to export.",
      allDoneMessage: "All albums in this folder are already exported."
    )
  }

  /// Starts an export of an explicit list of user albums by `collectionLocalIdentifier`.
  /// Drives the multi-select tile flow in `FolderContentView`: the caller computes the
  /// union of selected album ids (expanding any selected subfolders to their descendant
  /// albums) and passes the deduplicated list here.
  func startExportAlbums(collectionIds: [String]) {
    var seen = Set<String>()
    let deduped = collectionIds.filter { seen.insert($0).inserted }
    enqueueBulkAlbumExport(
      source: .explicitIds(deduped),
      logTag: "startExportAlbums",
      emptyMessage: "No albums in selection.",
      allDoneMessage: "All selected albums are already exported."
    )
  }

  /// Multi-select bulk export across a mixed Collections sidebar selection. Caller
  /// supplies the normalized buckets from `CollectionsSelectionBuckets`. Each kind
  /// (favorites, user albums, shared albums) is enqueued by calling the same
  /// `enqueueCollection` helper the per-kind start methods use — but all three
  /// loops run in a *single* Task so the user sees one merged enqueue lifecycle
  /// and one final `emptyRunMessage` instead of three fire-and-forget Tasks
  /// racing on the message slot. Partial-failure recovery and generation
  /// tracking match `enqueueBulkAlbumExport`.
  func startExportCollectionsSelection(_ buckets: CollectionsSelectionBuckets) {
    guard !isImporting else {
      logger.warning("startExportCollectionsSelection ignored: import in progress")
      return
    }
    guard canExportCollection else {
      logger.error(
        "startExportCollectionsSelection ignored: collection store state=\(String(describing: self.collectionExportRecordStore.state), privacy: .public)"
      )
      return
    }
    guard !isEnqueueingAll else { return }
    if buckets.isEmpty {
      setEmptyRunMessage("No collections selected.")
      return
    }
    let selection = versionSelection
    clearEmptyRunMessage()
    clearQueueWarningMessage()
    isEnqueueingAll = true
    if !isRunning && !isProcessing && pendingJobs.isEmpty { resetProgressCounters() }
    let gen = generation
    runBulkExportTask(
      generation: gen,
      logTag: "startExportCollectionsSelection",
      emptyDoneMessage: { "Everything in the selection is already exported." },
      partialScanWarning: {
        "Couldn't scan every item in the selection. Continuing with the photos already queued."
      },
      body: { [weak self] in
        guard let self else { return .stale }
        // Favorites — modelled as a 0-or-1 element pass so the helper handles
        // the cancellation check + outcome merge identically to the other passes.
        let favorites: [Bool] = buckets.includesFavorites ? [true] : []
        let favResult = try await self.runBulkEnqueueLoop(
          items: favorites, generation: gen
        ) { _ in
          try await self.enqueueCollection(
            selection: .favorites, scope: .favorites,
            selectionMode: selection, generation: gen)
        }
        guard favResult.completed else { return .stale }
        let albumsResult = try await self.runBulkEnqueueLoop(
          items: buckets.albumIds, generation: gen, startingFrom: favResult.totals
        ) { albumId in
          try await self.enqueueCollection(
            selection: .album(collectionId: albumId),
            scope: .album(collectionId: albumId),
            selectionMode: selection, generation: gen)
        }
        guard albumsResult.completed else { return .stale }
        let sharedResult = try await self.runBulkEnqueueLoop(
          items: buckets.sharedAlbumIds, generation: gen, startingFrom: albumsResult.totals
        ) { sharedId in
          try await self.enqueueCollection(
            selection: .sharedAlbum(collectionId: sharedId),
            scope: .sharedAlbum(collectionId: sharedId),
            selectionMode: selection, generation: gen)
        }
        return sharedResult.completed ? .completed(sharedResult.totals) : .stale
      }
    )
  }

  /// Accumulates the result of one or more `runBulkEnqueueLoop` passes so the
  /// outer `runBulkExportTask` can decide whether to surface an "already done"
  /// message after a clean run. `sawUnauthorized` is sticky — once any iteration
  /// reports it, suppress the empty-run message because the user genuinely
  /// can't tell whether all their items are done or simply unreachable.
  private struct BulkExportTotals: Equatable {
    var totalEnqueued: Int = 0
    var sawUnauthorized: Bool = false
  }

  /// Outcome of a bulk-export body. `.completed(totals)` triggers the helper's
  /// empty/done message dispatch on zero-enqueue, then `processQueueIfNeeded()`.
  /// `.completedWithCustomMessage` is for bodies that have set their own user
  /// message (e.g. `enqueueBulkAlbumExport`'s "folder no longer exists" branch)
  /// — the helper skips the message dispatch but still runs the queue. `.stale`
  /// short-circuits without finalizing because a generation check failed
  /// mid-body and a `cancelAndClear` (or equivalent) has already finalized
  /// whatever run was in flight.
  private enum BulkExportOutcome {
    case completed(BulkExportTotals)
    case completedWithCustomMessage
    case stale
  }

  /// Owns the bulk-export Task scaffolding every multi-item dispatcher
  /// (`startExportAll`, `startExportTimelineSelection`,
  /// `startExportCollectionsSelection`, `enqueueBulkAlbumExport`) was
  /// duplicating: the `Task { [weak self] in }` wrapper, the
  /// `isEnqueueingAll = false` teardown on every exit path, the success
  /// finalize (empty/done message + `processQueueIfNeeded()`), and the
  /// partial-failure recovery on throw (queue warning + `partialBulkScan` +
  /// drain if any jobs already queued; otherwise finalize as failed).
  ///
  /// Callers supply just (a) the bulk-loop body that does the enqueue work
  /// and returns `BulkExportOutcome`, (b) the empty/done message factory used
  /// when nothing was enqueued, and (c) the partial-scan warning factory used
  /// when the body throws after partial progress. Issue #67 item 5.
  ///
  /// Cancellation is the body's responsibility: capture `gen`, call
  /// `isCurrent(gen)` after every `await`, return `.stale` if a check fails.
  /// The helper's outer guard catches staleness *before* the body runs.
  private func runBulkExportTask(
    generation gen: Int,
    logTag: String,
    emptyDoneMessage: @escaping @MainActor () -> String,
    partialScanWarning: @escaping @MainActor () -> String,
    body: @escaping @MainActor () async throws -> BulkExportOutcome
  ) {
    Task { [weak self] in
      guard let self, self.isCurrent(gen) else {
        self?.isEnqueueingAll = false
        return
      }
      do {
        let outcome = try await body()
        switch outcome {
        case .stale:
          self.isEnqueueingAll = false
        case .completed(let totals):
          self.isEnqueueingAll = false
          if totals.totalEnqueued == 0 && !totals.sawUnauthorized {
            self.setEmptyRunMessage(emptyDoneMessage())
          }
          self.processQueueIfNeeded()
        case .completedWithCustomMessage:
          self.isEnqueueingAll = false
          self.processQueueIfNeeded()
        }
      } catch {
        self.isEnqueueingAll = false
        self.logger.error(
          "\(logTag, privacy: .public) failed: \(String(describing: error), privacy: .public)"
        )
        // Partial-failure recovery: if any jobs already landed in the queue,
        // drain them and surface a warning + flag the run as `partialBulkScan`
        // so AutoSync's dirty-flag bookkeeping survives the partial scan.
        // Otherwise finalize the active run (if any) as failed.
        if !self.pendingJobs.isEmpty {
          self.setQueueWarningMessage(partialScanWarning())
          self.activeRunBookkeeping?.partialBulkScan = true
          self.processQueueIfNeeded()
        } else {
          self.finalizeActiveRun(result: .failed, cancelReason: nil)
        }
      }
    }
  }

  /// Drives one homogeneous enqueue loop with generation-aware cancellation.
  /// Each iteration calls `enqueue(item)` and merges the result into the
  /// returned totals. `completed == false` means the loop bailed early on a
  /// stale `isCurrent(gen)` check; the caller should propagate as
  /// `BulkExportOutcome.stale`. Multi-bucket dispatchers chain multiple
  /// passes by feeding the prior pass's totals into `startingFrom`.
  private func runBulkEnqueueLoop<Item>(
    items: [Item],
    generation gen: Int,
    startingFrom seed: BulkExportTotals = .init(),
    enqueue: (Item) async throws -> EnqueueOutcome
  ) async throws -> (totals: BulkExportTotals, completed: Bool) {
    var totals = seed
    for item in items {
      let outcome = try await enqueue(item)
      guard isCurrent(gen) else { return (totals, false) }
      switch outcome {
      case .enqueued(let count): totals.totalEnqueued += count
      case .alreadyComplete: break
      case .unauthorized: totals.sawUnauthorized = true
      }
    }
    return (totals, true)
  }

  /// Where a bulk-album export draws its album-id list from. `.allAlbums` walks the
  /// whole tree; `.allSharedAlbums` walks the flat top-level shared-album list;
  /// `.folder` walks one folder's subtree (and short-circuits with a "folder no
  /// longer exists" message if the id can't be found); `.explicitIds` uses the
  /// caller-supplied list as-is.
  ///
  /// `placementKind` controls which placement family each batch member resolves
  /// to. Only `.allSharedAlbums` produces `.sharedAlbum`; folder and explicit-id
  /// sources are user-album-only by design (folders don't contain shared albums;
  /// the multi-select UI for shared albums isn't a feature today).
  private enum BulkAlbumSource {
    case allAlbums
    case allSharedAlbums
    case folder(folderId: String)
    case explicitIds([String])

    var placementKind: ExportPlacement.Kind {
      switch self {
      case .allSharedAlbums: return .sharedAlbum
      case .allAlbums, .folder, .explicitIds: return .album
      }
    }

    func selection(for collectionId: String) -> LibrarySelection {
      switch placementKind {
      case .sharedAlbum: return .sharedAlbum(collectionId: collectionId)
      default: return .album(collectionId: collectionId)
      }
    }

    func scope(for collectionId: String) -> PhotoFetchScope {
      switch placementKind {
      case .sharedAlbum: return .sharedAlbum(collectionId: collectionId)
      default: return .album(collectionId: collectionId)
      }
    }
  }

  /// Shared driver for the three bulk-album export entry points
  /// (`startExportAllAlbums`, `startExportFolder`, `startExportAlbums`). Owns the
  /// guards, generation tracking, partial-failure recovery, and the messaging
  /// matrix. Album-id resolution is deferred into the run Task — every source
  /// dereferences `self.photoLibraryService` from main-actor context, so no
  /// non-Sendable closure capture crosses an actor boundary.
  private func enqueueBulkAlbumExport(
    source: BulkAlbumSource,
    logTag: String,
    emptyMessage: String,
    allDoneMessage: String,
    selectionOverride: ExportVersionSelection? = nil
  ) {
    guard !isImporting else {
      logger.warning("\(logTag, privacy: .public) ignored: import in progress")
      return
    }
    guard canExportCollection else {
      logger.error(
        "\(logTag, privacy: .public) ignored: collection store state=\(String(describing: self.collectionExportRecordStore.state), privacy: .public)"
      )
      return
    }
    guard !isEnqueueingAll else { return }
    let selectionMode = selectionOverride ?? versionSelection
    clearEmptyRunMessage()
    clearQueueWarningMessage()
    isEnqueueingAll = true
    if !isRunning && !isProcessing && pendingJobs.isEmpty { resetProgressCounters() }
    let gen = generation
    runBulkExportTask(
      generation: gen,
      logTag: logTag,
      // Body owns the empty/done message because the variant depends on whether
      // any albums were *resolved* (`emptyMessage`) vs all resolved are already
      // done (`allDoneMessage`) — a distinction the helper can't see from
      // `BulkExportTotals` alone.
      emptyDoneMessage: { "" },
      partialScanWarning: {
        "Couldn't list every album. Continuing with the photos already queued."
      },
      body: { [weak self] in
        guard let self else { return .stale }
        let albumIds: [String]
        switch source {
        case .allAlbums:
          let tree = try self.photoLibraryService.fetchCollectionTree()
          albumIds = PhotoCollectionDescriptor.albumLocalIds(in: tree)
        case .allSharedAlbums:
          let tree = try self.photoLibraryService.fetchCollectionTree()
          albumIds = PhotoCollectionDescriptor.sharedAlbumLocalIds(in: tree)
        case .folder(let folderId):
          let tree = try self.photoLibraryService.fetchCollectionTree()
          guard let folder = PhotoCollectionDescriptor.findFolder(id: folderId, in: tree) else {
            // Folder vanished between guard-pass and lookup. Surface the
            // dedicated message and signal the helper to skip its empty/done
            // dispatch. Symmetric with the other body exits: any future
            // awaitable `runExport(context:)` wiring for folder runs still
            // gets the `processQueueIfNeeded()` finalize via the helper.
            self.setEmptyRunMessage("That folder no longer exists.")
            return .completedWithCustomMessage
          }
          albumIds = PhotoCollectionDescriptor.albumLocalIds(under: folder)
        case .explicitIds(let ids):
          albumIds = ids
        }
        let result = try await self.runBulkEnqueueLoop(items: albumIds, generation: gen) { id in
          try await self.enqueueCollection(
            selection: source.selection(for: id),
            scope: source.scope(for: id),
            selectionMode: selectionMode,
            generation: gen
          )
        }
        guard result.completed else { return .stale }
        if result.totals.totalEnqueued == 0 && !result.totals.sawUnauthorized {
          self.setEmptyRunMessage(albumIds.isEmpty ? emptyMessage : allDoneMessage)
        }
        return .completedWithCustomMessage
      }
    )
  }

  /// Starts an export of a single iCloud shared album. Mirrors `startExportAlbum` but
  /// drives the `.sharedAlbum` enqueue branch so the resolved placement lands under
  /// `Collections/Shared Albums/`. Shared albums are excluded from "Export All Albums";
  /// users export them one at a time.
  func startExportSharedAlbum(collectionId: String) {
    guard !isImporting else {
      logger.warning("startExportSharedAlbum ignored: import in progress")
      return
    }
    guard canExportCollection else {
      logger.error(
        "startExportSharedAlbum ignored: collection store state=\(String(describing: self.collectionExportRecordStore.state), privacy: .public)"
      )
      return
    }
    let selection = versionSelection
    clearEmptyRunMessage()
    clearQueueWarningMessage()
    if !isRunning && !isProcessing && pendingJobs.isEmpty { resetProgressCounters() }
    let gen = generation
    Task { [weak self] in
      guard let self, self.isCurrent(gen) else { return }
      do {
        let outcome = try await enqueueCollection(
          selection: .sharedAlbum(collectionId: collectionId),
          scope: .sharedAlbum(collectionId: collectionId),
          selectionMode: selection,
          generation: gen
        )
        guard self.isCurrent(gen) else { return }
        switch outcome {
        case .enqueued, .unauthorized:
          break
        case .alreadyComplete:
          setEmptyRunMessage("This shared album is already exported.")
        }
        processQueueIfNeeded()
      } catch {
        logger.error(
          "Failed to enqueue shared-album export: \(String(describing: error), privacy: .public)"
        )
      }
    }
  }

  /// Starts an export of a single user album by `collectionLocalIdentifier`.
  func startExportAlbum(collectionId: String) {
    guard !isImporting else {
      logger.warning("startExportAlbum ignored: import in progress")
      return
    }
    guard canExportCollection else {
      logger.error(
        "startExportAlbum ignored: collection store state=\(String(describing: self.collectionExportRecordStore.state), privacy: .public)"
      )
      return
    }
    let selection = versionSelection
    clearEmptyRunMessage()
    clearQueueWarningMessage()
    if !isRunning && !isProcessing && pendingJobs.isEmpty { resetProgressCounters() }
    let gen = generation
    Task { [weak self] in
      guard let self, self.isCurrent(gen) else { return }
      do {
        let outcome = try await enqueueCollection(
          selection: .album(collectionId: collectionId),
          scope: .album(collectionId: collectionId),
          selectionMode: selection,
          generation: gen
        )
        guard self.isCurrent(gen) else { return }
        switch outcome {
        case .enqueued, .unauthorized:
          break
        case .alreadyComplete:
          setEmptyRunMessage("This album is already exported.")
        }
        processQueueIfNeeded()
      } catch {
        logger.error(
          "Failed to enqueue album export: \(String(describing: error), privacy: .public)"
        )
      }
    }
  }

  /// Resolves the placement for a collection selection and enqueues every asset that
  /// isn't already `.done` for that placement. Mirrors `enqueueMonth` on the timeline
  /// side; the only differences are the placement source (resolver vs synthetic
  /// `.timeline(...)`), the fetch scope, and the record-store the existence check
  /// reads from.
  @discardableResult
  private func enqueueCollection(
    selection: LibrarySelection,
    scope: PhotoFetchScope,
    selectionMode: ExportVersionSelection,
    generation gen: Int
  ) async throws -> EnqueueOutcome {
    try throwIfCancelledOrStale(gen)
    guard photoLibraryService.isAuthorized else { return .unauthorized }

    // Resolve the placement. For `.album` and `.sharedAlbum`, the resolver needs the
    // collection tree to find the descriptor and any colliding siblings; for
    // `.favorites` the resolver returns a fixed placement.
    let collections: [PhotoCollectionDescriptor]
    switch selection {
    case .album, .sharedAlbum:
      collections = try photoLibraryService.fetchCollectionTree()
    default:
      collections = []
    }
    let existingPlacements = collectionExportRecordStore.placements
      .values.map { $0 }
    let resolver = ExportPlacementResolver()
    let placement = try resolver.placement(
      for: selection,
      collections: collections,
      existingPlacements: Array(existingPlacements)
    )

    // Persist the placement metadata so subsequent runs can match on the same
    // (kind, collectionLocalIdentifier, displayPathHash8) triple. `upsertPlacement` is a
    // no-op for `.timeline` kinds (which the collection store rejects); collection-side
    // kinds (`.favorites`, `.album`, `.sharedAlbum`) all land here.
    collectionExportRecordStore.upsertPlacement(placement)

    let assets = try await photoLibraryService.fetchAssets(in: scope, mediaType: nil)
    try throwIfCancelledOrStale(gen)
    let newJobs = ExportJobPlanner.plan(
      assets: assets, placement: placement, selection: selectionMode,
      isExported: {
        collectionExportRecordStore.isExported(
          asset: $0, placement: placement, selection: selectionMode)
      },
      shouldSkipForRetry: { skipForAutoSyncRetry(asset: $0, placement: $1, selection: $2) })
    queueCoordinator.enqueue(newJobs)
    logger.info(
      "Enqueued \(newJobs.count) assets for export to \(placement.relativePath, privacy: .public)"
    )
    return newJobs.isEmpty ? .alreadyComplete : .enqueued(newJobs.count)
  }

  func cancelAndClear() {
    logger.info("Cancelling current export and clearing queue due to destination change")
    teardownActiveWork()
    finalizeActiveRun(result: .cancelled, cancelReason: .userCancelled)
  }

  /// User confirmed a manual export while an AutoSync run was active. Plan
  /// §"Phase 4": "the automatic run is superseded with
  /// `cancelReason: .supersededByManualRun`. After the manual run finishes,
  /// the auto-sync reducer re-evaluates and schedules another run if work
  /// is still pending." Resolves the active run as `.superseded` so AutoSync
  /// knows not to clear dirty state (the run didn't actually complete).
  func supersedeForManualRun() {
    logger.info("Superseding active auto-sync run for manual export")
    teardownActiveWork()
    finalizeActiveRun(result: .superseded, cancelReason: .supersededByManualRun)
  }

  /// Drive-unmount equivalent of `cancelAndClear()`. Stops starting new jobs and clears
  /// in-memory pending work, but resolves the active run as transient
  /// (`cancelReason: .destinationUnavailable`) rather than user-cancelled. The AutoSync
  /// state machine treats `.destinationUnavailable` as "resume when the drive comes
  /// back" rather than "this run failed."
  ///
  /// MVP scope: identical cleanup to `cancelAndClear` minus the cancel-reason change.
  /// Phase 0b adds advisory-lock release; persistence of accumulated dirty state lands
  /// when AutoSyncManager wires up. An in-flight `PHAssetResourceManager.writeData` may
  /// still complete or fail because there is no cancellation plumbing for that path —
  /// the in-flight write will surface as a transient failure on the next
  /// reconciliation.
  func interruptForDestinationUnavailable() {
    logger.info("Interrupting current export — destination unavailable")
    teardownActiveWork()
    finalizeActiveRun(result: .interrupted, cancelReason: .destinationUnavailable)
  }

  /// Common in-memory teardown shared by `cancelAndClear` and
  /// `interruptForDestinationUnavailable`. Removes any in-progress variant from the
  /// correct record store, then zeros queue + run + counter state. The call sites differ
  /// only in their log line and the `finalizeActiveRun` arguments.
  private func teardownActiveWork() {
    if let inFlightId = currentJobAssetId, let inFlightVariant = currentJobVariant,
      let inFlightPlacement = currentJobPlacement
    {
      // The router's removeInProgressVariant is a no-op when the variant is not
      // `.inProgress`, so the cross-store check that used to live here is baked into
      // the dispatch.
      recordStoreRouter.removeInProgressVariant(
        assetId: inFlightId, placement: inFlightPlacement, variant: inFlightVariant)
    }
    currentJobAssetId = nil
    currentJobVariant = nil
    currentJobPlacement = nil
    queueCoordinator.bumpGeneration()
    queueCoordinator.teardownQueue()
    queueCoordinator.resetProgressCounters()
    isEnqueueingAll = false
    progressState.currentAssetFilename = nil
    clearEmptyRunMessage()
    clearQueueWarningMessage()
  }

  // MARK: - Empty-run message

  /// Shows a transient message in the toolbar's progress slot for `emptyRunMessageDuration`.
  /// Replaces any previously-shown message and resets the auto-clear timer.
  ///
  /// Auto-sync (`.background` visibility) runs suppress this — plan §"Phase 3":
  /// "auto-sync empty runs update lastRunSummary but do not show toolbar
  /// empty-run messages." The user-visible surface for those is
  /// AutoSyncManager.lastRunSummary, rendered in Settings → Auto Export.
  private func setEmptyRunMessage(_ message: String) {
    if activeRunContext?.visibility == .background {
      return
    }
    progressState.emptyRunMessage = message
    emptyRunMessageTask?.cancel()
    let duration = Self.emptyRunMessageDuration
    emptyRunMessageTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
      guard !Task.isCancelled else { return }
      await MainActor.run { [weak self] in
        self?.progressState.emptyRunMessage = nil
        self?.emptyRunMessageTask = nil
      }
    }
  }

  /// Clears the empty-run message immediately. Called by every code path that invalidates
  /// it: any new `startExport*`, version-selection change, `cancelAndClear`.
  private func clearEmptyRunMessage() {
    progressState.emptyRunMessage = nil
    emptyRunMessageTask?.cancel()
    emptyRunMessageTask = nil
  }

  /// Clears the queue-warning message. Called from every path that invalidates it: a fresh
  /// `startExport*` (the new run owns the warning slot) and `cancelAndClear`. The message
  /// itself is not auto-expiring — it persists until the queue it describes drains or the
  /// user kicks off something new.
  private func clearQueueWarningMessage() {
    progressState.queueWarningMessage = nil
  }

  private func setQueueWarningMessage(_ message: String) {
    progressState.queueWarningMessage = message
  }

  func pause() {
    guard canTogglePause else { return }
    queueCoordinator.pause()
  }

  func resume() {
    queueCoordinator.resume()
  }

  func clearPending() {
    _ = queueCoordinator.clearPending()
  }

  // MARK: - Queue Handling

  /// Scans the month and returns the enqueue outcome. Callers use the outcome to decide
  /// whether to surface the "already exported" toolbar message.
  @discardableResult
  // Phase 4b lifted the per-placement queue-counter mutation into
  // `ExportQueueCoordinator.enqueue`. The three enqueue methods retain only the
  // PhotoKit fetch + `ExportJobPlanner.plan` call.
  private func enqueueMonth(
    year: Int, month: Int, selection: ExportVersionSelection, generation gen: Int
  ) async throws -> EnqueueOutcome {
    try throwIfCancelledOrStale(gen)
    guard photoLibraryService.isAuthorized else { return .unauthorized }
    let assets = try await photoLibraryService.fetchAssets(year: year, month: month)
    try throwIfCancelledOrStale(gen)
    let placement = ExportPlacement.timeline(year: year, month: month)
    let newJobs = ExportJobPlanner.plan(
      assets: assets, placement: placement, selection: selection,
      isExported: { exportRecordStore.isExported(asset: $0, selection: selection) },
      shouldSkipForRetry: { skipForAutoSyncRetry(asset: $0, placement: $1, selection: $2) })
    queueCoordinator.enqueue(newJobs)
    logger.info("Enqueued \(newJobs.count) assets for export for \(year)-\(month)")
    return newJobs.isEmpty ? .alreadyComplete : .enqueued(newJobs.count)
  }

  @discardableResult
  private func enqueueYear(
    year: Int, selection: ExportVersionSelection, generation gen: Int
  ) async throws -> EnqueueOutcome {
    try throwIfCancelledOrStale(gen)
    guard photoLibraryService.isAuthorized else { return .unauthorized }
    let assets = try await photoLibraryService.fetchAssets(year: year, month: nil)
    try throwIfCancelledOrStale(gen)
    let newJobs = ExportJobPlanner.planTimelineYear(
      assets: assets, year: year, selection: selection,
      isExported: { exportRecordStore.isExported(asset: $0, selection: selection) },
      shouldSkipForRetry: { skipForAutoSyncRetry(asset: $0, placement: $1, selection: $2) })
    queueCoordinator.enqueue(newJobs)
    logger.info("Enqueued \(newJobs.count) assets for export for year \(year)")
    return newJobs.isEmpty ? .alreadyComplete : .enqueued(newJobs.count)
  }

  /// Runs an export and returns its terminal summary. Wraps the existing fire-and-forget
  /// `start*` methods with single-active-run ownership: at most one `runExport` is in
  /// flight per `ExportManager`, and the await resolves when the run reaches a terminal
  /// state — completed, cancelled, or failed.
  ///
  /// MVP scope coverage: `.timelineFullLibrary`, `.favoritesFull`, `.allAlbumsFull` map
  /// to the existing manual-export entry points. Targeted asset-id scopes
  /// (`.timelineAssets`, `.favoritesAssets`, `.allAlbumsAssets`) and the umbrella
  /// `.autoExport` scope land in subsequent Phase 0a slices; for now they resolve
  /// immediately with `.failed` so callers see a deterministic outcome rather than a
  /// hang.
  ///
  /// **Awaiter behavior under pause**: `pause()` while a `runExport` is active leaves
  /// the queue parked and the awaitable suspended until either `resume()` drains the
  /// queue or `cancelAndClear()` / `interruptForDestinationUnavailable()` resolves the
  /// run. Callers that pause mid-run are responsible for unblocking the awaiter.
  func runExport(context: ExportRunContext) async -> ExportRunSummary {
    precondition(
      activeRunContext == nil,
      "runExport called while another run is active; ExportManager has at most one active run"
    )
    return await withCheckedContinuation {
      (continuation: CheckedContinuation<ExportRunSummary, Never>) in
      activeRunContext = context

      // Bookkeeping is captured *after* dispatch because the start* methods call
      // `resetProgressCounters()` synchronously when the queue is idle. Capturing
      // before dispatch would snapshot stale totals from a prior run, producing a
      // negative-clamped delta on the next finalize.
      //
      // The fail-fast guards block dispatch when the manager isn't idle. Without
      // `!hasActiveExportWork`, a fire-and-forget run already in flight would
      // silently no-op the dispatched `start*` (its `isEnqueueingAll` guard returns
      // early) and the awaiter would hang forever.
      switch context.scope {
      case .timelineFullLibrary:
        if !isImporting && canExportTimeline && !hasActiveExportWork {
          startExportAll(selectionOverride: context.selection)
          activeRunBookkeeping = ActiveRunBookkeeping(
            totalJobsEnqueuedAtStart: totalJobsEnqueued,
            totalJobsCompletedAtStart: totalJobsCompleted,
            continuation: continuation
          )
        } else {
          activeRunBookkeeping = ActiveRunBookkeeping(
            totalJobsEnqueuedAtStart: totalJobsEnqueued,
            totalJobsCompletedAtStart: totalJobsCompleted,
            continuation: continuation
          )
          finalizeActiveRun(result: .failed, cancelReason: nil)
        }
      case .favoritesFull:
        if !isImporting && canExportCollection && !hasActiveExportWork {
          startExportFavorites(selectionOverride: context.selection)
          activeRunBookkeeping = ActiveRunBookkeeping(
            totalJobsEnqueuedAtStart: totalJobsEnqueued,
            totalJobsCompletedAtStart: totalJobsCompleted,
            continuation: continuation
          )
        } else {
          activeRunBookkeeping = ActiveRunBookkeeping(
            totalJobsEnqueuedAtStart: totalJobsEnqueued,
            totalJobsCompletedAtStart: totalJobsCompleted,
            continuation: continuation
          )
          finalizeActiveRun(result: .failed, cancelReason: nil)
        }
      case .allAlbumsFull:
        if !isImporting && canExportCollection && !hasActiveExportWork {
          startExportAllAlbums(selectionOverride: context.selection)
          activeRunBookkeeping = ActiveRunBookkeeping(
            totalJobsEnqueuedAtStart: totalJobsEnqueued,
            totalJobsCompletedAtStart: totalJobsCompleted,
            continuation: continuation
          )
        } else {
          activeRunBookkeeping = ActiveRunBookkeeping(
            totalJobsEnqueuedAtStart: totalJobsEnqueued,
            totalJobsCompletedAtStart: totalJobsCompleted,
            continuation: continuation
          )
          finalizeActiveRun(result: .failed, cancelReason: nil)
        }
      case .allSharedAlbumsFull:
        if !isImporting && canExportCollection && !hasActiveExportWork {
          startExportAllSharedAlbums(selectionOverride: context.selection)
          activeRunBookkeeping = ActiveRunBookkeeping(
            totalJobsEnqueuedAtStart: totalJobsEnqueued,
            totalJobsCompletedAtStart: totalJobsCompleted,
            continuation: continuation
          )
        } else {
          activeRunBookkeeping = ActiveRunBookkeeping(
            totalJobsEnqueuedAtStart: totalJobsEnqueued,
            totalJobsCompletedAtStart: totalJobsCompleted,
            continuation: continuation
          )
          finalizeActiveRun(result: .failed, cancelReason: nil)
        }
      case .timelineAssets, .favoritesAssets, .allAlbumsAssets,
        .allSharedAlbumsAssets, .autoExport:
        // Targeted asset-id and autoExport scopes land in subsequent Phase 0a slices.
        activeRunBookkeeping = ActiveRunBookkeeping(
          totalJobsEnqueuedAtStart: totalJobsEnqueued,
          totalJobsCompletedAtStart: totalJobsCompleted,
          continuation: continuation
        )
        finalizeActiveRun(result: .failed, cancelReason: nil)
      }
    }
  }

  /// Resolves the awaitable run's continuation if one is active. Idempotent — second
  /// and later calls are no-ops, so existing run-terminal paths can call this without
  /// worrying about whether they're the first to detect the end. No-op when the run
  /// was started via the existing fire-and-forget `start*` methods (i.e.,
  /// `activeRunContext` is nil).
  private func finalizeActiveRun(
    result: ExportRunResult,
    cancelReason: ExportCancelReason?
  ) {
    guard let context = activeRunContext, let bookkeeping = activeRunBookkeeping else {
      return
    }
    // A natural queue-drain finalize comes in as `.completed`. Two conditions
    // demote it to `.failed`:
    //   1. Any variants failed during this run — callers (AutoSync's retry path,
    //      Export Issues UI) need to distinguish a clean run from one that needs
    //      retry-store inspection.
    //   2. The bulk-enqueue catch block elected to drain a partial queue — the
    //      unreached albums in the batch never got a chance to enqueue, so a
    //      `.completed` summary would over-report what the run actually covered
    //      and `AutoSyncReducer` would clear dirty state for albums that weren't
    //      reconciled.
    // Explicit cancel/interrupt paths keep their incoming result untouched.
    let effectiveResult: ExportRunResult
    if result == .completed
      && (bookkeeping.failedCount > 0 || bookkeeping.partialBulkScan)
    {
      effectiveResult = .failed
    } else {
      effectiveResult = result
    }
    let summary = ExportRunSummary(
      context: context,
      endedAt: Date(),
      enqueuedCount: max(0, totalJobsEnqueued - bookkeeping.totalJobsEnqueuedAtStart),
      completedCount: max(0, totalJobsCompleted - bookkeeping.totalJobsCompletedAtStart),
      failedCount: bookkeeping.failedCount,
      skippedCount: bookkeeping.skippedCount,
      cancelReason: cancelReason,
      result: effectiveResult,
      failures: bookkeeping.failures
    )
    activeRunContext = nil
    activeRunBookkeeping = nil
    // Order matters: send the summary on `completedRunsSubject` *before*
    // resuming the awaiter. AutoSync's manager subscribes to
    // `completedRunsPublisher` and filters to `source == .manual`, so its
    // own AutoSync-sourced runs never reach the manual-clear path either
    // way. But the awaiter dispatches `.autoSyncRunCompleted(summary)`
    // which is also queued behind the in-flight reducer event — and we
    // want the subject emission to land first so that any reordering
    // future-us applies stays self-consistent rather than relying on the
    // continuation-resume / subject-send order to bend a specific way.
    completedRunsSubject.send(summary)
    bookkeeping.continuation.resume(returning: summary)
  }

  /// Forwarder onto the coordinator. Kept as a public method on ExportManager because
  /// existing call sites (`startExport*`, the bulk-album finalize paths, `resume()`)
  /// invoke it by name.
  func processQueueIfNeeded() {
    queueCoordinator.processQueueIfNeeded()
  }

  // The drain loop body (`processNext`) and `updateQueueCount` have moved to
  // `ExportQueueCoordinator`. The manager keeps `queuedCount(year:month:)` because it
  // wraps placement-id resolution.

  /// Reads the queue depth for `(year, month)` by resolving the synthetic timeline
  /// placement id and looking it up in the placement-keyed dict. Existing call sites use
  /// `(year, month)` and stay unchanged.
  func queuedCount(year: Int, month: Int) -> Int {
    let placementId = ExportPlacement.timeline(year: year, month: month).id
    return queueCoordinator.queuedCount(placementId: placementId)
  }

  private func resetProgressCounters() {
    queueCoordinator.resetProgressCounters()
    progressState.currentAssetFilename = nil
  }

  // MARK: - Export Logic

  /// Non-throwing companion to `throwIfCancelledOrStale(_:)`. Returns `true` when the
  /// captured generation is still the active one, i.e. the work has not been superseded
  /// by `bumpGeneration`-equivalent transitions (`cancelAndClear`,
  /// `interruptForDestinationUnavailable`, `supersedeForManualRun`, `cancelImport`).
  /// Note: `clearPending()` only drops queued jobs and does NOT bump generation —
  /// in-flight work that started before `clearPending` keeps its `gen` and finishes
  /// normally. The path that *does* cancel mid-flight is `cancelAndClear`. Use this
  /// helper at non-throwing checkpoints — typically inside escaping closures that
  /// `return` early when the run is stale. Per
  /// `docs/project/archive/software-architecture-improvement-plan.md` "Cross-Cutting
  /// Contracts > Generation / cancellation ownership", these helpers are the seam
  /// the manager's own dispatchers call inline. The Phase-0 storage moved to
  /// `ExportQueueCoordinator` in issue #67 item 2; these are thin forwarders so the
  /// in-module call sites (`guard self.isCurrent(gen)`, `try throwIfCancelledOrStale`)
  /// remain stable.
  func isCurrent(_ gen: Int) -> Bool {
    queueCoordinator.isCurrent(gen)
  }

  func throwIfCancelledOrStale(_ gen: Int) throws {
    try queueCoordinator.throwIfCancelledOrStale(gen)
  }

  private func export(job: ExportJob, generation gen: Int) async {
    var inFlight: (assetId: String, variant: ExportVariant)?
    do {
      try throwIfCancelledOrStale(gen)

      guard let descriptor = photoLibraryService.fetchAssetDescriptor(for: job.assetLocalIdentifier)
      else {
        try throwIfCancelledOrStale(gen)
        recordVariantFailed(
          assetId: job.assetLocalIdentifier, placement: job.placement, variant: .original,
          sentinelMessage: "Asset not found", category: .assetMissing, at: Date())
        logger.error(
          "Asset not found for id: \(job.assetLocalIdentifier, privacy: .public)")
        return
      }
      logger.debug(
        "Export begin id: \(descriptor.id, privacy: .public) type: \(descriptor.mediaType.rawValue) hasAdjustments: \(descriptor.hasAdjustments) dims: \(descriptor.pixelWidth)x\(descriptor.pixelHeight)"
      )

      guard let scopedURL = exportDestination.beginScopedAccess() else {
        throw NSError(
          domain: "Export", code: 1,
          userInfo: [
            NSLocalizedDescriptionKey: "Failed to access export folder (security scope)"
          ])
      }
      logger.debug("Begin scoped access for: \(scopedURL.path, privacy: .public)")
      defer { exportDestination.endScopedAccess(for: scopedURL) }

      // Phase 3 unifies the destination resolution: every job's placement carries its
      // own relativePath (e.g. "2025/02/" for timeline, "Collections/Albums/Trip/" for
      // an album). The destination resolver applies escape-protection regardless of
      // kind, so timeline and collection jobs flow through one path.
      let destDir = try exportDestination.urlForRelativeDirectory(
        job.placement.relativePath, createIfNeeded: true)
      let relPath = job.placement.relativePath

      let resources = photoLibraryService.resources(for: descriptor.id)
      let resourceSummary = resources.map { "\($0.type.rawValue):\($0.originalFilename)" }.joined(
        separator: ", ")
      logger.debug("Asset resources: \(resourceSummary, privacy: .public)")

      // Look up the existing record for the *current placement* (not cross-placement).
      // Timeline jobs read from the timeline store; collection jobs read from the
      // collection store; the router selects the right one. The reuse-source copy path
      // (Phase 3.3) consults the *other* store separately to avoid re-fetching from
      // PhotoKit when an asset is already exported elsewhere.
      let existingVariants = recordStoreRouter.variants(
        forAssetId: descriptor.id, placement: job.placement)
      // Synthesize an `ExportRecord` shape for the existing-stem inheritance logic below
      // (which today only accepts `ExportRecord?`). Collection placements don't have
      // year/month, so we use the placement's relPath directly.
      let existingRecord: ExportRecord?
      if !existingVariants.isEmpty {
        let (yr, mo) = job.placement.timelineYearMonth ?? (0, 0)
        existingRecord = ExportRecord(
          id: descriptor.id, year: yr, month: mo, relPath: job.placement.relativePath,
          variants: existingVariants)
      } else {
        existingRecord = nil
      }
      let required = requiredVariants(
        for: descriptor, selection: job.selection,
        policy: job.placement.kind.variantPolicy)
      let missing = required.filter { variant in
        existingRecord?.variants[variant]?.status != .done
      }
      if missing.isEmpty {
        logger.debug(
          "All required variants already .done for id: \(descriptor.id, privacy: .public)")
        return
      }

      // Always attempt original before edited so edited can inherit the chosen group stem.
      let orderedVariants: [ExportVariant] = [.original, .edited].filter { missing.contains($0) }

      // Whether `.original` is paired with `.edited` for this asset. When true, the
      // `.original` file is written at `<stem>_orig.<origExt>`; otherwise at the bare stem.
      let pairOriginalWithSuffix = required.contains(.edited)

      var groupStem = ExportDestinationResolver.inheritedGroupStem(
        from: existingRecord, descriptor: descriptor, resources: resources)

      // Pre-allocate a paired stem when we will write both variants in this run with no
      // inherited stem to anchor the pair. This guarantees the edited and `_orig` companion
      // land on the same stem instead of splitting via per-file uniqueFileURL collisions.
      if groupStem == nil, orderedVariants == [.original, .edited],
        let originalRes = ResourceSelection.selectOriginalResource(
          from: resources, mediaType: descriptor.mediaType)
      {
        let editedProducer = ResourceSelection.selectEditedProducer(
          from: resources, mediaType: descriptor.mediaType, descriptor: descriptor)
        if let editedFilename = editedProducer.originalFilename {
          let baseStem = ExportDestinationResolver.splitFilename(originalRes.originalFilename).base
          let originalExt = (originalRes.originalFilename as NSString).pathExtension
          let editedExt = (editedFilename as NSString).pathExtension
          groupStem = destinationResolver.allocatePairedGroupStem(
            baseStem: baseStem, editedExt: editedExt, originalExt: originalExt, destDir: destDir)
        }
      }

      for variant in orderedVariants {
        do {
          try throwIfCancelledOrStale(gen)
          let nextGroupStem = try await exportSingleVariant(
            variant: variant,
            descriptor: descriptor,
            resources: resources,
            destDir: destDir,
            relPath: relPath,
            job: job,
            groupStem: groupStem,
            pairOriginalWithSuffix: pairOriginalWithSuffix,
            generation: gen,
            inFlight: &inFlight
          )
          if let nextGroupStem { groupStem = nextGroupStem }
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          logger.error(
            "Variant \(variant.rawValue, privacy: .public) failed for id: \(descriptor.id, privacy: .public) error: \(String(describing: error), privacy: .public)"
          )
          recordVariantFailed(
            assetId: descriptor.id, placement: job.placement, variant: variant,
            error: error, at: Date())
          inFlight = nil
        }
      }

      // Issue #22 fallback: when the user asked for `.edited` only (no
      // `_orig` companion), but Photos refused the edited resource, write the
      // original to the `_orig` path. The natural-stem slot stays free, so a
      // future run can still write the edited file if Photos' state changes.
      // `isExported(asset:selection:)` recognises this pair and stops
      // re-queueing the asset every run.
      let currentVariantsForFallback = currentVariants(
        assetId: descriptor.id, placement: job.placement)
      if ExportCompletionPolicy.shouldRunEditedFallback(
        variants: currentVariantsForFallback, required: required)
      {
        await runEditedFallbackOriginal(
          descriptor: descriptor, resources: resources, destDir: destDir,
          relPath: relPath, job: job, generation: gen, inFlight: &inFlight)
      }
    } catch is CancellationError {
      logger.info(
        "Export cancelled for id: \(job.assetLocalIdentifier, privacy: .public)")
      if let inFlight, self.isCurrent(gen) {
        recordStoreRouter.removeInProgressVariant(
          assetId: inFlight.assetId, placement: job.placement, variant: inFlight.variant)
      }
    } catch {
      guard self.isCurrent(gen) else { return }
      logger.error(
        "Export failed for id: \(job.assetLocalIdentifier, privacy: .public) error: \(String(describing: error), privacy: .public)"
      )
      // Record the failure against the variant that was actually in flight when the
      // error landed. Falling back to `.original` here used to fabricate a phantom
      // `.failed .original` entry on collection-only `.edited` jobs (collection-export
      // descriptors that only need the edited variant); those jobs would surface a
      // failure on a variant they never attempted to write. The in-flight tuple is
      // populated as soon as `exportSingleVariant` issues the variant-in-progress
      // record and is cleared on success/per-variant catch, so by the time we reach
      // this outer catch it accurately names the variant whose write threw.
      let failedVariant = inFlight?.variant ?? .original
      recordVariantFailed(
        assetId: job.assetLocalIdentifier, placement: job.placement, variant: failedVariant,
        error: error, at: Date())
    }
  }

  /// Forwarder onto `VariantExporter.exportSingleVariant`. The signature is preserved so
  /// existing call sites (the variant loop and the edited-fallback path) don't change
  /// during Phase 3a.
  private func exportSingleVariant(
    variant: ExportVariant,
    descriptor: AssetDescriptor,
    resources: [ResourceDescriptor],
    destDir: URL,
    relPath: String,
    job: ExportJob,
    groupStem: String?,
    pairOriginalWithSuffix: Bool,
    generation gen: Int,
    inFlight: inout (assetId: String, variant: ExportVariant)?
  ) async throws -> String? {
    try await variantExporter.exportSingleVariant(
      variant: variant, descriptor: descriptor, resources: resources,
      destDir: destDir, relPath: relPath, job: job,
      groupStem: groupStem, pairOriginalWithSuffix: pairOriginalWithSuffix,
      generation: gen, inFlight: &inFlight)
  }

  // Destination resolution (URL + filename allocation, paired-stem allocation, collision
  // suffixing, inherited group stem) lives on `ExportDestinationResolver`. Callers go
  // through `self.destinationResolver` or the static helpers
  // `ExportDestinationResolver.splitFilename` / `ExportDestinationResolver.inheritedGroupStem`.

  // MARK: - Edited-unavailable fallback (issue #22)

  /// The decision logic for running this fallback now lives in
  /// `ExportCompletionPolicy.shouldRunEditedFallback`. The call site at the end of the
  /// variant loop (above) reads the current variants once and hands them to the policy.

  /// Writes the original variant to a `<stem>_orig.<originalExt>` slot. Used
  /// when the edited variant was unavailable so the user still gets the bytes
  /// for this asset. Reuses the same `_orig` naming the include-originals
  /// feature uses, so a future run that successfully retrieves the edit can
  /// write `<stem>.<editedExt>` without colliding.
  ///
  /// Errors here are logged but do not propagate or rewrite the
  /// `editedResourceUnavailable` failure — the user keeps the original
  /// failure context in the diagnostic report.
  private func runEditedFallbackOriginal(
    descriptor: AssetDescriptor,
    resources: [ResourceDescriptor],
    destDir: URL,
    relPath: String,
    job: ExportJob,
    generation gen: Int,
    inFlight: inout (assetId: String, variant: ExportVariant)?
  ) async {
    guard
      let originalRes = ResourceSelection.selectOriginalResource(
        from: resources, mediaType: descriptor.mediaType)
    else {
      logger.info(
        "Edited fallback skipped: no original-side resource for id: \(descriptor.id, privacy: .public)"
      )
      return
    }
    let baseStem = ExportDestinationResolver.splitFilename(originalRes.originalFilename).base
    let originalExt = (originalRes.originalFilename as NSString).pathExtension
    let stem = destinationResolver.allocateUnusedOrigStem(
      baseStem: baseStem, originalExt: originalExt, destDir: destDir)
    do {
      try throwIfCancelledOrStale(gen)
      _ = try await exportSingleVariant(
        variant: .original,
        descriptor: descriptor,
        resources: resources,
        destDir: destDir,
        relPath: relPath,
        job: job,
        groupStem: stem,
        pairOriginalWithSuffix: true,
        generation: gen,
        inFlight: &inFlight
      )
      // Mark `.edited` with the explicit fallback sentinel so future runs
      // recognise the asset as covered without relying on the ambiguous
      // `_orig` filename shape. Overwrites the generic
      // `editedResourceUnavailableMessage` the variant loop recorded.
      recordVariantFailed(
        assetId: descriptor.id, placement: job.placement, variant: .edited,
        sentinelMessage: ExportVariantRecovery.editedUnavailableOriginalBackedUpMessage,
        category: .resourceMissing, at: Date())
      logger.info(
        "Edited fallback wrote original for id: \(descriptor.id, privacy: .public) stem: \(stem, privacy: .public)"
      )
    } catch is CancellationError {
      logger.info("Edited fallback cancelled for id: \(descriptor.id, privacy: .public)")
    } catch {
      logger.error(
        "Edited fallback failed for id: \(descriptor.id, privacy: .public) error: \(String(describing: error), privacy: .public)"
      )
      // `exportSingleVariant` records `.inProgress` for `.original` before the
      // atomic move; if the move (or any later step) throws, that
      // `.inProgress` is still in the store. Without this transition, the
      // record lies about work in flight for the rest of the session — the
      // diagnostic report shows a phantom "in-progress" row, the sidebar
      // counters skew, and the next launch's `recoverInProgressVariants()`
      // finally rewrites it to `.failed`. Record the failure here so the
      // store reflects what actually happened. The asset is still re-queued
      // on the next run because `.original` is now `.failed` (not `.done`).
      recordVariantFailed(
        assetId: descriptor.id, placement: job.placement, variant: .original,
        error: error, at: Date())
      inFlight = nil
    }
  }

  /// Variants currently recorded for the asset under `placement`. Pure forwarder to
  /// `RecordStoreRouter.variants(forAssetId:placement:)` — kept for call-site stability
  /// across a refactor that has multiple readers (the variant loop, the cancellation
  /// path, the fallback policy lookup). Inlining would touch all of them at once and
  /// obscure the router seam in this PR; the wrapper is on the deletion list for a
  /// later cleanup phase.
  private func currentVariants(
    assetId: String, placement: ExportPlacement
  ) -> [ExportVariant: ExportVariantRecord] {
    recordStoreRouter.variants(forAssetId: assetId, placement: placement)
  }

  // `allocateUnusedOrigStem` and `inheritedGroupStem` moved to ExportDestinationResolver.

  // MARK: - Helpers

  // `isSourceSideCopyError` moved to `VariantExporter` along with the reuse-source copy
  // path (Phase 3a).

  // MARK: - VariantExporter.Host conformance

  // Generation seam (`isCurrent` + `throwIfCancelledOrStale`) and the sentinel-message
  // `recordVariantFailed` overload are already declared above; the protocol witness
  // table picks them up here.

  func setCurrentAssetFilename(_ name: String?) {
    progressState.currentAssetFilename = name
  }

  func setCurrentJobVariant(_ variant: ExportVariant?) {
    currentJobVariant = variant
  }

  func clearRenderActivity() {
    progressState.renderActivity = nil
  }

  // The rendered-media bridge that lived here in Phase 3a is gone — `VariantExporter`
  // now holds the renderer directly. ExportManager still constructs the renderer (so
  // it can wire the `renderActivity` callback) but no longer invokes it.

  // MARK: - ExportQueueCoordinator.Host conformance

  /// `generation` and `isCurrent(_:)` are already declared above; the protocol witness
  /// picks them up here. `isEnqueueingAll` is the existing stored property.

  /// Drives the per-job export pipeline on behalf of the coordinator. Wraps the
  /// existing `export(job:gen:)` body so the coordinator's drain loop doesn't need to
  /// know about it.
  func performExport(job: ExportJob, generation gen: Int) async {
    await export(job: job, generation: gen)
  }

  /// Called by the coordinator's drain loop on the "queue empty after a job ran" edge.
  /// Mirrors the pre-Phase-4b `processNext` empty-branch finalize.
  func didDrainQueue() {
    logger.info("Export queue drained")
    finalizeActiveRun(result: .completed, cancelReason: nil)
  }

  /// Set placement BEFORE assetId per the plan's ordering rule — any cancellation
  /// cleanup that observes `currentJobAssetId` must also see the matching
  /// `currentJobPlacement`. Reset `currentJobVariant` because the variant write hasn't
  /// started yet.
  func setCurrentJob(_ job: ExportJob) {
    currentJobPlacement = job.placement
    currentJobAssetId = job.assetLocalIdentifier
    currentJobVariant = nil
  }

  func clearCurrentJobIdentifiers() {
    currentJobAssetId = nil
    currentJobVariant = nil
    currentJobPlacement = nil
    progressState.currentAssetFilename = nil
  }

  // MARK: Record-mutation routing

  /// AutoSync retry-eligibility gate: returns `true` when the enqueue path
  /// should *skip* this asset because all required variants are currently
  /// in retry backoff (or hard-blocked needing user action). Called from
  /// each of the three enqueue helpers; bumps `skippedCount` as a side
  /// effect so the call site can simply `if skipForAutoSync(...) { continue }`.
  /// No-op for manual runs (`activeRunContext?.source != .autoSync`) and
  /// when the closure isn't installed.
  private func skipForAutoSyncRetry(
    asset: AssetDescriptor, placement: ExportPlacement,
    selection: ExportVersionSelection
  ) -> Bool {
    guard activeRunContext?.source == .autoSync,
      let check = autoSyncEligibilityCheck
    else { return false }
    let required = requiredVariants(
      for: asset, selection: selection, policy: placement.kind.variantPolicy)
    let now = Date()
    let hasEligible = required.contains { variant in
      check(asset.id, placement, variant, now)
    }
    if !hasEligible {
      activeRunBookkeeping?.skippedCount += 1
    }
    return !hasEligible
  }

  private func recordVariantFailed(
    assetId: String, placement: ExportPlacement, variant: ExportVariant,
    failure: ExportFailureSignal, at date: Date
  ) {
    recordStoreRouter.markVariantFailed(
      assetId: assetId, placement: placement, variant: variant,
      error: failure.localizedDescription, at: date)
    activeRunBookkeeping?.failedCount += 1
    activeRunBookkeeping?.failures.append(
      ExportRunFailureDetail(
        assetId: assetId,
        placement: placement,
        variant: variant,
        category: failure.category,
        errorSignature: failure.errorSignature,
        localizedDescription: failure.localizedDescription,
        failedAt: date
      ))
  }

  /// Backwards-compatible overload — call sites that already have an
  /// `Error` instance route through here. The classifier extracts the
  /// `(category, signature, message)` triple.
  private func recordVariantFailed(
    assetId: String, placement: ExportPlacement, variant: ExportVariant,
    error: Error, at date: Date
  ) {
    recordVariantFailed(
      assetId: assetId, placement: placement, variant: variant,
      failure: AutoSyncFailureCategory.classify(error), at: date)
  }

  /// Sentinel-message overload — call sites that synthesize a failure
  /// string with no underlying `Error` (e.g., "Asset not found"). The
  /// caller declares the intended `category` so retry routing is
  /// deterministic; the message is used as both the `errorSignature` and
  /// the user-visible description.
  ///
  /// Declared `internal` (not `private`) so `VariantExporter.Host` can witness this
  /// method. The other two `recordVariantFailed` overloads remain `private` because
  /// they are not part of the Host protocol surface.
  func recordVariantFailed(
    assetId: String, placement: ExportPlacement, variant: ExportVariant,
    sentinelMessage: String, category: AutoSyncFailureCategory, at date: Date
  ) {
    recordVariantFailed(
      assetId: assetId, placement: placement, variant: variant,
      failure: AutoSyncFailureCategory.sentinel(
        category: category, signature: sentinelMessage, message: sentinelMessage),
      at: date)
  }

  // `recordVariantInProgress` and `recordVariantExported` previously lived here as pure
  // forwarders to the router. They became unused once Phase 3a moved the variant write
  // path into `VariantExporter` (the only caller for both) — `VariantExporter` now
  // calls `recordStoreRouter.markVariantInProgress` / `.markVariantExported` directly.
  // Removed in the post-refactor cleanup.

  // `splitFilename` and `uniqueFileURL` moved to ExportDestinationResolver
  // (static + instance respectively).

  // MARK: - Import Existing Backup

  /// Starts the "Import Existing Backup…" flow. Forwarder to the `ImportCoordinator`.
  func startImport() {
    importCoordinator.startImport()
  }

  /// Cancels an in-progress import. Forwarder to the `ImportCoordinator`.
  func cancelImport() {
    importCoordinator.cancelImport()
  }

  // MARK: - ImportCoordinator.Host conformance

  /// Writes the import report back to the manager's `@Published` mirror. Kept as a Host
  /// method (not a sink) because `importResult` is intentionally writable on the
  /// manager — test code resets it directly between consecutive imports.
  func setImportResult(_ result: ImportReport?) {
    importResult = result
  }
}

/// Summary report shown after the import completes.
struct ImportReport: Equatable {
  let matchedCount: Int
  let ambiguousCount: Int
  let unmatchedCount: Int
  let totalScanned: Int
  /// Variants pruned from records because their backing file was missing on disk
  /// (or replaced by a directory, or the variant was a corrupt `.done` with nil
  /// filename). Counts the timeline and collection stores together.
  let prunedVariants: Int
  /// Records removed entirely after their last variant was pruned. Counts the
  /// timeline and collection stores together.
  let prunedRecords: Int

  init(
    matchedCount: Int, ambiguousCount: Int, unmatchedCount: Int, totalScanned: Int,
    prunedVariants: Int = 0, prunedRecords: Int = 0
  ) {
    self.matchedCount = matchedCount
    self.ambiguousCount = ambiguousCount
    self.unmatchedCount = unmatchedCount
    self.totalScanned = totalScanned
    self.prunedVariants = prunedVariants
    self.prunedRecords = prunedRecords
  }
}
