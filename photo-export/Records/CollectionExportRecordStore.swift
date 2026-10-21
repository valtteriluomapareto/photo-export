import Combine
import Foundation
import os

/// Per-destination record store for **collection** exports (favorites + user albums).
/// Lives alongside the existing timeline `ExportRecordStore`; the two share no keys on
/// disk, so a failed favorites/album export is physically incapable of touching a timeline
/// record for the same asset.
///
/// On-disk layout under `<App Support>/<bundleId>/ExportRecords/<destinationId>/`:
/// - `collection-records.json` — snapshot
/// - `collection-records.jsonl` — append-only log
///
/// Empty on first launch; the snapshot file is only written once a mutation happens. There
/// is no migration of any kind into this store — the timeline store's pre-existing data
/// stays in `export-records.{json,jsonl}` untouched.
///
/// The store **rejects** `.timeline` placements at every entry point. Three layers of
/// defense uphold the disjoint-key-space invariant:
/// 1. The mutation API gate `accept(_:)` returns `false` and logs an error on `.timeline`.
/// 2. `configure(for:)` filters `.timeline` placements out of the loaded snapshot before
///    they enter `placements`.
/// 3. `apply(.upsertPlacement)` filters `.timeline` placements out of the log replay.
/// `ExportManager` is responsible for routing record mutations to the correct store via
/// `placement.kind`; this store's defenses ensure that even a tampered-on-disk file
/// cannot violate the invariant.
@MainActor
final class CollectionExportRecordStore: ObservableObject {
  enum Constants {
    static let logFileName = "collection-records.jsonl"
    static let snapshotFileName = "collection-records.json"
    static let snapshotVersion = 1
  }

  // MARK: - Snapshot + log shapes

  /// One asset's variants under one placement. The on-disk shape uses string keys
  /// (`ExportVariant.rawValue`) so it round-trips cleanly through standard JSON.
  struct RecordBody: Codable, Sendable, Equatable {
    var variants: [String: ExportVariantRecord]

    /// Strongly-typed projection of `variants` for handing to
    /// `ExportCompletionPolicy`. Drops any keys that don't decode to a known
    /// `ExportVariant` — in practice empty, since writers only ever store
    /// `ExportVariant.rawValue` keys.
    var typedVariants: [ExportVariant: ExportVariantRecord] {
      Dictionary(
        uniqueKeysWithValues: variants.compactMap { key, value in
          ExportVariant(rawValue: key).map { ($0, value) }
        })
    }
  }

  /// Top-level snapshot. `placements` is the canonical placement metadata; `records` is
  /// nested by placement id and then asset id. Two stores' snapshots are independent files
  /// with no shared keys.
  struct Snapshot: Codable, Sendable, Equatable {
    var version: Int
    var placements: [String: ExportPlacement]
    var records: [String: [String: RecordBody]]

    static var empty: Snapshot {
      Snapshot(version: Constants.snapshotVersion, placements: [:], records: [:])
    }
  }

  /// One log line, representing one of four operations:
  /// `upsertPlacement`, `deletePlacement`, `upsertRecord`, `deleteRecord`.
  /// The `op` discriminator keeps replay dispatch explicit and stable.
  enum LogOp: Codable, Sendable, Equatable {
    case upsertPlacement(placementId: String, placement: ExportPlacement)
    case deletePlacement(placementId: String)
    case upsertRecord(placementId: String, assetId: String, body: RecordBody)
    case deleteRecord(placementId: String, assetId: String)

    private enum CodingKeys: String, CodingKey {
      case op, placementId, placement, assetId, record
    }

    private enum OpDiscriminator: String, Codable {
      case upsertPlacement, deletePlacement, upsertRecord, deleteRecord
    }

    func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      switch self {
      case .upsertPlacement(let placementId, let placement):
        try c.encode(OpDiscriminator.upsertPlacement, forKey: .op)
        try c.encode(placementId, forKey: .placementId)
        try c.encode(placement, forKey: .placement)
      case .deletePlacement(let placementId):
        try c.encode(OpDiscriminator.deletePlacement, forKey: .op)
        try c.encode(placementId, forKey: .placementId)
      case .upsertRecord(let placementId, let assetId, let body):
        try c.encode(OpDiscriminator.upsertRecord, forKey: .op)
        try c.encode(placementId, forKey: .placementId)
        try c.encode(assetId, forKey: .assetId)
        try c.encode(body, forKey: .record)
      case .deleteRecord(let placementId, let assetId):
        try c.encode(OpDiscriminator.deleteRecord, forKey: .op)
        try c.encode(placementId, forKey: .placementId)
        try c.encode(assetId, forKey: .assetId)
      }
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      let op = try c.decode(OpDiscriminator.self, forKey: .op)
      let placementId = try c.decode(String.self, forKey: .placementId)
      switch op {
      case .upsertPlacement:
        let placement = try c.decode(ExportPlacement.self, forKey: .placement)
        self = .upsertPlacement(placementId: placementId, placement: placement)
      case .deletePlacement:
        self = .deletePlacement(placementId: placementId)
      case .upsertRecord:
        let assetId = try c.decode(String.self, forKey: .assetId)
        let body = try c.decode(RecordBody.self, forKey: .record)
        self = .upsertRecord(placementId: placementId, assetId: assetId, body: body)
      case .deleteRecord:
        let assetId = try c.decode(String.self, forKey: .assetId)
        self = .deleteRecord(placementId: placementId, assetId: assetId)
      }
    }
  }

  // MARK: - State

  private let logger = Logger.app(.collectionExportRecords)
  private let ioQueue = DispatchQueue(
    label: "com.valtteriluoma.photo-export.collection-records-io", qos: .utility)

  /// Top-level placement metadata, keyed by placement id. Stale entries from deleted albums
  /// remain here intentionally — they are load-bearing for collision detection and rename
  /// history. Deleted-album placements retain their export history.
  private(set) var placements: [String: ExportPlacement] = [:]
  /// Per-placement record bodies, keyed by `[placementId][assetId]`.
  private(set) var recordBodies: [String: [String: RecordBody]] = [:]

  /// A variant's folder: its placement (whose relative path is fixed at creation) plus
  /// the subfolder it was written into.
  struct ClaimFolder: Hashable, Sendable {
    let placementId: String
    let subfolder: String

    init(placementId: String, subfolder: String?) {
      self.placementId = placementId
      self.subfolder = subfolder ?? ""
    }
  }
  /// Filenames named by any variant record. Built on the first `isFilenameClaimed` query, at
  /// a session's first collection export, and maintained in `apply` after that; nil until
  /// then, and again whenever `recordBodies` is replaced wholesale. See
  /// `ExportRecordStore.filenameClaims` for why it is built lazily.
  private var filenameClaims: FilenameClaims<ClaimFolder>?

  /// Per-store load state. See `RecordStoreState` for semantics.
  @Published private(set) var state: RecordStoreState = .unconfigured
  @Published private(set) var persistenceError: String?
  private var hasUnsavedChanges = false
  // Immediate ownership token, separate from coalesced UI notifications. Any
  // configuration, accepted mutation, reset or newer reconciliation invalidates probes.
  private var reconciliationRevision: UInt64 = 0
  private var finalCommitContext: FinalCommitContext<Snapshot, LogOp>?
  // Only completion deltas survive a corrupt load; full snapshots must not bypass
  // the corruption alert or its explicit reset/forensic-backup path.
  private var deferredFinalCompletions: [String: [() -> Void]] = [:]
  // Final commits acknowledged while their destination loaded, landed once it has finished.
  private var commitsLandedWhileLoading: [String: [() -> Void]] = [:]
  private var configuredDestinationId: String?
  var destinationId: String? { configuredDestinationId }
  // Failed writes must survive destination switches until the user can retry saving.
  private var pendingRecovery: [String: Snapshot] = [:]
  // Each configure starts a new generation; only the newest load is installed.
  private var loadGeneration: UInt64 = 0
  private let latestLoad = RecordStoreLoadGeneration()
  private var settleWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

  @Published private(set) var mutationCounter: Int = 0
  /// `$mutationCounter` for subscribers outside this type: synchronous, delivered before the
  /// value is stored, and replaying the current value (pinned by `PublisherParityTests`).
  var mutationCounterPublisher: AnyPublisher<Int, Never> { $mutationCounter.eraseToAnyPublisher() }

  /// Mirror of `ExportManager.convertHEICToJPEG`. Kept in sync by the manager
  /// (init + didSet on the published property). Read by
  /// `isExported(asset:placement:selection:)` so collection-grid view callers
  /// see the right answers without threading the toggle through every
  /// `@EnvironmentObject` site.
  ///
  /// `@Published` (rather than plain stored) so `@EnvironmentObject` views
  /// re-render when the toggle flips. See `ExportRecordStore`'s sibling
  /// docstring; the same reasoning applies to collection placements.
  @Published var convertHEICToJPEG: Bool = false
  private let notificationClock: any AutoSyncClock
  private lazy var changeNotifier = RecordStoreChangeNotifier(clock: notificationClock) {
    [weak self] in
    self?.mutationCounter &+= 1
  }

  private let fileManager = FileManager.default
  private let recordLogIO: any JSONLRecordLogIO
  private let reconciliationFileChecker: any ReconciliationFileChecking
  let storeRootURL: URL
  private var currentStoreDirURL: URL?
  typealias RecordFile = JSONLRecordFile<Snapshot, LogOp>
  private var jsonl: RecordFile?

  // MARK: - Init

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
  /// returning. Passing `nil` clears in-memory state and detaches from any on-disk files.
  /// Publishes no `.loading`; the app's destination changes use `beginConfigure(for:)`.
  func configure(for destinationId: String?) {
    let signpost = AppDiagnostics.beginConfigure(label: "collection")
    defer { signpost.end() }
    guard let file = startConfiguring(for: destinationId) else { return }
    let inputs = file.readInputs
    let raw = ioQueue.sync { inputs.read() }
    let decoded = inputs.decode(raw)
    finishLoad(
      LoadTicket(generation: loadGeneration, file: file, signpost: nil),
      separator: decoded.needsLogSeparator, outcome: Self.prepare(decoded, logger: logger))
  }

  /// Points the store at a specific destination id and loads its history off the main actor.
  /// The store is `.loading` until the load finishes in one main-actor turn; records read as
  /// empty and mutations are refused meanwhile. `waitUntilSettled()` waits for the load. The
  /// file read is queued behind the previous destination's writes on the IO queue; decoding
  /// and preparing run in a detached task.
  func beginConfigure(for destinationId: String?) {
    let signpost = AppDiagnostics.beginConfigure(label: "collection")
    guard let file = startConfiguring(for: destinationId) else {
      signpost.end()
      return
    }
    setState(.loading)
    changeNotifier.notifyNow()
    let ticket = LoadTicket(generation: loadGeneration, file: file, signpost: signpost)
    let inputs = file.readInputs
    let latestLoad = latestLoad
    let logger = logger
    ioQueue.async(qos: .userInitiated, flags: .enforceQoS) { [weak self] in
      let raw = inputs.read()
      Task.detached(priority: .userInitiated) { [weak self] in
        var separator: Bool?
        var outcome: LoadOutcome?
        if latestLoad.isCurrent(ticket.generation) {
          let decoded = inputs.decode(raw)
          separator = decoded.needsLogSeparator
          outcome = Self.prepare(decoded, logger: logger)
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
    jsonl?.flushForTesting()
    // A parked final commit can fail while another destination is active. Deliver
    // that owner's failure before consulting pendingRecovery or loading it again.
    if let context = finalCommitContext {
      if context.file !== jsonl { context.file.flushForTesting() }
      if context.destinationId == configuredDestinationId,
        state == .ready || hasUnsavedChanges, let file = jsonl
      {
        context.file = file
        context.snapshot = Snapshot(
          version: Constants.snapshotVersion, placements: placements, records: recordBodies)
      }
    }
    if hasUnsavedChanges, let id = configuredDestinationId {
      pendingRecovery[id] = Snapshot(
        version: Constants.snapshotVersion, placements: placements, records: recordBodies)
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

    placements = [:]
    recordBodies = [:]
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
      placements = retained.placements
      recordBodies = retained.records
      filenameClaims = nil
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
      logger.debug("Discarded a collection history load that a newer configure replaced")
      return
    }
    ticket.file.adoptLogSeparator(separator)
    // A claim query during the load built its index from the empty in-memory records.
    filenameClaims = nil
    if let id = configuredDestinationId, let retained = pendingRecovery[id] {
      // A final commit's write failure was parked while the load ran; its history wins.
      placements = retained.placements
      recordBodies = retained.records
      hasUnsavedChanges = true
      persistenceError = Self.retainedProgressMessage
      setState(.persistenceFailed)
    } else {
      switch outcome {
      case .ioFailure(let error):
        persistenceError = error.localizedDescription
        setState(.persistenceFailed)
      case .corrupt:
        logger.error(
          "Collection records snapshot at \(ticket.file.snapshotURL.path, privacy: .public) failed to decode; store transitioning to .failed."
        )
        setState(.failed)
      case .loaded(let prepared):
        placements = prepared.placements
        recordBodies = prepared.recordBodies
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

  /// The placements and records a successful load installs.
  struct PreparedLoad: Sendable {
    let placements: [String: ExportPlacement]
    let recordBodies: [String: [String: RecordBody]]
  }

  /// How a load ends. A failed read outranks a corrupt snapshot, as in `ExportRecordStore`.
  enum LoadOutcome: Sendable {
    case ioFailure(any Error)
    case corrupt
    case loaded(PreparedLoad)
  }

  /// Builds what `configure(for:)` installs from a decoded load: the snapshot without
  /// `.timeline` placements, the log replayed over it, then interrupted variants recovered.
  /// Builds no claim index; that waits for the first claim query.
  nonisolated static func prepare(_ loaded: RecordFile.LoadResult, logger: Logger) -> LoadOutcome {
    if let error = loaded.ioFailure { return .ioFailure(error) }
    switch loaded.snapshotStatus {
    case .corrupt:
      return .corrupt
    case .absent, .loaded:
      var placements: [String: ExportPlacement] = [:]
      var recordBodies: [String: [String: RecordBody]] = [:]
      if let snapshot = loaded.snapshot {
        // Defense in depth: the API entry points reject `.timeline` placements via
        // `accept(_:)`, but a hand-edited or otherwise tampered snapshot file could still
        // carry one. Drop them before they enter `placements` and drop their records too,
        // so the disjoint-key-space invariant holds even on a corrupted-on-disk input.
        var droppedTimelineIds: Set<String> = []
        for (placementId, placement) in snapshot.placements {
          if placement.kind == .timeline {
            droppedTimelineIds.insert(placementId)
          } else {
            placements[placementId] = placement
          }
        }
        if !droppedTimelineIds.isEmpty {
          logger.error(
            "Dropped \(droppedTimelineIds.count) .timeline placement(s) from snapshot; collection store does not hold timeline placements."
          )
        }
        recordBodies = snapshot.records.filter { !droppedTimelineIds.contains($0.key) }
      }
      var noClaims: FilenameClaims<ClaimFolder>?
      for op in loaded.ops {
        apply(
          op, placements: &placements, recordBodies: &recordBodies, claims: &noClaims,
          logger: logger)
      }
      recoverInProgressVariants(in: &recordBodies)
      return .loaded(PreparedLoad(placements: placements, recordBodies: recordBodies))
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
      try jsonl.writeSnapshot(
        Snapshot(version: Constants.snapshotVersion, placements: placements, records: recordBodies))
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
  /// with an empty snapshot + log. See `ExportRecordStore.resetToEmpty` for the same
  /// pattern; the timeline and collection stores recover identically.
  func resetToEmpty() {
    guard state == .failed else { return }
    reconciliationRevision &+= 1
    guard let jsonl else { return }
    do {
      try jsonl.resetToEmpty(emptySnapshot: Snapshot.empty)
      placements = [:]
      recordBodies = [:]
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

  // MARK: - Placement metadata API

  func upsertPlacement(_ placement: ExportPlacement) {
    guard accept(placement) else { return }
    append(.upsertPlacement(placementId: placement.id, placement: placement))
  }

  func deletePlacement(id: String) {
    // `accept(_:)` takes a placement object; this entry point only has an id. Look up the
    // existing placement to validate kind. If we don't know the placement (already deleted
    // or never-recorded), we still allow the no-op `deleteRecord` op to land — a stray
    // delete is harmless. We *do* refuse if the id matches a `.timeline`-kind entry that
    // somehow snuck into memory (the snapshot-decode guard above is the primary defense;
    // this is belt-and-braces).
    if let existing = placements[id], existing.kind == .timeline {
      logger.error(
        "CollectionExportRecordStore.deletePlacement called for a .timeline placement \(id, privacy: .public); drop and ignore."
      )
      return
    }
    append(.deletePlacement(placementId: id))
  }

  /// Current persisted collection slot; caller supplies the Photos tree so this
  /// query remains read-only and never performs framework IO or allocates a placement.
  func currentPlacement(
    for selection: LibrarySelection, collections: [PhotoCollectionDescriptor]
  ) -> ExportPlacement? {
    ExportPlacementResolver().existingCollectionPlacement(
      for: selection, collections: collections, existingPlacements: Array(placements.values))
  }

  func placement(id: String) -> ExportPlacement? {
    placements[id]
  }

  func placements(matching kind: ExportPlacement.Kind) -> [ExportPlacement] {
    if kind == .timeline {
      // The collection store never holds `.timeline` placements (snapshot-decode and
      // log-apply guards enforce that), so an empty array is the correct answer for the
      // `.timeline` query. Log the call so a routing bug surfaces in diagnostics rather
      // than the empty result quietly hiding it.
      logger.error(
        "CollectionExportRecordStore.placements(matching:) called with .timeline; returning empty."
      )
      return []
    }
    return placements.values.filter { $0.kind == kind }
  }

  // MARK: - Record write API

  func upsert(_ record: ScopedExportRecord) {
    guard accept(record.placement) else { return }
    let body = encodeBody(from: record.variants)
    append(
      .upsertRecord(
        placementId: record.placement.id, assetId: record.assetId, body: body))
  }

  /// `subfolder` is the path component inside the placement folder where
  /// the file will land (e.g. `"videos"`). `nil` means the bare placement path. The
  /// value is persisted on the per-variant record so reuse-source and reconcile can
  /// recover each file's true on-disk location regardless of the current setting.
  func markVariantInProgress(
    assetId: String,
    placement: ExportPlacement,
    variant: ExportVariant,
    filename: String?,
    subfolder: String? = nil
  ) {
    guard accept(placement) else { return }
    var body = recordBodies[placement.id]?[assetId] ?? RecordBody(variants: [:])
    var variantRecord =
      body.variants[variant.rawValue]
      ?? ExportVariantRecord(filename: filename, status: .pending, exportDate: nil, lastError: nil)
    variantRecord.filename = filename
    variantRecord.status = .inProgress
    variantRecord.lastError = nil
    variantRecord.reason = nil
    variantRecord.subfolder = subfolder
    body.variants[variant.rawValue] = variantRecord
    append(.upsertRecord(placementId: placement.id, assetId: assetId, body: body))
  }

  /// See `markVariantInProgress` for `subfolder` semantics.
  func markVariantExported(
    assetId: String,
    placement: ExportPlacement,
    variant: ExportVariant,
    filename: String,
    exportedAt: Date,
    subfolder: String? = nil
  ) {
    guard accept(placement) else { return }
    var body = recordBodies[placement.id]?[assetId] ?? RecordBody(variants: [:])
    body.variants[variant.rawValue] = ExportVariantRecord(
      filename: filename, status: .done, exportDate: exportedAt, lastError: nil,
      subfolder: subfolder)
    append(.upsertRecord(placementId: placement.id, assetId: assetId, body: body))
  }

  func markVariantFailed(
    assetId: String,
    placement: ExportPlacement,
    variant: ExportVariant,
    error: String,
    reason: ExportVariantReason? = nil,
    at date: Date
  ) {
    guard accept(placement) else { return }
    var body = recordBodies[placement.id]?[assetId] ?? RecordBody(variants: [:])
    var variantRecord =
      body.variants[variant.rawValue]
      ?? ExportVariantRecord(filename: nil, status: .pending, exportDate: nil, lastError: nil)
    variantRecord.status = .failed
    variantRecord.exportDate = date
    variantRecord.lastError = error
    variantRecord.reason = reason
    body.variants[variant.rawValue] = variantRecord
    append(.upsertRecord(placementId: placement.id, assetId: assetId, body: body))
  }

  func removeVariant(assetId: String, placement: ExportPlacement, variant: ExportVariant) {
    guard accept(placement) else { return }
    guard var body = recordBodies[placement.id]?[assetId] else { return }
    guard body.variants[variant.rawValue] != nil else { return }
    body.variants.removeValue(forKey: variant.rawValue)
    if body.variants.isEmpty {
      append(.deleteRecord(placementId: placement.id, assetId: assetId))
    } else {
      append(.upsertRecord(placementId: placement.id, assetId: assetId, body: body))
    }
  }

  func remove(assetId: String, placement: ExportPlacement) {
    guard accept(placement) else { return }
    guard recordBodies[placement.id]?[assetId] != nil else { return }
    append(.deleteRecord(placementId: placement.id, assetId: assetId))
  }

  // MARK: - Bulk import

  /// One placement's files found by Import Existing Backup.
  struct ImportBatch: Equatable {
    let placement: ExportPlacement
    /// Asset id → the variants found on disk.
    let records: [String: [ExportVariant: ExportVariantRecord]]
  }

  /// Records collection files found by Import Existing Backup, in one synchronous batch.
  /// - A new placement is written before its records. A saved placement with the same id
  ///   keeps its metadata and folder; files found at a different folder are not recorded
  ///   under it.
  /// - A variant already `.done` is left as it is; any other state is replaced.
  /// - Nothing is appended when nothing changes, so importing the same backup again writes
  ///   no bytes.
  /// - A store that is not `.ready` and `.timeline` placements take nothing.
  /// Uses the existing `upsertPlacement` and `upsertRecord` operations only.
  /// `recordedVariantCount(of:)` tells how many of the batches' variants were recorded.
  func bulkImportRecords(_ batches: [ImportBatch]) {
    var imported = 0
    var alreadyDone = 0
    var rejected = 0
    var addedPlacements = 0
    for batch in batches {
      let variantCount = batch.records.values.reduce(0) { $0 + $1.count }
      guard state == .ready, accept(batch.placement) else {
        rejected += variantCount
        continue
      }
      let placement: ExportPlacement
      let isNew: Bool
      if let saved = placements[batch.placement.id] {
        guard saved.relativePath == batch.placement.relativePath else {
          logger.warning(
            "Skipped importing \(variantCount) variants for \(saved.id, privacy: .public): its saved folder differs from the folder they were found in"
          )
          rejected += variantCount
          continue
        }
        placement = saved
        isNew = false
      } else {
        placement = batch.placement
        isNew = true
      }

      var changedBodies: [(assetId: String, body: RecordBody)] = []
      for assetId in batch.records.keys.sorted() {
        var body = recordBodies[placement.id]?[assetId] ?? RecordBody(variants: [:])
        var changed = false
        for (variant, incoming) in batch.records[assetId] ?? [:] {
          if body.variants[variant.rawValue]?.status == .done {
            alreadyDone += 1
            continue
          }
          body.variants[variant.rawValue] = incoming
          imported += 1
          changed = true
        }
        if changed { changedBodies.append((assetId, body)) }
      }
      guard !changedBodies.isEmpty else { continue }
      if isNew {
        append(.upsertPlacement(placementId: placement.id, placement: placement))
        addedPlacements += 1
      }
      for (assetId, body) in changedBodies {
        append(.upsertRecord(placementId: placement.id, assetId: assetId, body: body))
      }
    }
    logger.info(
      "Bulk imported \(imported) collection variants into \(addedPlacements) new placements (\(alreadyDone) already done, \(rejected) not imported)"
    )
  }

  /// How many of the batches' variants the history records as exported now, for reporting
  /// what an import adopted after the reconcile that follows it.
  func recordedVariantCount(of batches: [ImportBatch]) -> Int {
    var count = 0
    for batch in batches {
      guard let placement = placements[batch.placement.id],
        placement.relativePath == batch.placement.relativePath
      else { continue }
      for (assetId, variants) in batch.records {
        let body = recordBodies[placement.id]?[assetId]
        count += variants.keys.filter { body?.variants[$0.rawValue]?.status == .done }.count
      }
    }
    return count
  }

  // MARK: - Reconcile against filesystem

  /// Result of `reconcileAgainstFilesystem(at:)`. Same shape as the timeline store's
  /// summary; the import flow sums both before reporting.
  struct ReconcileSummary: Equatable {
    let prunedVariants: Int
    let prunedRecords: Int

    static let zero = ReconcileSummary(prunedVariants: 0, prunedRecords: 0)
  }

  /// Removes every `.done` variant whose backing file is missing from the destination.
  /// Mirrors the timeline-store reconcile but joins each record body to its
  /// `ExportPlacement` by id to source the on-disk relative path. Invalid metadata,
  /// nonregular targets, lookup errors and an unreadable root reject the entire batch.
  ///
  /// Two-phase: snapshot on main, file checks off-main, mutations on main. Callers
  /// must run this only when no export is active. Obsolete configurations, mutations,
  /// replacement reconciliation or cancelled callers cannot apply the snapshot.
  func reconcileAgainstFilesystem(
    at root: URL, isCurrent: @MainActor () -> Bool = { true }
  ) async throws -> ReconcileSummary {
    guard isCurrent(), !Task.isCancelled, state == .ready else { return .zero }
    reconciliationRevision &+= 1
    let revision = reconciliationRevision

    // Snapshot on main: invalid placement metadata cannot prove a file missing.
    let probes = try completedVariantProbes(root: root)

    // Probe off-main: preserve errors until ownership has been checked.
    let probesCopy = probes
    let fileChecker = reconciliationFileChecker
    // Cancellation stops new probes; a probe in flight finishes first.
    let outcome: Result<[(placementId: String, assetId: String, variantKey: String)], Error> =
      await runDetached {
        do {
          var keys: [(placementId: String, assetId: String, variantKey: String)] = []
          for probe in probesCopy {
            try Task.checkCancellation()
            if try await !fileChecker.isFile(atPath: probe.path) {
              keys.append((probe.placementId, probe.assetId, probe.variantKey))
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

    // Commit on main: apply the whole verified batch synchronously.
    var prunedVariants = 0
    var prunedRecords = 0
    for (placementId, assetId, variantKey) in toPrune {
      guard var body = recordBodies[placementId]?[assetId] else { continue }
      guard body.variants.removeValue(forKey: variantKey) != nil else { continue }
      prunedVariants += 1
      if body.variants.isEmpty {
        append(.deleteRecord(placementId: placementId, assetId: assetId))
        prunedRecords += 1
      } else {
        append(.upsertRecord(placementId: placementId, assetId: assetId, body: body))
      }
    }
    logger.info(
      "Reconciled collections: pruned \(prunedVariants) variants, \(prunedRecords) records"
    )
    return ReconcileSummary(
      prunedVariants: prunedVariants, prunedRecords: prunedRecords)
  }

  private struct CompletedVariantProbe: Sendable {
    let placementId: String
    let assetId: String
    let variantKey: String
    let path: String
  }

  private func completedVariantProbes(root: URL) throws -> [CompletedVariantProbe] {
    var probes: [CompletedVariantProbe] = []
    for (placementId, byAsset) in recordBodies {
      guard let placement = placements[placementId] else {
        throw ReconciliationVerificationError(
          path: root.path, detail: "History is missing a placement")
      }
      for (assetId, body) in byAsset {
        for (variantKey, vr) in body.variants where vr.status == .done {
          // per-variant subfolder. A standalone-video asset's variants
          // may live in `<placement>/videos/`, while image-asset variants live at
          // the bare placement path. Probe each variant against its own stored
          // subfolder.
          let path = try ReconciliationFileChecker.filePath(
            root: root, placement: placement, filename: vr.filename, subfolder: vr.subfolder)
          probes.append(
            CompletedVariantProbe(
              placementId: placementId, assetId: assetId, variantKey: variantKey, path: path))
        }
      }
    }
    return probes
  }

  /// Whether any completed variant's file is under `root`, or `nil` when there is no completed
  /// variant to look for (or the store isn't ready). Read-only, like the timeline store's.
  func containsCompletedFile(
    at root: URL, isCurrent: @MainActor () -> Bool = { true }
  ) async throws -> Bool? {
    guard isCurrent(), !Task.isCancelled, state == .ready else { return nil }
    let paths = try completedVariantProbes(root: root).map(\.path)
    guard !paths.isEmpty else { return nil }
    let fileChecker = reconciliationFileChecker
    return try await runDetached { try await fileChecker.containsAnyFile(paths, root: root) }
  }

  // MARK: - Read API

  func exportInfo(assetId: String, placement: ExportPlacement) -> ScopedExportRecord? {
    guard accept(placement) else { return nil }
    guard let body = recordBodies[placement.id]?[assetId] else { return nil }
    var variantMap: [ExportVariant: ExportVariantRecord] = [:]
    for (rawKey, value) in body.variants {
      if let variant = ExportVariant(rawValue: rawKey) {
        variantMap[variant] = value
      }
    }
    return ScopedExportRecord(placement: placement, assetId: assetId, variants: variantMap)
  }

  /// Whether a record names `filename` in the folder for `placement` and `subfolder`, apart
  /// from `assetId`'s own `variant`. The asset's other variants count.
  func isFilenameClaimed(
    _ filename: String, placement: ExportPlacement, subfolder: String?,
    exceptVariant variant: ExportVariant, of assetId: String
  ) -> Bool {
    isFilenameClaimed(
      filename, placement: placement, subfolder: subfolder, assetId: assetId,
      excluding: { $0 == variant.rawValue })
  }

  /// Whether another asset's record names `filename` in the folder for `placement` and
  /// `subfolder`. None of `assetId`'s own variants in the placement count.
  func isFilenameClaimed(
    _ filename: String, placement: ExportPlacement, subfolder: String?,
    exceptAsset assetId: String
  ) -> Bool {
    isFilenameClaimed(
      filename, placement: placement, subfolder: subfolder, assetId: assetId,
      excluding: { _ in true })
  }

  private func isFilenameClaimed(
    _ filename: String, placement: ExportPlacement, subfolder: String?, assetId: String,
    excluding isOwn: (String) -> Bool
  ) -> Bool {
    let variants = recordBodies[placement.id]?[assetId]?.variants ?? [:]
    let own = variants.filter { isOwn($0.key) }.values.map {
      (
        filename: $0.filename,
        folder: ClaimFolder(placementId: placement.id, subfolder: $0.subfolder)
      )
    }
    let folder = ClaimFolder(placementId: placement.id, subfolder: subfolder)
    return currentFilenameClaims().count(filename, in: folder, excluding: own) > 0
  }

  /// True when every required variant for `asset` under `selection` is `.done`, OR the
  /// asset is covered by the edited-fallback case (see
  /// `ExportCompletionPolicy.satisfiesEditedFallback`). Collection placements derive the
  /// `VariantPolicy` from `placement.kind` so shared-album single-resource clamping
  /// applies correctly.
  /// `livePhotosPaired` is REQUIRED — no default. Every UI call site that
  /// surfaces "is this asset exported?" must consider whether the user has opted into
  /// paired-video accounting. Tests pass `livePhotosPaired: false` explicitly when the
  /// scenario doesn't involve Live Photos; the small extra boilerplate catches the
  /// silent-regression class at compile time. Mirrors `ExportRecordStore.isExported`.
  func isExported(
    asset: AssetDescriptor,
    placement: ExportPlacement,
    selection: ExportVersionSelection,
    livePhotosPaired: Bool
  ) -> Bool {
    guard accept(placement) else { return false }
    guard let body = recordBodies[placement.id]?[asset.id] else { return false }
    return ExportCompletionPolicy.isComplete(
      variants: body.typedVariants, asset: asset, selection: selection,
      policy: placement.kind.variantPolicy,
      convertHEICToJPEG: convertHEICToJPEG,
      livePhotosPaired: livePhotosPaired)
  }

  // MARK: - Scoped queries

  func recordCount(in scope: CollectionPlacementScope) -> Int {
    var count = 0
    for (placementId, byAsset) in recordBodies {
      guard let placement = placements[placementId] else { continue }
      let matches: Bool
      switch scope {
      case .favorites: matches = (placement.kind == .favorites)
      case .album(let id):
        matches = (placement.kind == .album && placement.collectionLocalIdentifier == id)
      case .sharedAlbum(let id):
        matches =
          (placement.kind == .sharedAlbum && placement.collectionLocalIdentifier == id)
      case .any:
        matches =
          (placement.kind == .favorites || placement.kind == .album
            || placement.kind == .sharedAlbum)
      }
      if matches {
        count += byAsset.count
      }
    }
    return count
  }

  /// Asset-aware summary used by the collection grid header (`CollectionContentView`).
  /// Mirrors `ExportRecordStore.monthSummary(assets:selection:)` on the timeline side:
  /// the caller supplies the visible asset list, the store evaluates each asset's
  /// `requiredVariants(for:selection:)` against its variant records under `placement.id`,
  /// and the result counts only assets that are in the current scope. This avoids the
  /// drift `summary(for:)` would show when a user has removed photos from an album: the
  /// store still holds historical records for those assets but the visible grid no longer
  /// includes them, so a record-keyed total would over-report.
  func monthSummary(
    assets: [AssetDescriptor], placement: ExportPlacement, selection: ExportVersionSelection,
    livePhotosPaired: Bool
  ) -> MonthStatusSummary {
    guard accept(placement) else {
      return MonthStatusSummary(
        year: 0, month: 0, exportedCount: 0, totalCount: assets.count, status: .notExported)
    }
    var exported = 0
    for asset in assets
    where isExported(
      asset: asset, placement: placement, selection: selection,
      livePhotosPaired: livePhotosPaired)
    {
      exported += 1
    }
    let status: MonthExportStatus
    if assets.isEmpty {
      status = .notExported
    } else if exported >= assets.count {
      status = .complete
    } else if exported == 0 {
      status = .notExported
    } else {
      status = .partial
    }
    return MonthStatusSummary(
      year: 0, month: 0, exportedCount: exported, totalCount: assets.count, status: status)
  }

  func summary(for placement: ExportPlacement) -> PlacementSummary {
    guard accept(placement) else {
      return PlacementSummary(
        placementId: placement.id, exportedCount: 0, totalCount: 0, status: .notExported)
    }
    let bodies = recordBodies[placement.id] ?? [:]
    let total = bodies.count
    var done = 0
    for (_, body) in bodies
    where body.variants.values.contains(where: { $0.status == .done }) {
      done += 1
    }
    let status: MonthExportStatus
    if total == 0 {
      status = .notExported
    } else if done >= total {
      status = .complete
    } else if done == 0 {
      status = .notExported
    } else {
      status = .partial
    }
    return PlacementSummary(
      placementId: placement.id, exportedCount: done, totalCount: total, status: status)
  }

  // MARK: - Testing helpers

  /// Blocks until pending IO is flushed.
  func flushForTesting() {
    jsonl?.flushForTesting()
  }

  /// Captures the existing writer before physical final IO. A successful move is
  /// acknowledged even after cancellation; failure retains history for Retry. The
  /// acknowledgement carries the name the file was committed or adopted under, or `nil`
  /// when nothing was committed.
  func captureFinalCommit(
    assetId: String, variant: ExportVariant, placement: ExportPlacement,
    subfolder: String?, acceptsEditedFallback: Bool
  ) throws -> (_ finalFilename: String?) async -> Void {
    guard state == .ready, let destinationId = configuredDestinationId, let file = jsonl else {
      throw RecordPersistenceUnavailable()
    }
    precondition(finalCommitContext == nil, "Final commits must be serialized")
    let context = FinalCommitContext(
      destinationId: destinationId, file: file,
      snapshot: Snapshot(
        version: Constants.snapshotVersion, placements: [:], records: [:]))
    finalCommitContext = context
    let applyCompletion = { [weak self] (filename: String) in
      guard let self else { return }
      if self.placements[placement.id] == nil { self.upsertPlacement(placement) }
      let date = Date()
      self.markVariantExported(
        assetId: assetId, placement: placement, variant: variant,
        filename: filename, exportedAt: date, subfolder: subfolder)
      if acceptsEditedFallback {
        self.markVariantFailed(
          assetId: assetId, placement: placement, variant: .edited,
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
      if context.snapshot.placements[placement.id] == nil {
        context.snapshot.placements[placement.id] = placement
        context.file.append(
          .upsertPlacement(placementId: placement.id, placement: placement),
          currentSnapshot: { context.snapshot })
      }
      var body = context.snapshot.records[placement.id]?[assetId] ?? RecordBody(variants: [:])
      body.variants[variant.rawValue] = done
      if acceptsEditedFallback {
        // As `markVariantFailed` does: a new edited record names no file.
        var edited =
          body.variants[ExportVariant.edited.rawValue]
          ?? ExportVariantRecord(filename: nil, status: .pending, exportDate: nil, lastError: nil)
        edited.status = .failed
        edited.exportDate = exportedAt
        edited.lastError = ExportVariantRecovery.editedUnavailableOriginalBackedUpMessage
        edited.reason = .editedUnavailableOriginalBackedUp
        body.variants[ExportVariant.edited.rawValue] = edited
      }
      context.snapshot.records[placement.id, default: [:]][assetId] = body
      context.file.append(
        .upsertRecord(placementId: placement.id, assetId: assetId, body: body),
        currentSnapshot: { context.snapshot })
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
    _ filename: String, context: FinalCommitContext<Snapshot, LogOp>,
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
        context.file.flushForTesting()
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
    _ filename: String, context: FinalCommitContext<Snapshot, LogOp>,
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
      placements = context.snapshot.placements
      recordBodies = context.snapshot.records
      filenameClaims = nil
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
    _ error: any Error, context: FinalCommitContext<Snapshot, LogOp>
  ) {
    let isActive = configuredDestinationId == context.destinationId
    // While the destination loads, its in-memory records are empty and must not replace the
    // commit's own snapshot; the finished load installs what is parked here.
    let isLoading = isActive && state == .loading
    if isActive && !isLoading {
      // Active state is already current; snapshot only on failure, avoiding a full
      // dictionary CoW on every ordinary successful file commit.
      context.snapshot = Snapshot(
        version: Constants.snapshotVersion, placements: placements, records: recordBodies)
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

  /// Validates that this store should accept the placement. Returns `false` and logs an
  /// error when given a `.timeline` placement; the store is then a no-op for the call.
  /// Combined with the snapshot-decode and log-replay guards in `apply(_:)` and
  /// `configure(for:)`, this is one of three layers that uphold the disjoint-key-space
  /// invariant — a `.timeline` placement should never enter the collection store via any
  /// path. (Earlier versions tripped `assertionFailure` here, which made the rejection
  /// path untestable in debug builds; the routing-bug surfacing now happens via `Logger`
  /// instead so tests can exercise every API entry point.)
  private func accept(_ placement: ExportPlacement) -> Bool {
    if placement.kind == .timeline {
      logger.error(
        "CollectionExportRecordStore received a .timeline placement \(placement.id, privacy: .public); routing bug — drop and ignore. Timeline placements belong in ExportRecordStore."
      )
      return false
    }
    return true
  }

  private func append(_ op: LogOp) {
    // Keep an in-flight export's final filename in memory after a write failure,
    // so Retry can save it without exporting the file again. Failed loads stay read-only.
    guard state == .ready || (state == .persistenceFailed && hasUnsavedChanges) else {
      return
    }
    reconciliationRevision &+= 1
    apply(op)
    if let context = finalCommitContext, context.destinationId == configuredDestinationId,
      let file = jsonl
    {
      context.file = file
    }
    scheduleCoalescedNotify()
    guard state == .ready, let jsonl else { return }
    jsonl.append(
      op,
      currentSnapshot: {
        Snapshot(
          version: Constants.snapshotVersion,
          placements: self.placements,
          records: self.recordBodies)
      })
  }

  private func apply(_ op: LogOp) {
    Self.apply(
      op, placements: &placements, recordBodies: &recordBodies, claims: &filenameClaims,
      logger: logger)
  }

  /// Applies one log operation to `placements` and `recordBodies`, keeping `claims` current
  /// when there is an index. Shared by mutations and the load's replay.
  nonisolated static func apply(
    _ op: LogOp, placements: inout [String: ExportPlacement],
    recordBodies: inout [String: [String: RecordBody]], claims: inout FilenameClaims<ClaimFolder>?,
    logger: Logger
  ) {
    switch op {
    case .upsertPlacement(let placementId, let placement):
      // Defense in depth — same rationale as the snapshot-decode guard. A `.timeline`
      // placement must never enter the collection store, even via log replay.
      if placement.kind == .timeline {
        logger.error(
          "Skipping .timeline placement \(placementId, privacy: .public) on apply; collection store does not hold timeline placements."
        )
        return
      }
      placements[placementId] = placement
    case .deletePlacement(let placementId):
      placements.removeValue(forKey: placementId)
      if let removed = recordBodies.removeValue(forKey: placementId) {
        for body in removed.values {
          updateClaims(&claims, placementId: placementId, body: body, adding: false)
        }
      }
    case .upsertRecord(let placementId, let assetId, let body):
      // Reject orphan records: the on-disk format requires every record to reference an
      // existing placement. If a log truncation or partial write loses the upsertPlacement
      // line but preserves a later upsertRecord line, replaying would otherwise write a
      // record under a placement id with no metadata — and the next compaction would
      // freeze the orphan into the snapshot. Skip with a log line so the issue is
      // observable but doesn't corrupt the store.
      guard placements[placementId] != nil else {
        logger.error(
          "Skipping upsertRecord for unknown placementId \(placementId, privacy: .public) (assetId=\(assetId, privacy: .public)); placement metadata missing."
        )
        return
      }
      var byAsset = recordBodies[placementId] ?? [:]
      if let old = byAsset.updateValue(body, forKey: assetId) {
        updateClaims(&claims, placementId: placementId, body: old, adding: false)
      }
      updateClaims(&claims, placementId: placementId, body: body, adding: true)
      recordBodies[placementId] = byAsset
    case .deleteRecord(let placementId, let assetId):
      var byAsset = recordBodies[placementId] ?? [:]
      if let old = byAsset.removeValue(forKey: assetId) {
        updateClaims(&claims, placementId: placementId, body: old, adding: false)
      }
      if byAsset.isEmpty {
        recordBodies.removeValue(forKey: placementId)
      } else {
        recordBodies[placementId] = byAsset
      }
    }
  }

  nonisolated private static func updateClaims(
    _ claims: inout FilenameClaims<ClaimFolder>?, placementId: String, body: RecordBody,
    adding: Bool
  ) {
    guard claims != nil else { return }
    update(&claims!, placementId: placementId, body: body, adding: adding)
  }

  nonisolated private static func update(
    _ claims: inout FilenameClaims<ClaimFolder>, placementId: String, body: RecordBody,
    adding: Bool
  ) {
    for variant in body.variants.values {
      let folder = ClaimFolder(placementId: placementId, subfolder: variant.subfolder)
      if adding {
        claims.add(variant.filename, in: folder)
      } else {
        claims.remove(variant.filename, in: folder)
      }
    }
  }

  private func currentFilenameClaims() -> FilenameClaims<ClaimFolder> {
    if let filenameClaims { return filenameClaims }
    let claims = Self.buildClaims(from: recordBodies, logger: logger)
    filenameClaims = claims
    return claims
  }

  /// The claim index for `recordBodies`: every filename a variant names, in its folder.
  nonisolated static func buildClaims(
    from recordBodies: [String: [String: RecordBody]], logger: Logger
  ) -> FilenameClaims<ClaimFolder> {
    let recordCount = recordBodies.values.reduce(0) { $0 + $1.count }
    return FilenameClaims<ClaimFolder>.build(recordCount: recordCount, logger: logger) {
      claims in
      for (placementId, byAsset) in recordBodies {
        for body in byAsset.values {
          update(&claims, placementId: placementId, body: body, adding: true)
        }
      }
    }
  }

  /// Converts any variant left as `.inProgress` after load into `.failed` with the
  /// interrupted message. In-memory only — the corrected status flows to disk on the next
  /// mutation that lands for the same `(placement, asset)` pair, mirroring the timeline
  /// store's existing lazy-correction behavior.
  nonisolated static func recoverInProgressVariants(
    in recordBodies: inout [String: [String: RecordBody]]
  ) {
    for (placementId, byAsset) in recordBodies {
      var mutatedByAsset = byAsset
      var changedAny = false
      for (assetId, body) in byAsset {
        var mutated = body
        var changed = false
        for (rawKey, variantRecord) in body.variants where variantRecord.status == .inProgress {
          var next = variantRecord
          next.status = .failed
          next.lastError = ExportVariantRecovery.interruptedMessage
          next.reason = .interrupted
          mutated.variants[rawKey] = next
          changed = true
        }
        if changed {
          mutatedByAsset[assetId] = mutated
          changedAny = true
        }
      }
      if changedAny {
        recordBodies[placementId] = mutatedByAsset
      }
    }
  }

  private func encodeBody(from variants: [ExportVariant: ExportVariantRecord]) -> RecordBody {
    var stringKeyed: [String: ExportVariantRecord] = [:]
    for (variant, record) in variants {
      stringKeyed[variant.rawValue] = record
    }
    return RecordBody(variants: stringKeyed)
  }

  private func createDirectoryIfNeeded(_ url: URL) {
    if !fileManager.fileExists(atPath: url.path) {
      do { try fileManager.createDirectory(at: url, withIntermediateDirectories: true) } catch {
        logger.error(
          "Failed to create collection store directory: \(String(describing: error), privacy: .public)"
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
}
