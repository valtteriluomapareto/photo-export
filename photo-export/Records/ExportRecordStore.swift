import Combine
import Foundation
import os

/// Thread-safe-ish store using a serial IO queue for disk operations and in-memory map for queries.
///
/// Persistence design:
/// - Mutations are appended to `export-records.jsonl` (one JSON object per line) under a destination-specific directory.
/// - On configure/load, we fold the JSONL log into `recordsById` and optionally overlay a snapshot `export-records.json` if present.
/// - After N mutations or at app termination, we compact into a canonical snapshot file and truncate the log.
///
/// Schema:
/// - Current records carry per-variant state in `ExportRecord.variants` keyed by `ExportVariant`.
/// - Legacy flat records (single filename/status fields) decode into a synthesized `.original` variant.
/// - On load, any variant left as `.inProgress` is converted to `.failed` with `ExportVariantRecovery.interruptedMessage`
///   because no in-progress state survives app restart.
@MainActor
final class ExportRecordStore: ObservableObject {
  struct Constants {
    static let directoryName = "ExportRecords"
    static let logFileName = "export-records.jsonl"
    static let snapshotFileName = "export-records.json"
    static let compactEveryNMutations = 1000
  }

  private let logger = Logger.app(.exportRecords)
  private let ioQueue = DispatchQueue(
    label: "com.valtteriluoma.photo-export.records-io", qos: .utility)

  private(set) var recordsById: [String: ExportRecord] = [:]

  /// Incrementally-maintained per-`(year, month)` counters that back the public count
  /// queries. Without these, `recordCount`, `monthSummary`, `sidebarSummary`, and the
  /// year-roll-up helpers each iterate `recordsById.values` once per call — a 500k-record
  /// library × ~5 visible years on screen × every coalesced `mutationCounter` bump turned
  /// the timeline sidebar into a multi-second stall during exports. The counters are
  /// rebuilt from scratch at `configure(for:)` time and updated incrementally on every
  /// `apply(_:)` thereafter (every public mutation routes through `apply` via `append`).
  ///
  /// All public read methods translate one-for-one against the original implementations;
  /// `ExportRecordStoreQueryGoldenTests` pins the exact integer outputs against
  /// hand-checked fixtures so any drift here surfaces immediately.
  struct MonthKey: Hashable, Sendable {
    let year: Int
    let month: Int
  }
  struct MonthCounters: Sendable {
    /// Per-variant, per-status occurrence count.
    var variantStatus: [ExportVariant: [ExportStatus: Int]] = [:]
    /// Records where both `.original` and `.edited` variants are `.done`.
    var bothVariantsDone: Int = 0
    /// Records where `.original.done` at a natural-stem filename (not `_orig`-companion)
    /// AND `.edited` is not `.done`. The records-only sidebar formula's "unedited asset
    /// exported once" estimator depends on this.
    var originalDoneAtNaturalStem: Int = 0
    /// Records covered by the fallback: `.original.done` AND
    /// `.edited.failed` with the explicit
    /// `editedUnavailableOriginalBackedUpMessage` sentinel that
    /// `runEditedFallbackOriginal` writes after a successful `_orig` write.
    /// These represent adjusted assets where Photos refused the edit and the
    /// pipeline wrote the original as a fallback. Without this counter, the
    /// sidebar's records-only formula would never count fallback-covered
    /// records, leaving years stuck at 99% even after `isExported` correctly
    /// recognises them as covered.
    var editedFallbackCovered: Int = 0
    /// Records that have at least one paired-video variant
    /// (`.originalPairedVideo` or `.editedPairedVideo`) whose status is not
    /// `.done`. Subtracted from the records-only sidebar formula when the
    /// caller passes `livePhotosPaired: true` so a Live Photo whose still
    /// landed but whose paired video is still pending no longer over-reports.
    ///
    /// Transient over-reporting during active export: the variant order writes
    /// `.original` before `.originalPairedVideo`, so between
    /// `markVariantExported(.original)` and `markVariantInProgress(.originalPairedVideo)`
    /// the record has `.original.done` but no paired-video variant yet — the
    /// counter is 0, the legacy formula counts the record, and the sidebar
    /// reads it as fully exported even though the asset isn't complete under
    /// `livePhotosPaired`. Self-corrects on the next `markVariantInProgress`
    /// call when the paired-video variant lands and the counter increments.
    ///
    /// `.failed` paired-video variants are counted as incomplete with one
    /// exception: a `.failed` whose `lastError` is
    /// `pairedVideoUnavailableMessage` is treated as covered (the still landed
    /// and Photos has no motion file to give — analogous to
    /// `editedFallbackCovered`). Every other failure mode stays incomplete so
    /// the sidebar reflects asset state that the user can act on.
    var pairedVideoIncomplete: Int = 0
    static let zero = MonthCounters()
  }
  private(set) var monthCounters: [MonthKey: MonthCounters] = [:]

  /// A variant's folder: its month plus the subfolder it was written into.
  struct ClaimFolder: Hashable, Sendable {
    let year: Int
    let month: Int
    let subfolder: String

    init(year: Int, month: Int, subfolder: String?) {
      self.year = year
      self.month = month
      self.subfolder = subfolder ?? ""
    }
  }
  /// Filenames named by any variant record. Built on the first `isFilenameClaimed` query, at
  /// a session's first export, so a launch that exports nothing never pays for it (about
  /// 0.4 s per 500k records); kept with `monthCounters` after that. Nil until then, and again
  /// whenever the records are replaced wholesale.
  private var filenameClaims: FilenameClaims<ClaimFolder>?

  /// Per-store health, surfaced by RecordStoreAlertHost with the appropriate recovery action.
  @Published private(set) var state: RecordStoreState = .unconfigured
  @Published private(set) var persistenceError: String?
  private var hasUnsavedChanges = false
  // Immediate ownership token, separate from coalesced UI notifications. Any
  // configuration, accepted mutation, reset or newer reconciliation invalidates probes.
  private var reconciliationRevision: UInt64 = 0
  private var finalCommitContext: FinalCommitContext<[String: ExportRecord], ExportRecordMutation>?
  // Only completion deltas survive a corrupt load; full snapshots must not bypass
  // the corruption alert or its explicit reset/forensic-backup path.
  private var deferredFinalCompletions: [String: [() -> Void]] = [:]
  // Final commits acknowledged while their destination loaded, landed once it has finished.
  private var commitsLandedWhileLoading: [String: [() -> Void]] = [:]
  private var configuredDestinationId: String?
  var destinationId: String? { configuredDestinationId }
  // Failed writes must survive destination switches until the user can retry saving.
  private var pendingRecovery: [String: [String: ExportRecord]] = [:]
  // Each configure starts a new generation; only the newest load is installed.
  private var loadGeneration: UInt64 = 0
  private let latestLoad = RecordStoreLoadGeneration()
  private var settleWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

  // Published bump used to notify SwiftUI of logical changes
  @Published private(set) var mutationCounter: Int = 0

  /// Mirror of `ExportManager.convertHEICToJPEG`. Kept in sync by the manager
  /// (init + didSet on the published property). Read by `isExported(asset:
  /// selection:)` and `monthSummary(assets:selection:)` so view-side
  /// `@EnvironmentObject` callers see the right answers without having to
  /// thread the toggle through five call sites (timeline grid, year tiles,
  /// sidebar badges, content-pane summary, etc.).
  ///
  /// `@Published` so views with `@EnvironmentObject private var
  /// exportRecordStore: ExportRecordStore` re-render when the toggle flips.
  /// `MonthContentView` is `Equatable` over a stable value set and is not
  /// otherwise re-evaluated on toggle changes, so without the publish here
  /// "exported" thumbnail badges would stay stale until the next mutation.
  /// Change rate is zero outside user-toggle clicks, so no render-storm
  /// concern.
  @Published var convertHEICToJPEG: Bool = false
  private let notificationClock: any AutoSyncClock
  private lazy var changeNotifier = RecordStoreChangeNotifier(clock: notificationClock) {
    [weak self] in
    self?.mutationCounter &+= 1
  }

  private let fileManager = FileManager.default
  private let recordLogIO: any JSONLRecordLogIO
  private let reconciliationFileChecker: any ReconciliationFileChecking
  /// Base directory containing per-destination subdirectories
  /// (`<App Support>/<bundleId>/ExportRecords/`). Exposed for
  /// `ExportRecordsDirectoryCoordinator`, which needs to manage
  /// the per-destination subdirectory before this store configures.
  let storeRootURL: URL
  private var currentStoreDirURL: URL?
  typealias RecordFile = JSONLRecordFile<[String: ExportRecord], ExportRecordMutation>
  /// JSONL persistence for the currently configured destination. `nil` when the store is
  /// unconfigured (no destination selected). Reconstructed on every `configure(for:)`.
  private var jsonl: RecordFile?

  /// `baseDirectoryURL` is the parent of the per-destination folders; the app passes
  /// `AppComposition.recordsRoot`.
  init(
    baseDirectoryURL: URL,
    reconciliationFileChecker: any ReconciliationFileChecking = ReconciliationFileChecker(),
    recordLogIO: any JSONLRecordLogIO = ProductionJSONLRecordLogIO(),
    notificationClock: (any AutoSyncClock)? = nil
  ) {
    self.recordLogIO = recordLogIO
    self.notificationClock = notificationClock ?? SystemAutoSyncClock()
    self.reconciliationFileChecker = reconciliationFileChecker
    self.storeRootURL = baseDirectoryURL
    createDirectoryIfNeeded(baseDirectoryURL)
  }

  // MARK: - Destination configuration
  /// Points the store at a specific destination id (subdirectory) and loads its history before
  /// returning. Passing nil clears state (shows empty). Publishes no `.loading`; the app's
  /// destination changes use `beginConfigure(for:)`.
  func configure(for destinationId: String?) {
    let signpost = AppDiagnostics.beginConfigure(label: "timeline")
    defer { signpost.end() }
    guard let file = startConfiguring(for: destinationId) else { return }
    let inputs = file.readInputs
    let raw = ioQueue.sync { inputs.read() }
    let decoded = inputs.decode(raw)
    finishLoad(
      LoadTicket(generation: loadGeneration, file: file, signpost: nil),
      separator: decoded.needsLogSeparator, outcome: Self.prepare(decoded))
  }

  /// Points the store at a specific destination id and loads its history off the main actor.
  /// The store is `.loading` until the load finishes in one main-actor turn; records read as
  /// empty and mutations are refused meanwhile. `waitUntilSettled()` waits for the load. The
  /// file read is queued behind the previous destination's writes on the IO queue; decoding
  /// and preparing run in a detached task.
  func beginConfigure(for destinationId: String?) {
    let signpost = AppDiagnostics.beginConfigure(label: "timeline")
    guard let file = startConfiguring(for: destinationId) else {
      signpost.end()
      return
    }
    setState(.loading)
    changeNotifier.notifyNow()
    let ticket = LoadTicket(generation: loadGeneration, file: file, signpost: signpost)
    let inputs = file.readInputs
    let latestLoad = latestLoad
    ioQueue.async(qos: .userInitiated, flags: .enforceQoS) { [weak self] in
      let raw = inputs.read()
      Task.detached(priority: .userInitiated) { [weak self] in
        var separator: Bool?
        var outcome: LoadOutcome?
        if latestLoad.isCurrent(ticket.generation) {
          let decoded = inputs.decode(raw)
          separator = decoded.needsLogSeparator
          outcome = Self.prepare(decoded)
        }
        await self?.finishLoad(ticket, separator: separator, outcome: outcome)
      }
    }
  }

  /// Returns once the store is not `.loading`, or as soon as the calling task is cancelled.
  /// A blocking configure, or one to nil, ends the wait at once. An asynchronous configure that
  /// replaces the load keeps the store `.loading`, so the wait ends when the newest load settles.
  func waitUntilSettled() async {
    while state == .loading, !Task.isCancelled {
      let id = UUID()
      await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
          if Task.isCancelled {
            continuation.resume()
          } else {
            settleWaiters[id] = continuation
          }
        }
      } onCancel: {
        Task { @MainActor [weak self] in self?.settleWaiters.removeValue(forKey: id)?.resume() }
      }
    }
  }

  /// Loads that finished, applied or discarded. Exists for tests, to wait on progress.
  private(set) var finishedLoadCount = 0

  /// Tasks waiting in `waitUntilSettled()`. Exists for tests, to wait on progress.
  var pendingSettleWaiterCount: Int { settleWaiters.count }

  /// One load: which configure started it and the file it read. Only the newest configure's
  /// load is installed.
  private struct LoadTicket: Sendable {
    let generation: UInt64
    let file: RecordFile
    /// Ends when the load finishes; `nil` when the caller's own interval covers it.
    let signpost: ConfigureSignpost?
  }

  private static let retainedProgressMessage =
    "Progress from this destination still needs to be saved."

  /// What every configure does before reading: drain and park the old destination, switch,
  /// clear the in-memory history, and end there for nil or for history retained after a failed
  /// write. Returns the new destination's file when its history still has to be read.
  private func startConfiguring(for destinationId: String?) -> RecordFile? {
    reconciliationRevision &+= 1
    loadGeneration &+= 1
    latestLoad.advance(to: loadGeneration)

    // Finish the old destination's queued writes before replacing its file owner.
    jsonl?.drainSynchronously()
    // A parked final commit can fail while another destination is active. Deliver
    // that owner's failure before consulting pendingRecovery or loading it again.
    if let context = finalCommitContext {
      if context.file !== jsonl { context.file.drainSynchronously() }
      if context.destinationId == configuredDestinationId,
        state == .ready || hasUnsavedChanges, let file = jsonl
      {
        context.file = file
        context.snapshot = recordsById
      }
    }
    if hasUnsavedChanges, let id = configuredDestinationId {
      pendingRecovery[id] = recordsById
    }
    let departingId = configuredDestinationId
    configuredDestinationId = destinationId
    persistenceError = nil
    hasUnsavedChanges = false
    // Commits held for the departing destination's load would otherwise wait for a reload that
    // may never come. They now land in its parked history, written on the IO queue after the
    // discarded read. A configure of the same destination keeps them for its own load.
    if let departingId, departingId != destinationId {
      replayCommitsLandedWhileLoading(for: departingId)
    }

    // Reset in-memory state
    recordsById = [:]
    monthCounters = [:]
    filenameClaims = nil

    guard let destinationId else {
      currentStoreDirURL = nil
      jsonl = nil
      setState(.unconfigured)
      changeNotifier.notifyNow()
      return nil
    }

    let dir = storeRootURL.appendingPathComponent(destinationId, isDirectory: true)
    createDirectoryIfNeeded(dir)
    currentStoreDirURL = dir
    let file = RecordFile(
      snapshotURL: dir.appendingPathComponent(Constants.snapshotFileName),
      logURL: dir.appendingPathComponent(Constants.logFileName),
      ioQueue: ioQueue,
      logger: logger,
      logIO: recordLogIO
    )
    jsonl = file
    file.onPersistenceFailure = { [weak self, weak file] error in
      guard let self, let file else { return }
      if let context = self.finalCommitContext, context.file === file {
        self.retainFinalCommitFailure(error, context: context)
      }
      guard self.jsonl === file else { return }
      self.hasUnsavedChanges = true
      self.persistenceError = error.localizedDescription
      self.setState(.persistenceFailed)
    }

    if let retained = pendingRecovery[destinationId] {
      recordsById = retained
      rebuildCountersFromRecords()
      hasUnsavedChanges = true
      persistenceError = Self.retainedProgressMessage
      setState(.persistenceFailed)
      // No load follows, so commits held for this destination's replaced load land here, in
      // the retained history.
      replayCommitsLandedWhileLoading()
      changeNotifier.notifyNow()
      return nil
    }
    return file
  }

  /// Installs a finished load in one main-actor turn, unless a newer configure replaced it.
  /// `outcome` is nil when the load skipped decoding because it was already replaced.
  private func finishLoad(_ ticket: LoadTicket, separator: Bool?, outcome: LoadOutcome?) {
    defer { ticket.signpost?.end() }
    finishedLoadCount += 1
    guard ticket.generation == loadGeneration, ticket.file === jsonl, let outcome else {
      logger.debug("Discarded a timeline history load that a newer configure replaced")
      return
    }
    ticket.file.adoptLogSeparator(separator)
    // A claim query during the load built its index from the empty in-memory records.
    filenameClaims = nil
    if let id = configuredDestinationId, let retained = pendingRecovery[id] {
      // A final commit's write failure was parked while the load ran; its history wins.
      recordsById = retained
      rebuildCountersFromRecords()
      hasUnsavedChanges = true
      persistenceError = Self.retainedProgressMessage
      setState(.persistenceFailed)
    } else {
      switch outcome {
      case .ioFailure(let error):
        persistenceError = error.localizedDescription
        setState(.persistenceFailed)
      case .corrupt:
        // Deferred-rename rule: leave the corrupt snapshot at its original path on disk so
        // a Quit-and-relaunch reproduces this `.failed` state instead of silently
        // initializing empty. `resetToEmpty()` is the only path that renames the file out
        // of the way after the user chooses recovery in RecordStoreAlertHost.
        logger.error(
          "Timeline records snapshot at \(ticket.file.snapshotURL.path, privacy: .public) failed to decode; store transitioning to .failed."
        )
        setState(.failed)
      case .loaded(let prepared):
        recordsById = prepared.records
        monthCounters = prepared.monthCounters
        setState(.ready)
      }
    }
    if state == .failed, finalCommitContext?.destinationId == configuredDestinationId {
      finalCommitContext?.needsCorruptionRecovery = true
    }
    replayFinalCompletions()
    replayCommitsLandedWhileLoading()
    changeNotifier.notifyNow()
  }

  /// Every state change goes through here, so leaving `.loading` by any path resumes the
  /// tasks in `waitUntilSettled()`.
  private func setState(_ newState: RecordStoreState) {
    state = newState
    guard newState != .loading, !settleWaiters.isEmpty else { return }
    let waiters = settleWaiters
    settleWaiters.removeAll()
    for waiter in waiters.values { waiter.resume() }
  }

  /// The records and counters a successful load installs.
  struct PreparedLoad: Sendable {
    let records: [String: ExportRecord]
    let monthCounters: [MonthKey: MonthCounters]
  }

  /// How a load ends. A failed read outranks a corrupt snapshot, so the user is asked to
  /// retry storage access rather than to reset history that could not be read.
  enum LoadOutcome: Sendable {
    case ioFailure(any Error)
    case corrupt
    case loaded(PreparedLoad)
  }

  /// Builds what `configure(for:)` installs from a decoded load: the snapshot, the log
  /// replayed over it, interrupted variants recovered, then the counters counted once.
  /// Builds no claim index; that waits for the first claim query.
  nonisolated static func prepare(_ loaded: RecordFile.LoadResult) -> LoadOutcome {
    if let error = loaded.ioFailure { return .ioFailure(error) }
    switch loaded.snapshotStatus {
    case .corrupt:
      return .corrupt
    case .absent, .loaded:
      var records = loaded.snapshot ?? [:]
      // Replay without counting: counting each op against counters that do not yet hold
      // the snapshot would subtract records that were never added.
      for op in loaded.ops {
        applyMutation(op, to: &records)
      }
      recoverInProgressVariants(in: &records)
      var counters: [MonthKey: MonthCounters] = [:]
      var noClaims: FilenameClaims<ClaimFolder>?
      for record in records.values {
        contribute(record, sign: +1, counters: &counters, claims: &noClaims)
      }
      return .loaded(PreparedLoad(records: records, monthCounters: counters))
    }
  }

  /// Retry storage access without resetting export history. After an append failure,
  /// save the retained in-memory state; after a read failure, reload the original files.
  ///
  /// No commit held for a load can be waiting here: a store leaves `.loading` only through a
  /// finished load or the retained-recovery exit, and both land those commits.
  func retryPersistence() {
    guard state == .persistenceFailed else { return }
    guard hasUnsavedChanges, let jsonl else {
      configure(for: configuredDestinationId)
      return
    }
    do {
      try jsonl.writeSnapshot(recordsById)
      hasUnsavedChanges = false
      if let id = configuredDestinationId { pendingRecovery.removeValue(forKey: id) }
      persistenceError = nil
      setState(.ready)
      replayFinalCompletions()
      changeNotifier.notifyNow()
    } catch {
      persistenceError = error.localizedDescription
    }
  }

  /// True only when the current in-memory records have a successful write barrier.
  var hasDurableRecords: Bool {
    state == .ready && jsonl?.hasUnflushedChanges == false
  }

  /// Acknowledges all preceding record writes, including their synchronization.
  func flush() async throws {
    guard let file = jsonl else { throw RecordPersistenceUnavailable() }
    try await file.flush()
    guard jsonl === file else { throw CancellationError() }
    guard state == .ready else { throw RecordPersistenceUnavailable() }
  }

  /// Renames a corrupt snapshot to `<name>.broken-<ISO8601>` and reinitializes the store
  /// with an empty snapshot + log after the user chooses recovery in RecordStoreAlertHost.
  ///
  /// Transitions `state` from `.failed` back to `.ready` on success. Only valid to call
  /// when `state == .failed` (otherwise it is a no-op so callers can wire it through a
  /// generic alert handler without first checking).
  func resetToEmpty() {
    guard state == .failed else { return }
    reconciliationRevision &+= 1
    guard let jsonl else { return }
    do {
      try jsonl.resetToEmpty(emptySnapshot: [:])
      recordsById = [:]
      monthCounters = [:]
      filenameClaims = nil
      setState(.ready)
      replayFinalCompletions()
      changeNotifier.notifyNow()
    } catch {
      logger.error(
        "resetToEmpty failed: \(String(describing: error), privacy: .public). Store remains .failed."
      )
    }
  }

  /// Converts any variant left as `.inProgress` after load into `.failed` with the interrupted
  /// message. No in-progress state survives app restart; `.pending` is preserved as-is.
  nonisolated static func recoverInProgressVariants(in records: inout [String: ExportRecord]) {
    for (id, record) in records {
      var mutated = record
      var changed = false
      for (variant, variantRecord) in record.variants where variantRecord.status == .inProgress {
        var next = variantRecord
        next.status = .failed
        next.lastError = ExportVariantRecovery.interruptedMessage
        next.reason = .interrupted
        mutated.variants[variant] = next
        changed = true
      }
      if changed {
        records[id] = mutated
      }
    }
  }

  // MARK: - Public API (variant mutations)

  /// Marks a variant `.inProgress`. Creates the record if missing and upserts the variant.
  /// `subfolder` is the path component inside the placement folder where
  /// the file will land (e.g. `"videos"`). `nil` means the bare placement path. The
  /// value is persisted on the per-variant record so reuse-source and reconcile can
  /// recover each file's true on-disk location regardless of the current setting.
  func markVariantInProgress(
    assetId: String,
    variant: ExportVariant,
    year: Int,
    month: Int,
    relPath: String,
    filename: String?,
    subfolder: String? = nil
  ) {
    var record =
      recordsById[assetId]
      ?? ExportRecord(
        id: assetId, year: year, month: month, relPath: relPath)
    record.year = year
    record.month = month
    record.relPath = relPath
    var variantRecord =
      record.variants[variant]
      ?? ExportVariantRecord(
        filename: filename, status: .pending, exportDate: nil, lastError: nil)
    variantRecord.filename = filename
    variantRecord.status = .inProgress
    variantRecord.lastError = nil
    variantRecord.reason = nil
    variantRecord.subfolder = subfolder
    record.variants[variant] = variantRecord
    append(.upsert(record))
  }

  /// Marks a variant `.done` with a final filename. Creates the record if missing.
  /// See `markVariantInProgress` for `subfolder` semantics.
  func markVariantExported(
    assetId: String,
    variant: ExportVariant,
    year: Int,
    month: Int,
    relPath: String,
    filename: String,
    exportedAt: Date,
    subfolder: String? = nil
  ) {
    var record =
      recordsById[assetId]
      ?? ExportRecord(
        id: assetId, year: year, month: month, relPath: relPath)
    record.year = year
    record.month = month
    record.relPath = relPath
    let variantRecord = ExportVariantRecord(
      filename: filename, status: .done, exportDate: exportedAt, lastError: nil,
      subfolder: subfolder)
    record.variants[variant] = variantRecord
    append(.upsert(record))
  }

  /// Marks a variant `.failed`. Creates the record if missing; preserves year/month/relPath
  /// for existing records.
  func markVariantFailed(
    assetId: String,
    variant: ExportVariant,
    error: String,
    reason: ExportVariantReason? = nil,
    at date: Date
  ) {
    var record =
      recordsById[assetId]
      ?? ExportRecord(
        id: assetId, year: 0, month: 0, relPath: "")
    var variantRecord =
      record.variants[variant]
      ?? ExportVariantRecord(
        filename: nil, status: .pending, exportDate: nil, lastError: nil)
    variantRecord.status = .failed
    variantRecord.exportDate = date
    variantRecord.lastError = error
    variantRecord.reason = reason
    record.variants[variant] = variantRecord
    append(.upsert(record))
  }

  /// Removes a single variant from an asset record. If no variants remain, removes the record.
  func removeVariant(assetId: String, variant: ExportVariant) {
    guard var record = recordsById[assetId] else { return }
    guard record.variants[variant] != nil else { return }
    record.variants.removeValue(forKey: variant)
    if record.variants.isEmpty {
      append(.delete(id: assetId))
    } else {
      append(.upsert(record))
    }
  }

  // MARK: - Public API (queries)

  /// Strict, asset-aware completion check for a single asset. Thin wrapper that hands the
  /// record's variant dict to `ExportCompletionPolicy.isComplete`. Timeline placements
  /// always use `VariantPolicy.standard` (no reduced-fidelity sources on owned-library
  /// assets).
  ///
  /// Includes the edited-fallback case via the policy: an adjusted asset whose
  /// `.edited` variant is `.failed` with the `editedUnavailableOriginalBackedUpMessage`
  /// sentinel counts as exported. See `ExportCompletionPolicy.satisfiesEditedFallback`.
  ///
  /// `livePhotosPaired` is REQUIRED — no default — because every UI call site that
  /// surfaces "is this asset exported?" must consider whether the user has opted
  /// into paired-video accounting. The MonthContentView per-thumbnail
  /// badge bug that motivated this constraint silently defaulted to `false` and
  /// over-reported completeness. Tests that don't care pass `livePhotosPaired: false`
  /// explicitly — boilerplate is worth catching the silent-regression class at
  /// compile time.
  func isExported(
    asset: AssetDescriptor, selection: ExportVersionSelection,
    livePhotosPaired: Bool
  ) -> Bool {
    guard let record = recordsById[asset.id] else { return false }
    return ExportCompletionPolicy.isComplete(
      variants: record.variants, asset: asset, selection: selection, policy: .standard,
      convertHEICToJPEG: convertHEICToJPEG,
      livePhotosPaired: livePhotosPaired)
  }

  func exportInfo(assetId: String) -> ExportRecord? {
    recordsById[assetId]
  }

  /// Whether a record names `filename` in the folder for `year`/`month` and `subfolder`,
  /// apart from `assetId`'s own `variant`. The asset's other variants count.
  func isFilenameClaimed(
    _ filename: String, year: Int, month: Int, subfolder: String?,
    exceptVariant variant: ExportVariant, of assetId: String
  ) -> Bool {
    isFilenameClaimed(
      filename, year: year, month: month, subfolder: subfolder, assetId: assetId,
      excluding: { $0 == variant })
  }

  /// Whether another asset's record names `filename` in the folder for `year`/`month` and
  /// `subfolder`. None of `assetId`'s own variants count.
  func isFilenameClaimed(
    _ filename: String, year: Int, month: Int, subfolder: String?,
    exceptAsset assetId: String
  ) -> Bool {
    isFilenameClaimed(
      filename, year: year, month: month, subfolder: subfolder, assetId: assetId,
      excluding: { _ in true })
  }

  private func isFilenameClaimed(
    _ filename: String, year: Int, month: Int, subfolder: String?, assetId: String,
    excluding isOwn: (ExportVariant) -> Bool
  ) -> Bool {
    let own =
      (recordsById[assetId].map { record in
        record.variants.filter { isOwn($0.key) }.values.map {
          (
            filename: $0.filename,
            folder: ClaimFolder(year: record.year, month: record.month, subfolder: $0.subfolder)
          )
        }
      }) ?? []
    let folder = ClaimFolder(year: year, month: month, subfolder: subfolder)
    return currentFilenameClaims().count(filename, in: folder, excluding: own) > 0
  }

  private func currentFilenameClaims() -> FilenameClaims<ClaimFolder> {
    if let filenameClaims { return filenameClaims }
    let claims = Self.buildClaims(from: recordsById, logger: logger)
    filenameClaims = claims
    return claims
  }

  /// The claim index for `records`: every filename a variant names, in its folder.
  nonisolated static func buildClaims(
    from records: [String: ExportRecord], logger: Logger
  ) -> FilenameClaims<ClaimFolder> {
    FilenameClaims<ClaimFolder>.build(recordCount: records.count, logger: logger) { claims in
      for record in records.values {
        for variant in record.variants.values {
          claims.add(
            variant.filename,
            in: ClaimFolder(year: record.year, month: record.month, subfolder: variant.subfolder))
        }
      }
    }
  }

  /// Total number of assets in `year` whose `.original` variant is `.done`. Matches legacy
  /// yearly progress counting for unadjusted libraries.
  func yearExportedCount(year: Int) -> Int {
    var total = 0
    for month in 1...12 {
      total +=
        monthCounters[MonthKey(year: year, month: month)]?
        .variantStatus[.original]?[.done] ?? 0
    }
    return total
  }

  /// Legacy month summary that counts `.original` done records. Preserved for call sites that
  /// have not yet adopted `monthSummary(assets:selection:)`.
  func monthSummary(year: Int, month: Int, totalAssets: Int) -> MonthStatusSummary {
    let exportedCount =
      monthCounters[MonthKey(year: year, month: month)]?
      .variantStatus[.original]?[.done] ?? 0
    return makeSummary(year: year, month: month, exported: exportedCount, total: totalAssets)
  }

  /// Selection-aware month summary. Caller supplies the month's loaded asset descriptors so the
  /// evaluator can consult each asset's `hasAdjustments`. `livePhotosPaired` is the user's
  /// current setting — without it, a Live Photo whose paired video is pending
  /// would be miscounted as complete.
  func monthSummary(
    assets: [AssetDescriptor], selection: ExportVersionSelection, livePhotosPaired: Bool
  ) -> MonthStatusSummary {
    let year =
      assets.first.map { Calendar.current.component(.year, from: $0.creationDate ?? Date()) }
      ?? 0
    let month =
      assets.first.map { Calendar.current.component(.month, from: $0.creationDate ?? Date()) }
      ?? 0

    var exported = 0
    for asset in assets
    where isExported(asset: asset, selection: selection, livePhotosPaired: livePhotosPaired) {
      exported += 1
    }
    return makeSummary(year: year, month: month, exported: exported, total: assets.count)
  }

  /// Count of records in `year`/`month` whose variant matches the requested `variant` with the
  /// requested `status`. Used by selection-aware sidebar summaries that do not have access to the
  /// loaded asset descriptors.
  func recordCount(
    year: Int, month: Int, variant: ExportVariant, status: ExportStatus
  ) -> Int {
    monthCounters[MonthKey(year: year, month: month)]?
      .variantStatus[variant]?[status] ?? 0
  }

  /// Count of records in `year`/`month` whose `.original` and `.edited` variants are both
  /// `.done`. These records are definitely fully complete under `editedWithOriginals`
  /// regardless of whether the asset is currently adjusted.
  func recordCountBothVariantsDone(year: Int, month: Int) -> Int {
    monthCounters[MonthKey(year: year, month: month)]?.bothVariantsDone ?? 0
  }

  /// Count of records in `year`/`month` whose `.edited` variant is `.done`. Used by the
  /// records-only sidebar formula for the default mode.
  func recordCountEditedDone(year: Int, month: Int) -> Int {
    recordCount(year: year, month: month, variant: .edited, status: .done)
  }

  /// Count of records in `year`/`month` with `.original.done` at a natural-stem filename
  /// (i.e. not a `_orig` companion) AND `.edited` not `.done`. Used by the records-only
  /// sidebar formula to estimate "unedited asset, exported once" rows without loading
  /// descriptors.
  func recordCountOriginalDoneAtNaturalStem(year: Int, month: Int) -> Int {
    monthCounters[MonthKey(year: year, month: month)]?.originalDoneAtNaturalStem ?? 0
  }

  /// Records covered by the fallback in `(year, month)`. Counted as
  /// "exported" by the sidebar's records-only formula in `.edited` mode so a
  /// year that finishes with fallback-covered assets reads as 100% rather
  /// than 99% — matching the asset-aware `isExported(asset:selection:)`.
  func recordCountEditedFallback(year: Int, month: Int) -> Int {
    monthCounters[MonthKey(year: year, month: month)]?.editedFallbackCovered ?? 0
  }

  /// Records in `(year, month)` with at least one paired-video variant whose
  /// status is not `.done`. Subtracted by `sidebarSummary` when the caller
  /// passes `livePhotosPaired: true` so a Live Photo whose still landed but
  /// whose motion file is still pending no longer reads as fully exported
  /// in the timeline sidebar / month tile badges.
  func recordCountPairedVideoIncomplete(year: Int, month: Int) -> Int {
    monthCounters[MonthKey(year: year, month: month)]?.pairedVideoIncomplete ?? 0
  }

  /// Records-only approximation of "fully exported under this selection," capped by the
  /// count of unedited assets in scope so that natural-stem `.original.done` records
  /// belonging to currently-adjusted assets cannot over-contribute past the number of
  /// assets that could legitimately be original-only.
  ///
  /// `adjustedCount` is required for both modes. Pass nil when the count hasn't loaded yet —
  /// callers should render a neutral "loading" state in that case rather than treat nil as
  /// zero.
  ///
  /// `livePhotosPaired` is REQUIRED — no default. When true, records with
  /// any paired-video variant in a non-`.done` state are subtracted from the exported
  /// total so a Live Photo whose still landed but whose motion file is still pending
  /// no longer over-reports against the per-asset
  /// `isExported(asset:selection:livePhotosPaired:)`. Forcing every caller to pass
  /// the flag prevents silent regressions at the UI seam.
  func sidebarSummary(
    year: Int, month: Int, totalCount: Int, adjustedCount: Int?,
    selection: ExportVersionSelection,
    livePhotosPaired: Bool
  ) -> MonthStatusSummary? {
    guard let adjustedCount else { return nil }
    let uneditedCount = max(0, totalCount - adjustedCount)
    let origOnlyAtStem = recordCountOriginalDoneAtNaturalStem(year: year, month: month)
    let pairedIncomplete =
      livePhotosPaired ? recordCountPairedVideoIncomplete(year: year, month: month) : 0
    switch selection {
    case .edited:
      let editedDone = recordCountEditedDone(year: year, month: month)
      let fallbackCovered = recordCountEditedFallback(year: year, month: month)
      let legacy = editedDone + min(origOnlyAtStem, uneditedCount) + fallbackCovered
      let exported = max(0, legacy - pairedIncomplete)
      return makeSummary(year: year, month: month, exported: exported, total: totalCount)
    case .editedWithOriginals:
      // `editedFallbackCovered` is intentionally NOT added here:
      // `satisfiesEditedFallback` is gated to `selection == .edited`, so the
      // asset-aware `isExported(asset:selection:)` keeps re-queueing fallback
      // records under `.editedWithOriginals`. The sidebar must agree, or a
      // year that's actually 0% covered would advertise as 100%.
      let bothDone = recordCountBothVariantsDone(year: year, month: month)
      let legacy = bothDone + min(origOnlyAtStem, uneditedCount)
      let exported = max(0, legacy - pairedIncomplete)
      return makeSummary(year: year, month: month, exported: exported, total: totalCount)
    }
  }

  /// Year-scope variant. Iterates each month with its (totalCount, adjustedCount) pair, sums
  /// the per-month exported counts, and returns the rolled-up total. Months whose
  /// adjustedCount is nil contribute zero to the total — callers should suppress the
  /// year-level badge until all populated months have reported.
  func sidebarYearExportedCount(
    year: Int,
    totalCountsByMonth: [Int: Int],
    adjustedCountsByMonth: [Int: Int?],
    selection: ExportVersionSelection,
    livePhotosPaired: Bool
  ) -> Int {
    var total = 0
    for month in 1...12 {
      let monthTotal = totalCountsByMonth[month] ?? 0
      if monthTotal == 0 { continue }
      let monthAdjusted = adjustedCountsByMonth[month].flatMap { $0 }
      guard
        let summary = sidebarSummary(
          year: year, month: month, totalCount: monthTotal,
          adjustedCount: monthAdjusted, selection: selection,
          livePhotosPaired: livePhotosPaired)
      else { continue }
      total += summary.exportedCount
    }
    return total
  }

  private func makeSummary(year: Int, month: Int, exported: Int, total: Int)
    -> MonthStatusSummary
  {
    let status: MonthExportStatus
    if total == 0 {
      status = .notExported
    } else if exported == 0 {
      status = .notExported
    } else if exported < total {
      status = .partial
    } else {
      status = .complete
    }
    return MonthStatusSummary(
      year: year, month: month, exportedCount: exported, totalCount: total, status: status)
  }

  // MARK: - Reconcile against filesystem

  /// Result of `reconcileAgainstFilesystem(at:)`.
  struct ReconcileSummary: Equatable {
    let prunedVariants: Int
    let prunedRecords: Int

    static let zero = ReconcileSummary(prunedVariants: 0, prunedRecords: 0)
  }

  /// Removes every `.done` variant whose backing file is missing from the destination.
  /// Used by Import Existing Backup so a destination whose contents have shrunk (or
  /// vanished) reflects disk truth instead of stale state from a previous run.
  ///
  /// Pruning rules:
  /// - `.failed`/`.inProgress` variants are left alone — they have signal value (Save
  ///   Diagnostic Report surfaces them) and the next export run retries them anyway.
  /// - Invalid location metadata, nonregular targets and lookup errors reject the
  ///   entire batch. Only child-path ENOENT/ENOTDIR proves absence.
  /// - A readable destination root is revalidated before applying any prune.
  /// - When all variants are pruned, the record is removed entirely.
  ///
  /// Two-phase to respect the `@MainActor` isolation: snapshot on main, file checks
  /// off-main via `runDetached`, mutations applied on main. Callers must run this
  /// only when no export is active (the import flow already gates on
  /// `!hasActiveExportWork`). Reconfiguration, concurrent mutations, replacement
  /// reconciliation, Task cancellation or loss of caller ownership discard the batch.
  func reconcileAgainstFilesystem(
    at root: URL, isCurrent: @MainActor () -> Bool = { true }
  ) async throws -> ReconcileSummary {
    guard isCurrent(), !Task.isCancelled, state == .ready else { return .zero }
    reconciliationRevision &+= 1
    let revision = reconciliationRevision

    // Snapshot on main: capture every .done variant's expected on-disk path.
    let probes = try completedVariantProbes(root: root)

    // Probe off-main: preserve errors until ownership has been checked.
    let probesCopy = probes
    let fileChecker = reconciliationFileChecker
    // Cancellation stops new probes; a probe in flight finishes first.
    let outcome: Result<[(assetId: String, variant: ExportVariant)], Error> = await runDetached {
      do {
        var keys: [(assetId: String, variant: ExportVariant)] = []
        for probe in probesCopy {
          try Task.checkCancellation()
          if try await !fileChecker.isFile(atPath: probe.path) {
            keys.append((probe.assetId, probe.variant))
          }
        }
        try Task.checkCancellation()
        try await fileChecker.validateRoot(atPath: root.path)
        return .success(keys)
      } catch { return .failure(error) }
    }

    // Evaluate caller ownership first; then reject configuration/mutation changes
    // before the whole synchronous commit (whose own appends advance the revision).
    guard isCurrent(), !Task.isCancelled, state == .ready,
      reconciliationRevision == revision
    else { return .zero }

    let toPrune = try outcome.get()

    // Commit on main: apply mutations.
    var prunedVariants = 0
    var prunedRecords = 0
    for (assetId, variant) in toPrune {
      guard var record = recordsById[assetId] else { continue }
      guard record.variants.removeValue(forKey: variant) != nil else { continue }
      prunedVariants += 1
      if record.variants.isEmpty {
        append(.delete(id: assetId))
        prunedRecords += 1
      } else {
        append(.upsert(record))
      }
    }
    logger.info(
      "Reconciled timeline: pruned \(prunedVariants) variants, \(prunedRecords) records")
    return ReconcileSummary(
      prunedVariants: prunedVariants, prunedRecords: prunedRecords)
  }

  private struct CompletedVariantProbe: Sendable {
    let assetId: String
    let variant: ExportVariant
    let path: String
  }

  private func completedVariantProbes(root: URL) throws -> [CompletedVariantProbe] {
    var probes: [CompletedVariantProbe] = []
    for (assetId, record) in recordsById {
      for (variant, vr) in record.variants where vr.status == .done {
        // probe each variant's *own* on-disk location, computed from the
        // placement-derived `record.relPath` (which the timeline store sets to the
        // current target layout's effective path on every write) plus the variant's
        // persisted `subfolder`. Under mid-life toggle, two variants of one asset
        // can live in different subfolders — using a shared `record.relPath` here
        // would mis-probe whichever variant didn't match the last write.
        let placement = ExportPlacement.timeline(year: record.year, month: record.month)
        let path = try ReconciliationFileChecker.filePath(
          root: root, placement: placement, filename: vr.filename, subfolder: vr.subfolder)
        probes.append(CompletedVariantProbe(assetId: assetId, variant: variant, path: path))
      }
    }
    return probes
  }

  /// Whether any completed variant's file is under `root`, or `nil` when there is no completed
  /// variant to look for (or the store isn't ready). Read-only: stops at the first file found,
  /// and checks the root before concluding that none are there, so an unreadable folder throws
  /// instead of reading as empty.
  func containsCompletedFile(
    at root: URL, isCurrent: @MainActor () -> Bool = { true }
  ) async throws -> Bool? {
    guard isCurrent(), !Task.isCancelled, state == .ready else { return nil }
    let paths = try completedVariantProbes(root: root).map(\.path)
    guard !paths.isEmpty else { return nil }
    let fileChecker = reconciliationFileChecker
    return try await runDetached { try await fileChecker.containsAnyFile(paths, root: root) }
  }

  // MARK: - Bulk import (for backup import)

  /// Imports a batch of records from the backup-scan flow, merging per variant. An existing
  /// `.done` for a given asset+variant is preserved; weaker statuses may be replaced by an imported
  /// `.done` variant.
  ///
  /// Bails early when the store isn't `.ready` — otherwise the per-record `append` would
  /// trip a debug assertion on every iteration. The caller (Import Existing Backup flow)
  /// should only invoke this when the store has loaded successfully; the early return is a
  /// belt-and-braces no-op for unexpected states.
  func bulkImportRecords(_ records: [ExportRecord]) {
    guard state == .ready else { return }
    var importedVariants = 0
    var skippedVariants = 0
    for incoming in records {
      var merged =
        recordsById[incoming.id]
        ?? ExportRecord(
          id: incoming.id, year: incoming.year, month: incoming.month, relPath: incoming.relPath)
      let hasCompletedVariant = merged.variants.values.contains { $0.status == .done }
      if hasCompletedVariant {
        // Timeline paths are resolved from year/month plus each variant's subfolder.
        // Raw relPath may include videos/ even for the same timeline placement.
        guard merged.year == incoming.year, merged.month == incoming.month else {
          skippedVariants += incoming.variants.count
          logger.warning("Skipped import at a conflicting completed timeline placement")
          continue
        }
      } else {
        merged.year = incoming.year
        merged.month = incoming.month
        merged.relPath = incoming.relPath
      }
      var changed = false
      for (variant, variantRecord) in incoming.variants {
        if let existing = merged.variants[variant], existing.status == .done {
          skippedVariants += 1
          continue
        }
        merged.variants[variant] = variantRecord
        importedVariants += 1
        changed = true
      }
      if changed {
        append(.upsert(merged))
      }
    }
    logger.info(
      "Bulk imported \(importedVariants) variants (skipped \(skippedVariants) completed or conflicting variants)"
    )
  }

  /// Captures the existing writer before physical final IO. A successful move is
  /// acknowledged even after cancellation; failure retains history for Retry. The
  /// acknowledgement carries the name the file was committed or adopted under, or `nil`
  /// when nothing was committed.
  func captureFinalCommit(
    assetId: String, variant: ExportVariant, year: Int, month: Int, relPath: String,
    subfolder: String?, acceptsEditedFallback: Bool
  ) throws -> (_ finalFilename: String?) async -> Void {
    guard state == .ready, let destinationId = configuredDestinationId, let file = jsonl else {
      throw RecordPersistenceUnavailable()
    }
    precondition(finalCommitContext == nil, "Final commits must be serialized")
    let context = FinalCommitContext(
      destinationId: destinationId, file: file, snapshot: [:])
    finalCommitContext = context
    let applyCompletion = { [weak self] (filename: String) in
      guard let self else { return }
      let date = Date()
      self.markVariantExported(
        assetId: assetId, variant: variant, year: year, month: month, relPath: relPath,
        filename: filename, exportedAt: date, subfolder: subfolder)
      if acceptsEditedFallback {
        self.markVariantFailed(
          assetId: assetId, variant: .edited,
          error: ExportVariantRecovery.editedUnavailableOriginalBackedUpMessage,
          reason: .editedUnavailableOriginalBackedUp, at: date)
      }
    }
    // Writes the completion into the parked history of a destination the store has left.
    let writeParked = { (filename: String) in
      let exportedAt = Date()
      let done = ExportVariantRecord(
        filename: filename, status: .done, exportDate: exportedAt, lastError: nil,
        subfolder: subfolder)
      var record =
        context.snapshot[assetId]
        ?? ExportRecord(id: assetId, year: year, month: month, relPath: relPath)
      record.year = year
      record.month = month
      record.relPath = relPath
      record.variants[variant] = done
      if acceptsEditedFallback {
        // As `markVariantFailed` does: a new edited record names no file.
        var edited =
          record.variants[.edited]
          ?? ExportVariantRecord(filename: nil, status: .pending, exportDate: nil, lastError: nil)
        edited.status = .failed
        edited.exportDate = exportedAt
        edited.lastError = ExportVariantRecovery.editedUnavailableOriginalBackedUpMessage
        edited.reason = .editedUnavailableOriginalBackedUp
        record.variants[.edited] = edited
      }
      context.snapshot[assetId] = record
      context.file.append(.upsert(record), currentSnapshot: { context.snapshot })
    }
    return { [self] finalFilename in
      defer { if finalCommitContext === context { finalCommitContext = nil } }
      guard let filename = finalFilename else { return }
      let landing = landFinalCommit(
        filename, context: context, applyCompletion: applyCompletion, writeParked: writeParked)
      guard landing != .held else { return }
      do {
        try await context.file.flush()
      } catch {
        retainFinalCommitFailure(error, context: context)
      }
    }
  }

  /// Lands an acknowledged final commit where its destination now stands: deferred behind a
  /// corrupt load, held while the destination loads, recorded in the active history, or written
  /// to the parked history of a destination the store has left. A held commit comes back here
  /// when that load finishes, or when the store leaves the destination first.
  private func landFinalCommit(
    _ filename: String,
    context: FinalCommitContext<[String: ExportRecord], ExportRecordMutation>,
    applyCompletion: @escaping (String) -> Void,
    writeParked: @escaping (String) -> Void
  ) -> FinalCommitLanding {
    let destinationId = context.destinationId
    if context.needsCorruptionRecovery
      || (configuredDestinationId == destinationId && state == .failed)
    {
      deferredFinalCompletions[destinationId, default: []].append { applyCompletion(filename) }
      return .held
    }
    guard configuredDestinationId == destinationId else {
      writeParked(filename)
      return .parked
    }
    guard state != .loading else {
      // Land against whatever the load ends in, as if the commit had arrived just after.
      commitsLandedWhileLoading[destinationId, default: []].append { [weak self] in
        guard let self else { return }
        let landing = self.landFinalCommit(
          filename, context: context, applyCompletion: applyCompletion, writeParked: writeParked)
        guard landing == .parked else { return }
        // Nobody awaits this commit any more. Finish its write before the store moves on, so a
        // failure is retained for Retry like any parked commit's.
        context.file.drainSynchronously()
        if context.file.hasUnflushedChanges {
          self.retainFinalCommitFailure(RecordPersistenceUnavailable(), context: context)
        }
      }
      return .held
    }
    return landOnActiveDestination(filename, context: context, applyCompletion: applyCompletion)
      ? .recorded : .held
  }

  /// Records an acknowledged final commit in the active destination's history: deferred
  /// behind a corrupt load, added to the parked history after an unreadable reload, or
  /// recorded. Returns whether the completion was written and its flush is still owed.
  @discardableResult
  private func landOnActiveDestination(
    _ filename: String,
    context: FinalCommitContext<[String: ExportRecord], ExportRecordMutation>,
    applyCompletion: @escaping (String) -> Void
  ) -> Bool {
    if state == .failed {
      deferredFinalCompletions[context.destinationId, default: []].append {
        applyCompletion(filename)
      }
      return false
    }
    if state == .persistenceFailed && !hasUnsavedChanges {
      // The known pre-switch history is intact in the parked owner, even
      // when its later reload was unreadable. Retry must retain the new file.
      recordsById = context.snapshot
      rebuildCountersFromRecords()
      hasUnsavedChanges = true
    }
    applyCompletion(filename)
    if state == .persistenceFailed {
      retainFinalCommitFailure(RecordPersistenceUnavailable(), context: context)
      return false
    }
    return true
  }

  /// Lands the final commits acknowledged while `destinationId` loaded, by default the active
  /// destination's. A completion recorded in the active history is flushed by the store's
  /// ordinary append path.
  private func replayCommitsLandedWhileLoading(for destinationId: String? = nil) {
    guard let id = destinationId ?? configuredDestinationId else { return }
    let landings = commitsLandedWhileLoading.removeValue(forKey: id) ?? []
    for land in landings { land() }
  }

  private func replayFinalCompletions() {
    guard state == .ready, let id = configuredDestinationId else { return }
    if finalCommitContext?.destinationId == id {
      finalCommitContext?.needsCorruptionRecovery = false
    }
    let completions = deferredFinalCompletions.removeValue(forKey: id) ?? []
    for completion in completions { completion() }
  }

  /// Parks the commit's history for Retry after its write failed. Internal rather than private
  /// only so its direct test can reach it.
  func retainFinalCommitFailure(
    _ error: any Error, context: FinalCommitContext<[String: ExportRecord], ExportRecordMutation>
  ) {
    let isActive = configuredDestinationId == context.destinationId
    // While the destination loads, its in-memory records are empty and must not replace the
    // commit's own snapshot; the finished load installs what is parked here.
    let isLoading = isActive && state == .loading
    if isActive && !isLoading {
      // Active state is already current; snapshot only on failure, avoiding a full
      // dictionary CoW on every ordinary successful file commit.
      context.snapshot = recordsById
    }
    pendingRecovery[context.destinationId] = context.snapshot
    guard isActive, !isLoading else { return }
    reconciliationRevision &+= 1
    hasUnsavedChanges = true
    persistenceError = error.localizedDescription
    setState(.persistenceFailed)
    changeNotifier.notifyNow()
  }

  // MARK: - Internals
  private func append(_ mutation: ExportRecordMutation) {
    // Keep an in-flight export's final filename in memory after a write failure,
    // so Retry can save it without exporting the file again. Failed loads stay read-only.
    guard state == .ready || (state == .persistenceFailed && hasUnsavedChanges) else {
      return
    }

    reconciliationRevision &+= 1
    apply(mutation)
    if let context = finalCommitContext, context.destinationId == configuredDestinationId,
      let file = jsonl
    {
      context.file = file
    }
    // Coalesce notifications to avoid excessive UI churn during exports
    scheduleCoalescedNotify()

    // If not configured to any destination, do not persist
    guard state == .ready, let jsonl else { return }
    jsonl.append(mutation, currentSnapshot: { self.recordsById })
  }

  /// Applies a mutation to in-memory state and updates `monthCounters` incrementally by
  /// subtracting the old record's contribution and adding the new record's. Loading
  /// replays ops through `applyMutation` alone and counts once afterwards (see `prepare`).
  private func apply(_ mutation: ExportRecordMutation) {
    guard let change = Self.applyMutation(mutation, to: &recordsById) else { return }
    adjustCounters(old: change.old, new: change.new)
  }

  /// Applies a mutation to `records` and returns the record it replaced or removed and the
  /// one it stored, or `nil` when it changed nothing (an upsert without a record).
  @discardableResult
  nonisolated static func applyMutation(
    _ mutation: ExportRecordMutation, to records: inout [String: ExportRecord]
  ) -> (old: ExportRecord?, new: ExportRecord?)? {
    let oldRecord = records[mutation.id]
    switch mutation.op {
    case .upsert:
      guard let record = mutation.record else { return nil }
      records[mutation.id] = record
      return (oldRecord, record)
    case .delete:
      records.removeValue(forKey: mutation.id)
      return (oldRecord, nil)
    }
  }

  /// Subtracts the old record's contribution and adds the new record's to `monthCounters`.
  /// Either side may be `nil` (a fresh insert has no `old`; a delete has no `new`).
  private func adjustCounters(old: ExportRecord?, new: ExportRecord?) {
    if let old {
      Self.contribute(old, sign: -1, counters: &monthCounters, claims: &filenameClaims)
    }
    if let new {
      Self.contribute(new, sign: +1, counters: &monthCounters, claims: &filenameClaims)
    }
  }

  /// Adds (`sign == +1`) or removes (`sign == -1`) `record`'s contribution to its
  /// `(year, month)` cell of `counters`, and its filenames to `claims` when there is an
  /// index. Idempotent under `+1` then `-1` for the same record value, which is what the
  /// diff in `adjustCounters` relies on.
  nonisolated static func contribute(
    _ record: ExportRecord, sign: Int, counters monthCounters: inout [MonthKey: MonthCounters],
    claims filenameClaims: inout FilenameClaims<ClaimFolder>?
  ) {
    let key = MonthKey(year: record.year, month: record.month)
    var counters = monthCounters[key] ?? .zero
    for (variant, variantRec) in record.variants {
      let prior = counters.variantStatus[variant]?[variantRec.status] ?? 0
      counters.variantStatus[variant, default: [:]][variantRec.status] = prior + sign
    }
    let originalDone = record.variants[.original]?.status == .done
    let editedDone = record.variants[.edited]?.status == .done
    if originalDone && editedDone {
      counters.bothVariantsDone += sign
    }
    if originalDone, !editedDone,
      let filename = record.variants[.original]?.filename,
      !ExportFilenamePolicy.isOrigCompanion(filename: filename)
    {
      counters.originalDoneAtNaturalStem += sign
    }
    if originalDone,
      let editedRecord = record.variants[.edited],
      editedRecord.status == .failed,
      editedRecord.reason == .editedUnavailableOriginalBackedUp
    {
      counters.editedFallbackCovered += sign
    }
    // A `.failed` paired-video with the `pairedVideoUnavailable` reason is
    // covered (the still landed, Photos has no motion file to give). Mirrors the
    // `editedFallbackCovered` handling — a record whose only "incompleteness" is
    // that reason must NOT count against the sidebar's exported total.
    let hasIncompletePairedVideo = record.variants.contains { variant, vr in
      guard variant.isPairedVideo, vr.status != .done else { return false }
      if vr.status == .failed,
        vr.reason == .pairedVideoUnavailable
      {
        return false
      }
      return true
    }
    if hasIncompletePairedVideo {
      counters.pairedVideoIncomplete += sign
    }
    monthCounters[key] = counters
    for variantRec in record.variants.values {
      let folder = ClaimFolder(
        year: record.year, month: record.month, subfolder: variantRec.subfolder)
      if sign > 0 {
        filenameClaims?.add(variantRec.filename, in: folder)
      } else {
        filenameClaims?.remove(variantRec.filename, in: folder)
      }
    }
  }

  /// Rebuilds `monthCounters` from scratch by walking `recordsById` once, and drops
  /// `filenameClaims` for the next query to rebuild. Called whenever retained records
  /// replace the in-memory ones; a load counts its records in `prepare` instead.
  private func rebuildCountersFromRecords() {
    monthCounters = [:]
    filenameClaims = nil
    for record in recordsById.values {
      Self.contribute(record, sign: +1, counters: &monthCounters, claims: &filenameClaims)
    }
  }

  private func createDirectoryIfNeeded(_ url: URL) {
    if !fileManager.fileExists(atPath: url.path) {
      do { try fileManager.createDirectory(at: url, withIntermediateDirectories: true) } catch {
        logger.error(
          "Failed to create store directory: \(String(describing: error), privacy: .public)"
        )
      }
    }
  }

  private func scheduleCoalescedNotify() {
    changeNotifier.schedule()
  }

  /// Delivers final logical changes at an owned terminal boundary, independently of IO.
  func flushPendingNotifications() {
    changeNotifier.flushPending()
  }

  // MARK: - Synchronous IO drain
  /// Blocks the caller until queued IO finishes and delivers any pending failure.
  /// Must not be called from the IO queue.
  func drainSynchronously() {
    jsonl?.drainSynchronously()
  }
}
