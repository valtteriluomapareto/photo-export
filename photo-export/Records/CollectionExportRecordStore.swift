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
      Dictionary(uniqueKeysWithValues: variants.compactMap { key, value in
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

  /// One log line. The plan calls for four ops:
  /// `upsertPlacement`, `deletePlacement`, `upsertRecord`, `deleteRecord`.
  /// Encoded with a discriminator field `op` to match the plan's JSON example exactly.
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

  private let logger = Logger(
    subsystem: "com.valtteriluoma.photo-export", category: "CollectionExportRecords")
  private let ioQueue = DispatchQueue(
    label: "com.valtteriluoma.photo-export.collection-records-io", qos: .utility)

  /// Top-level placement metadata, keyed by placement id. Stale entries from deleted albums
  /// remain here intentionally — they are load-bearing for collision detection and rename
  /// history. Cleanup of deleted-album placements is out of scope for this plan.
  private(set) var placements: [String: ExportPlacement] = [:]
  /// Per-placement record bodies, keyed by `[placementId][assetId]`.
  private(set) var recordBodies: [String: [String: RecordBody]] = [:]

  /// Per-store load state. See `RecordStoreState` for semantics.
  @Published private(set) var state: RecordStoreState = .unconfigured

  @Published private(set) var mutationCounter: Int = 0

  /// Mirror of `ExportManager.convertHEICToJPEG`. Kept in sync by the manager
  /// (init + didSet on the published property). Read by
  /// `isExported(asset:placement:selection:)` so collection-grid view callers
  /// see the right answers without threading the toggle through every
  /// `@EnvironmentObject` site. Issue #47.
  ///
  /// `@Published` (rather than plain stored) so `@EnvironmentObject` views
  /// re-render when the toggle flips. See `ExportRecordStore`'s sibling
  /// docstring; the same reasoning applies to collection placements.
  @Published var convertHEICToJPEG: Bool = false
  private var notifyWorkItem: DispatchWorkItem?

  private let fileManager = FileManager.default
  let storeRootURL: URL
  private var currentStoreDirURL: URL?
  private var jsonl: JSONLRecordFile<Snapshot, LogOp>?

  // MARK: - Init

  init() {
    let appSupport = try! fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let bundleId = Bundle.main.bundleIdentifier ?? "com.valtteriluoma.photo-export"
    let root = appSupport.appendingPathComponent(bundleId, isDirectory: true)
    let storeDir = root.appendingPathComponent("ExportRecords", isDirectory: true)
    self.storeRootURL = storeDir
    createDirectoryIfNeeded(storeDir)
  }

  /// Test-only: allow specifying a base directory for the store root.
  init(baseDirectoryURL: URL) {
    self.storeRootURL = baseDirectoryURL
    createDirectoryIfNeeded(baseDirectoryURL)
  }

  // MARK: - Destination configuration

  /// Points the store at a specific destination id (subdirectory). Passing `nil` clears
  /// in-memory state and detaches from any on-disk files.
  func configure(for destinationId: String?) {
    let signpost = AppDiagnostics.beginConfigure(label: "collection")
    defer { AppDiagnostics.endConfigure(signpost, label: "collection") }

    placements = [:]
    recordBodies = [:]

    guard let destinationId else {
      currentStoreDirURL = nil
      jsonl = nil
      state = .unconfigured
      mutationCounter &+= 1
      return
    }

    let dir = storeRootURL.appendingPathComponent(destinationId, isDirectory: true)
    createDirectoryIfNeeded(dir)
    currentStoreDirURL = dir
    let file = JSONLRecordFile<Snapshot, LogOp>(
      snapshotURL: dir.appendingPathComponent(Constants.snapshotFileName),
      logURL: dir.appendingPathComponent(Constants.logFileName),
      ioQueue: ioQueue,
      logger: logger
    )
    jsonl = file

    let loaded = file.load()
    switch loaded.snapshotStatus {
    case .corrupt:
      logger.error(
        "Collection records snapshot at \(dir.appendingPathComponent(Constants.snapshotFileName).path, privacy: .public) failed to decode; store transitioning to .failed."
      )
      state = .failed
    case .absent, .loaded:
      if let snapshot = loaded.snapshot {
        // Defense in depth: the API entry points reject `.timeline` placements via
        // `accept(_:)`, but a hand-edited or otherwise tampered snapshot file could still
        // carry one. Drop them before they enter `placements` and drop their records too,
        // so the disjoint-key-space invariant holds even on a corrupted-on-disk input.
        var validPlacements: [String: ExportPlacement] = [:]
        var droppedTimelineIds: Set<String> = []
        for (placementId, placement) in snapshot.placements {
          if placement.kind == .timeline {
            droppedTimelineIds.insert(placementId)
          } else {
            validPlacements[placementId] = placement
          }
        }
        if !droppedTimelineIds.isEmpty {
          logger.error(
            "Dropped \(droppedTimelineIds.count) .timeline placement(s) from snapshot; collection store does not hold timeline placements."
          )
        }
        placements = validPlacements
        recordBodies = snapshot.records.filter { !droppedTimelineIds.contains($0.key) }
      }
      for op in loaded.ops {
        apply(op)
      }
      recoverInProgressVariants()
      state = .ready
    }
    mutationCounter &+= 1
  }

  /// Renames a corrupt snapshot to `<name>.broken-<ISO8601>` and reinitializes the store
  /// with an empty snapshot + log. See `ExportRecordStore.resetToEmpty` for the same
  /// pattern; the timeline and collection stores recover identically.
  func resetToEmpty() {
    guard state == .failed else { return }
    guard let jsonl else { return }
    do {
      try jsonl.resetToEmpty(emptySnapshot: Snapshot.empty)
      placements = [:]
      recordBodies = [:]
      state = .ready
      mutationCounter &+= 1
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

  /// `subfolder` (issue #38) is the path component inside the placement folder where
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
  /// `ExportPlacement` by id to source the on-disk relative path. Record bodies whose
  /// placement metadata is gone (orphans) are pruned wholesale — they're
  /// unreconcilable garbage with no path to check.
  ///
  /// Two-phase: snapshot on main, file checks off-main, mutations on main. Callers
  /// must run this only when no export is active.
  func reconcileAgainstFilesystem(at root: URL) async -> ReconcileSummary {
    guard state == .ready else { return .zero }

    struct Probe: Sendable {
      let placementId: String
      let assetId: String
      let variantKey: String
      let path: String
      let isCorrupt: Bool
    }
    var probes: [Probe] = []
    var orphanDeletes: [(placementId: String, assetId: String)] = []

    // Phase 1 (main): snapshot. Orphan-body keys (placementId not in `placements`)
    // are queued for direct deletion; everything else is probed.
    for (placementId, byAsset) in recordBodies {
      guard let placement = placements[placementId] else {
        for assetId in byAsset.keys {
          orphanDeletes.append((placementId, assetId))
        }
        continue
      }
      for (assetId, body) in byAsset {
        for (variantKey, vr) in body.variants where vr.status == .done {
          guard let filename = vr.filename else {
            probes.append(
              Probe(
                placementId: placementId, assetId: assetId, variantKey: variantKey,
                path: "", isCorrupt: true))
            continue
          }
          // Issue #38: per-variant subfolder. A standalone-video asset's variants
          // may live in `<placement>/videos/`, while image-asset variants live at
          // the bare placement path. Probe each variant against its own stored
          // subfolder.
          let dirRelPath = ExportPlacementPathPolicy.relativePath(
            placement: placement, subfolder: vr.subfolder)
          let path = root.appendingPathComponent(dirRelPath)
            .appendingPathComponent(filename).path
          probes.append(
            Probe(
              placementId: placementId, assetId: assetId, variantKey: variantKey,
              path: path, isCorrupt: false))
        }
      }
    }

    // Phase 2 (off-main): file checks.
    let probesCopy = probes
    let toPrune: [(placementId: String, assetId: String, variantKey: String)] = await Task.detached
    {
      let fm = FileManager.default
      var keys: [(placementId: String, assetId: String, variantKey: String)] = []
      for probe in probesCopy {
        if probe.isCorrupt {
          keys.append((probe.placementId, probe.assetId, probe.variantKey))
          continue
        }
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: probe.path, isDirectory: &isDir)
        if !exists || isDir.boolValue {
          keys.append((probe.placementId, probe.assetId, probe.variantKey))
        }
      }
      return keys
    }.value

    // Phase 3 (main): apply mutations. Orphan bodies first, then variant prunes.
    var prunedVariants = 0
    var prunedRecords = 0
    for (placementId, assetId) in orphanDeletes {
      guard recordBodies[placementId]?[assetId] != nil else { continue }
      append(.deleteRecord(placementId: placementId, assetId: assetId))
      prunedRecords += 1
    }
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
      "Reconciled collections: pruned \(prunedVariants) variants, \(prunedRecords) records (incl. orphan bodies)"
    )
    return ReconcileSummary(
      prunedVariants: prunedVariants, prunedRecords: prunedRecords)
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

  /// True when every required variant for `asset` under `selection` is `.done`, OR the
  /// asset is covered by the issue #22 edited-fallback case (see
  /// `ExportCompletionPolicy.satisfiesEditedFallback`). Collection placements derive the
  /// `VariantPolicy` from `placement.kind` so shared-album single-resource clamping
  /// applies correctly.
  /// `livePhotosPaired` (issue #49) is REQUIRED — no default. Every UI call site that
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
    ioQueue.sync {}
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
    // RecordStoreState guard — see `ExportRecordStore.append` for the rationale.
    // .failed = corrupt snapshot, deferred-rename rule; .unconfigured = no destination.
    // Either way: silent no-op (assertionFailure in debug to surface routing bugs).
    guard state == .ready else {
      assertionFailure(
        "CollectionExportRecordStore.append called while state == \(state); ExportManager should have routed via canExport."
      )
      return
    }
    apply(op)
    scheduleCoalescedNotify()
    guard let jsonl else { return }
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
      recordBodies.removeValue(forKey: placementId)
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
      byAsset[assetId] = body
      recordBodies[placementId] = byAsset
    case .deleteRecord(let placementId, let assetId):
      var byAsset = recordBodies[placementId] ?? [:]
      byAsset.removeValue(forKey: assetId)
      if byAsset.isEmpty {
        recordBodies.removeValue(forKey: placementId)
      } else {
        recordBodies[placementId] = byAsset
      }
    }
  }

  /// Converts any variant left as `.inProgress` after load into `.failed` with the
  /// interrupted message. In-memory only — the corrected status flows to disk on the next
  /// mutation that lands for the same `(placement, asset)` pair, mirroring the timeline
  /// store's existing lazy-correction behavior.
  private func recoverInProgressVariants() {
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
    notifyWorkItem?.cancel()
    let item = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.mutationCounter &+= 1
    }
    notifyWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
  }
}
