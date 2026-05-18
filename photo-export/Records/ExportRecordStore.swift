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

  private let logger = Logger(
    subsystem: "com.valtteriluoma.photo-export", category: "ExportRecords")
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
  private struct MonthKey: Hashable {
    let year: Int
    let month: Int
  }
  private struct MonthCounters {
    /// Per-variant, per-status occurrence count.
    var variantStatus: [ExportVariant: [ExportStatus: Int]] = [:]
    /// Records where both `.original` and `.edited` variants are `.done`.
    var bothVariantsDone: Int = 0
    /// Records where `.original.done` at a natural-stem filename (not `_orig`-companion)
    /// AND `.edited` is not `.done`. The records-only sidebar formula's "unedited asset
    /// exported once" estimator depends on this.
    var originalDoneAtNaturalStem: Int = 0
    /// Records covered by the issue #22 fallback: `.original.done` AND
    /// `.edited.failed` with the explicit
    /// `editedUnavailableOriginalBackedUpMessage` sentinel that
    /// `runEditedFallbackOriginal` writes after a successful `_orig` write.
    /// These represent adjusted assets where Photos refused the edit and the
    /// pipeline wrote the original as a fallback. Without this counter, the
    /// sidebar's records-only formula would never count fallback-covered
    /// records, leaving years stuck at 99% even after `isExported` correctly
    /// recognises them as covered.
    var editedFallbackCovered: Int = 0
    static let zero = MonthCounters()
  }
  private var monthCounters: [MonthKey: MonthCounters] = [:]

  /// Per-store load state. See `RecordStoreState` for semantics. The corruption alert UI
  /// that drives `resetToEmpty()` lives in Phase 4; before then, a `.failed` state is
  /// observable in logs and tests but not surfaced to the user.
  @Published private(set) var state: RecordStoreState = .unconfigured

  // Published bump used to notify SwiftUI of logical changes
  @Published private(set) var mutationCounter: Int = 0

  /// Mirror of `ExportManager.convertHEICToJPEG`. Kept in sync by the manager
  /// (init + didSet on the published property). Read by `isExported(asset:
  /// selection:)` and `monthSummary(assets:selection:)` so view-side
  /// `@EnvironmentObject` callers see the right answers without having to
  /// thread the toggle through five call sites (timeline grid, year tiles,
  /// sidebar badges, content-pane summary, etc.). Issue #47.
  ///
  /// `@Published` so views with `@EnvironmentObject private var
  /// exportRecordStore: ExportRecordStore` re-render when the toggle flips.
  /// `MonthContentView` is `Equatable` over a stable value set and is not
  /// otherwise re-evaluated on toggle changes, so without the publish here
  /// "exported" thumbnail badges would stay stale until the next mutation.
  /// Change rate is zero outside user-toggle clicks, so no render-storm
  /// concern.
  @Published var convertHEICToJPEG: Bool = false
  private var notifyWorkItem: DispatchWorkItem?

  private let fileManager = FileManager.default
  /// Base directory containing per-destination subdirectories
  /// (`<App Support>/<bundleId>/ExportRecords/`). Exposed for
  /// `ExportRecordsDirectoryCoordinator`, which needs to manage
  /// the per-destination subdirectory before this store configures.
  let storeRootURL: URL
  private var currentStoreDirURL: URL?
  /// JSONL persistence for the currently configured destination. `nil` when the store is
  /// unconfigured (no destination selected). Reconstructed on every `configure(for:)`.
  private var jsonl: JSONLRecordFile<[String: ExportRecord], ExportRecordMutation>?

  init() {
    let appSupport = try! fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let bundleId = Bundle.main.bundleIdentifier ?? "com.valtteriluoma.photo-export"
    let root = appSupport.appendingPathComponent(bundleId, isDirectory: true)
    let storeDir = root.appendingPathComponent(Constants.directoryName, isDirectory: true)
    self.storeRootURL = storeDir
    createDirectoryIfNeeded(storeDir)
  }

  // Test-only/init-injection: allow specifying a base directory for the store root
  init(baseDirectoryURL: URL) {
    self.storeRootURL = baseDirectoryURL
    createDirectoryIfNeeded(baseDirectoryURL)
  }

  // MARK: - Destination configuration
  /// Points the store at a specific destination id (subdirectory). Passing nil clears state (shows empty).
  func configure(for destinationId: String?) {
    // Reset in-memory state
    recordsById = [:]
    monthCounters = [:]

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
    let file = JSONLRecordFile<[String: ExportRecord], ExportRecordMutation>(
      snapshotURL: dir.appendingPathComponent(Constants.snapshotFileName),
      logURL: dir.appendingPathComponent(Constants.logFileName),
      ioQueue: ioQueue,
      logger: logger
    )
    jsonl = file

    let loaded = file.load()
    switch loaded.snapshotStatus {
    case .corrupt:
      // Deferred-rename rule: leave the corrupt snapshot at its original path on disk so
      // a Quit-and-relaunch reproduces this `.failed` state instead of silently
      // initializing empty. `resetToEmpty()` is the only path that renames the file out
      // of the way; the alert UI that calls it lands in Phase 4.
      logger.error(
        "Timeline records snapshot at \(dir.appendingPathComponent(Constants.snapshotFileName).path, privacy: .public) failed to decode; store transitioning to .failed."
      )
      state = .failed
    case .absent, .loaded:
      if let snapshot = loaded.snapshot {
        recordsById = snapshot
      }
      // During load, apply each op directly to `recordsById` without touching
      // `monthCounters` — incrementally updating against an empty counter map would
      // produce negative counts for keys whose snapshot value should be subtracted.
      // After all ops are applied and recovery runs, rebuild counters once from the
      // final `recordsById`.
      for op in loaded.ops {
        apply(op, recordCounters: false)
      }
      recoverInProgressVariants()
      rebuildCountersFromRecords()
      state = .ready
    }
    mutationCounter &+= 1
  }

  /// Renames a corrupt snapshot to `<name>.broken-<ISO8601>` and reinitializes the store
  /// with an empty snapshot + log. Called from the Phase 4 corruption alert UI's "Reset to
  /// empty" action; in Phase 1 there is no UI for it and tests are the only caller.
  ///
  /// Transitions `state` from `.failed` back to `.ready` on success. Only valid to call
  /// when `state == .failed` (otherwise it is a no-op so callers can wire it through a
  /// generic alert handler without first checking).
  func resetToEmpty() {
    guard state == .failed else { return }
    guard let jsonl else { return }
    do {
      try jsonl.resetToEmpty(emptySnapshot: [:])
      recordsById = [:]
      monthCounters = [:]
      state = .ready
      mutationCounter &+= 1
    } catch {
      logger.error(
        "resetToEmpty failed: \(String(describing: error), privacy: .public). Store remains .failed."
      )
    }
  }

  /// Converts any variant left as `.inProgress` after load into `.failed` with the interrupted
  /// message. No in-progress state survives app restart; `.pending` is preserved as-is.
  private func recoverInProgressVariants() {
    for (id, record) in recordsById {
      var mutated = record
      var changed = false
      for (variant, variantRecord) in record.variants where variantRecord.status == .inProgress {
        var next = variantRecord
        next.status = .failed
        next.lastError = ExportVariantRecovery.interruptedMessage
        mutated.variants[variant] = next
        changed = true
      }
      if changed {
        recordsById[id] = mutated
      }
    }
  }

  // MARK: - Public API (variant mutations)

  /// Marks a variant `.inProgress`. Creates the record if missing and upserts the variant.
  func markVariantInProgress(
    assetId: String,
    variant: ExportVariant,
    year: Int,
    month: Int,
    relPath: String,
    filename: String?
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
    record.variants[variant] = variantRecord
    append(.upsert(record))
  }

  /// Marks a variant `.done` with a final filename. Creates the record if missing.
  func markVariantExported(
    assetId: String,
    variant: ExportVariant,
    year: Int,
    month: Int,
    relPath: String,
    filename: String,
    exportedAt: Date
  ) {
    var record =
      recordsById[assetId]
      ?? ExportRecord(
        id: assetId, year: year, month: month, relPath: relPath)
    record.year = year
    record.month = month
    record.relPath = relPath
    let variantRecord = ExportVariantRecord(
      filename: filename, status: .done, exportDate: exportedAt, lastError: nil)
    record.variants[variant] = variantRecord
    append(.upsert(record))
  }

  /// Marks a variant `.failed`. Creates the record if missing; preserves year/month/relPath
  /// for existing records.
  func markVariantFailed(
    assetId: String,
    variant: ExportVariant,
    error: String,
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

  // MARK: - Public API (legacy wrappers, route to .original)

  func markExported(
    assetId: String,
    year: Int,
    month: Int,
    relPath: String,
    filename: String,
    exportedAt: Date
  ) {
    markVariantExported(
      assetId: assetId, variant: .original, year: year, month: month, relPath: relPath,
      filename: filename, exportedAt: exportedAt)
  }

  func markFailed(assetId: String, error: String, at date: Date) {
    markVariantFailed(assetId: assetId, variant: .original, error: error, at: date)
  }

  func markInProgress(
    assetId: String, year: Int, month: Int, relPath: String, filename: String?
  ) {
    markVariantInProgress(
      assetId: assetId, variant: .original, year: year, month: month, relPath: relPath,
      filename: filename)
  }

  func remove(assetId: String) {
    append(.delete(id: assetId))
  }

  // MARK: - Public API (queries)

  /// Whether the `.original` variant for this asset is `.done`. Kept as a cheap asset-ID shim for
  /// legacy call sites and tests; new code should use `isExported(asset:selection:)`.
  func isExported(assetId: String) -> Bool {
    recordsById[assetId]?.variants[.original]?.status == .done
  }

  /// Strict, asset-aware completion check for a single asset. Thin wrapper that hands the
  /// record's variant dict to `ExportCompletionPolicy.isComplete`. Timeline placements
  /// always use `VariantPolicy.standard` (no reduced-fidelity sources on owned-library
  /// assets).
  ///
  /// Includes the issue #22 edited-fallback case via the policy: an adjusted asset whose
  /// `.edited` variant is `.failed` with the `editedUnavailableOriginalBackedUpMessage`
  /// sentinel counts as exported. See `ExportCompletionPolicy.satisfiesEditedFallback`.
  func isExported(asset: AssetDescriptor, selection: ExportVersionSelection) -> Bool {
    guard let record = recordsById[asset.id] else { return false }
    return ExportCompletionPolicy.isComplete(
      variants: record.variants, asset: asset, selection: selection, policy: .standard,
      convertHEICToJPEG: convertHEICToJPEG)
  }

  func exportInfo(assetId: String) -> ExportRecord? {
    recordsById[assetId]
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
  /// evaluator can consult each asset's `hasAdjustments`.
  func monthSummary(assets: [AssetDescriptor], selection: ExportVersionSelection)
    -> MonthStatusSummary
  {
    let year =
      assets.first.map { Calendar.current.component(.year, from: $0.creationDate ?? Date()) }
      ?? 0
    let month =
      assets.first.map { Calendar.current.component(.month, from: $0.creationDate ?? Date()) }
      ?? 0

    var exported = 0
    for asset in assets where isExported(asset: asset, selection: selection) {
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

  /// Records covered by the issue #22 fallback in `(year, month)`. Counted as
  /// "exported" by the sidebar's records-only formula in `.edited` mode so a
  /// year that finishes with fallback-covered assets reads as 100% rather
  /// than 99% — matching the asset-aware `isExported(asset:selection:)`.
  func recordCountEditedFallback(year: Int, month: Int) -> Int {
    monthCounters[MonthKey(year: year, month: month)]?.editedFallbackCovered ?? 0
  }

  /// Records-only approximation of "fully exported under this selection," capped by the
  /// count of unedited assets in scope so that natural-stem `.original.done` records
  /// belonging to currently-adjusted assets cannot over-contribute past the number of
  /// assets that could legitimately be original-only.
  ///
  /// `adjustedCount` is required for both modes. Pass nil when the count hasn't loaded yet —
  /// callers should render a neutral "loading" state in that case rather than treat nil as
  /// zero.
  func sidebarSummary(
    year: Int, month: Int, totalCount: Int, adjustedCount: Int?,
    selection: ExportVersionSelection
  ) -> MonthStatusSummary? {
    guard let adjustedCount else { return nil }
    let uneditedCount = max(0, totalCount - adjustedCount)
    let origOnlyAtStem = recordCountOriginalDoneAtNaturalStem(year: year, month: month)
    switch selection {
    case .edited:
      let editedDone = recordCountEditedDone(year: year, month: month)
      let fallbackCovered = recordCountEditedFallback(year: year, month: month)
      let exported = editedDone + min(origOnlyAtStem, uneditedCount) + fallbackCovered
      return makeSummary(year: year, month: month, exported: exported, total: totalCount)
    case .editedWithOriginals:
      // `editedFallbackCovered` is intentionally NOT added here:
      // `satisfiesEditedFallback` is gated to `selection == .edited`, so the
      // asset-aware `isExported(asset:selection:)` keeps re-queueing fallback
      // records under `.editedWithOriginals`. The sidebar must agree, or a
      // year that's actually 0% covered would advertise as 100%.
      let bothDone = recordCountBothVariantsDone(year: year, month: month)
      let exported = bothDone + min(origOnlyAtStem, uneditedCount)
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
    selection: ExportVersionSelection
  ) -> Int {
    var total = 0
    for month in 1...12 {
      let monthTotal = totalCountsByMonth[month] ?? 0
      if monthTotal == 0 { continue }
      let monthAdjusted = adjustedCountsByMonth[month].flatMap { $0 }
      guard
        let summary = sidebarSummary(
          year: year, month: month, totalCount: monthTotal,
          adjustedCount: monthAdjusted, selection: selection)
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
  /// - A `.done` variant with a `nil` filename is corrupt (the writer always sets a
  ///   filename on success) and is pruned wholesale; there's no path to check.
  /// - A `.done` variant whose path resolves to a directory (file replaced by a folder
  ///   of the same name) is pruned — only regular files satisfy "exported."
  /// - When all variants are pruned, the record is removed entirely.
  ///
  /// Two-phase to respect the `@MainActor` isolation: snapshot on main, file checks
  /// off-main via `Task.detached`, mutations applied on main. Callers must run this
  /// only when no export is active (the import flow already gates on
  /// `!hasActiveExportWork`); concurrent mutation would invalidate the snapshot.
  func reconcileAgainstFilesystem(at root: URL) async -> ReconcileSummary {
    guard state == .ready else { return .zero }

    // Phase 1 (main): snapshot every .done variant's expected on-disk path.
    struct Probe: Sendable {
      let assetId: String
      let variant: ExportVariant
      let path: String
      let isCorrupt: Bool
    }
    var probes: [Probe] = []
    for (assetId, record) in recordsById {
      for (variant, vr) in record.variants where vr.status == .done {
        guard let filename = vr.filename else {
          probes.append(Probe(assetId: assetId, variant: variant, path: "", isCorrupt: true))
          continue
        }
        let path = root.appendingPathComponent(record.relPath)
          .appendingPathComponent(filename).path
        probes.append(Probe(assetId: assetId, variant: variant, path: path, isCorrupt: false))
      }
    }

    // Phase 2 (off-main): file checks. `fileExists(atPath:isDirectory:)` rejects a
    // directory standing in for the expected file.
    let probesCopy = probes
    let toPrune: [(assetId: String, variant: ExportVariant)] = await Task.detached {
      let fm = FileManager.default
      var keys: [(assetId: String, variant: ExportVariant)] = []
      for probe in probesCopy {
        if probe.isCorrupt {
          keys.append((probe.assetId, probe.variant))
          continue
        }
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: probe.path, isDirectory: &isDir)
        if !exists || isDir.boolValue {
          keys.append((probe.assetId, probe.variant))
        }
      }
      return keys
    }.value

    // Phase 3 (main): apply mutations.
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
      merged.year = incoming.year
      merged.month = incoming.month
      merged.relPath = incoming.relPath
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
      "Bulk imported \(importedVariants) variants (skipped \(skippedVariants) already-done variants)"
    )
  }

  // MARK: - Internals
  private func append(_ mutation: ExportRecordMutation) {
    // RecordStoreState guard: writes only land when `.ready`. `.failed` means the snapshot
    // is corrupt (deferred-rename rule); `.unconfigured` means no destination is selected.
    // Either case: no-op. Debug builds trip an `assertionFailure` so a routing bug shows up
    // in tests; release silently drops to avoid crashing on a benign race during state
    // transitions.
    guard state == .ready else {
      assertionFailure(
        "ExportRecordStore.append called while state == \(state); ExportManager should have routed via canExport."
      )
      return
    }

    apply(mutation)
    // Coalesce notifications to avoid excessive UI churn during exports
    scheduleCoalescedNotify()

    // If not configured to any destination, do not persist
    guard let jsonl else { return }
    jsonl.append(mutation, currentSnapshot: { self.recordsById })
  }

  /// Applies a mutation to in-memory state. When `recordCounters` is `true` (the default
  /// for production mutations), `monthCounters` is updated incrementally by subtracting
  /// the old record's contribution and adding the new record's. The `false` path is used
  /// during `configure(for:)` while the snapshot+log replay rebuilds `recordsById` from
  /// scratch — incrementally diffing against an empty counter map would produce negative
  /// counts. After the replay, `rebuildCountersFromRecords()` populates the counters in
  /// one O(N) pass.
  private func apply(_ mutation: ExportRecordMutation, recordCounters: Bool = true) {
    let oldRecord = recordsById[mutation.id]
    switch mutation.op {
    case .upsert:
      if let record = mutation.record {
        recordsById[mutation.id] = record
        if recordCounters {
          adjustCounters(old: oldRecord, new: record)
        }
      }
    case .delete:
      recordsById.removeValue(forKey: mutation.id)
      if recordCounters {
        adjustCounters(old: oldRecord, new: nil)
      }
    }
  }

  /// Subtracts the old record's contribution and adds the new record's to `monthCounters`.
  /// Either side may be `nil` (a fresh insert has no `old`; a delete has no `new`).
  private func adjustCounters(old: ExportRecord?, new: ExportRecord?) {
    if let old { contribute(old, sign: -1) }
    if let new { contribute(new, sign: +1) }
  }

  /// Adds (`sign == +1`) or removes (`sign == -1`) `record`'s contribution to its
  /// `(year, month)` cell of `monthCounters`. Idempotent under `+1` then `-1` for the
  /// same record value, which is what the diff in `adjustCounters` relies on.
  private func contribute(_ record: ExportRecord, sign: Int) {
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
      editedRecord.lastError
        == ExportVariantRecovery.editedUnavailableOriginalBackedUpMessage
    {
      counters.editedFallbackCovered += sign
    }
    monthCounters[key] = counters
  }

  /// Rebuilds `monthCounters` from scratch by walking `recordsById` once. Called from
  /// `configure(for:)` after the snapshot is loaded and log ops are replayed (with
  /// counter updates suppressed during replay), and after `recoverInProgressVariants()`
  /// transitions any leftover in-progress variants to failed in-memory.
  private func rebuildCountersFromRecords() {
    monthCounters = [:]
    for record in recordsById.values {
      contribute(record, sign: +1)
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
    notifyWorkItem?.cancel()
    let item = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.mutationCounter &+= 1
    }
    notifyWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
  }

  // MARK: - Testing helpers
  /// Blocks until all pending IO operations are flushed.
  func flushForTesting() {
    ioQueue.sync {}
  }
}
