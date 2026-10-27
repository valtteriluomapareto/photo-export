import Darwin
import Foundation
import os
import Synchronization

/// Shared only with the serial IO queue. A failure stays latched until a complete snapshot
/// succeeds, because appending later operations across a missing log line would make a
/// subsequent compaction discard history that exists only in memory.
private final class JSONLIOFailureState: Sendable {
  private struct State: Sendable {
    var failure: (any Error)?
    var notified = false
  }
  private let state = Mutex(State())

  func currentFailure() -> (any Error)? {
    state.withLock { $0.failure }
  }

  func fail(_ error: any Error) {
    state.withLock { if $0.failure == nil { $0.failure = error } }
  }

  func takeUnnotifiedFailure() -> (any Error)? {
    state.withLock {
      guard !$0.notified, let failure = $0.failure else { return nil }
      $0.notified = true
      return failure
    }
  }

  func clear() {
    state.withLock { $0 = State() }
  }
}

/// Moves the frozen history to one worker; the box is empty before completion is resumed.
final class RecordValueTransfer<Value: Sendable>: Sendable {
  private let value: Mutex<Value?>
  init(_ value: consuming Value) { self.value = Mutex(consume value) }
  func discard() {
    value.withLock { $0 = nil }
  }
  func take() -> Value {
    value.withLock { stored in
      defer { stored = nil }
      return stored!
    }
  }
}

/// Reusable persistence component that backs both the timeline `ExportRecordStore` and the
/// new `CollectionExportRecordStore`. Owns the JSONL+snapshot machinery (atomic writes, log
/// replay with malformed-line skip, explicit maintenance checkpoints) and leaves the
/// record shape and apply-log-op dispatch to the composing store.
///
/// Boundaries:
/// - **Generic owns:** snapshot read/write (atomic via `.tmp` + rename + parent-dir fsync),
///   log append (with `fsync(handle)`), log replay (with malformed-line skip), checkpoint execution, snapshot/log file-rename rotation.
/// - **Composing store owns:** the in-memory record dictionary, the apply-log-op dispatch
///   on each loaded op, the in-flight recovery pass, the observed `mutationCounter`,
///   and the `RecordStoreState` machine.
///
/// Both stores share the same commit order: synchronize the replacement snapshot,
/// atomically rename it over the old snapshot, synchronize its directory, then truncate
/// the log. An interruption before log truncation leaves a replayable log intact.
///
/// `@MainActor` isolates the calling-actor side: every entry point (`load`, `append`,
/// `writeSnapshot`, `resetToEmpty`, `drainSynchronously`) and every
/// mutable property (including `submittedRevision` and the replay budget) must be touched from the main actor.
/// Both production composing stores (`ExportRecordStore`,
/// `CollectionExportRecordStore`) are themselves `@MainActor`, so this matches how the
/// type is actually used. Off-actor work — log writes and snapshot encoding/replacement —
/// happens on the dispatch queue and only reads `Sendable`
/// locals captured from the calling actor, never reaching back into `self` for
/// non-Sendable state. `load()` is composed of the `nonisolated` static `readFiles` and
/// `decode`, which take everything they need as arguments and can run on any thread.
@MainActor
final class JSONLRecordFile<Snapshot: Codable & Sendable, LogOp: Codable & Sendable> {
  enum Constants {
    static var compactEveryNMutations: Int { 1000 }
  }

  // MARK: - Configuration

  let snapshotURL: URL
  let logURL: URL
  private let ioQueue: DispatchQueue
  private let logger: Logger
  private let dateEncodingStrategy: JSONEncoder.DateEncodingStrategy
  private let dateDecodingStrategy: JSONDecoder.DateDecodingStrategy
  private let fileReplacer: any AtomicFileReplacing
  private let logIO: any JSONLRecordLogIO
  private let ioFailureState = JSONLIOFailureState()

  /// Called on the main actor once for a persistence failure, including asynchronous
  /// append and compaction failures. The owner must retain its in-memory records for retry.
  var onPersistenceFailure: ((any Error) -> Void)?

  // MARK: - Mutation-count state

  private var replayOperationCount = 0
  private var replayBytes = 0
  var needsMaintenance: Bool { replayOperationCount >= 4_000 || replayBytes >= 3_000_000 }
  var needsIdleMaintenance: Bool {
    replayOperationCount >= Constants.compactEveryNMutations || needsMaintenance
  }
  var hasReplayWork: Bool { replayOperationCount > 0 || replayBytes > 0 }
  private var submittedRevision = 0
  private var flushedRevision = 0
  /// A recovered complete or partial final line must not absorb the next operation.
  private var needsLogSeparator = false

  /// A ready store may still contain pending writes. A flush acknowledges only
  /// mutations submitted before its await, never newer mutations queued during it.
  var hasUnflushedChanges: Bool { submittedRevision != flushedRevision }

  // MARK: - Init

  init(
    snapshotURL: URL,
    logURL: URL,
    ioQueue: DispatchQueue,
    logger: Logger,
    dateEncodingStrategy: JSONEncoder.DateEncodingStrategy = .iso8601,
    dateDecodingStrategy: JSONDecoder.DateDecodingStrategy = .iso8601,
    fileReplacer: any AtomicFileReplacing = FileIOService(),
    logIO: any JSONLRecordLogIO = ProductionJSONLRecordLogIO()
  ) {
    self.snapshotURL = snapshotURL
    self.logURL = logURL
    self.ioQueue = ioQueue
    self.logger = logger
    self.dateEncodingStrategy = dateEncodingStrategy
    self.dateDecodingStrategy = dateDecodingStrategy
    self.fileReplacer = fileReplacer
    self.logIO = logIO
  }

  // MARK: - Load

  /// Outcome of reading the snapshot file. The composing store branches its load path on
  /// this — a corrupt snapshot transitions the store to `.failed` per *Recovery on
  /// Corruption*, while an absent snapshot is normal (legitimate before the first
  /// compaction).
  enum SnapshotStatus: Equatable, Sendable {
    /// No snapshot file on disk. Normal first-launch / pre-first-compaction state.
    case absent
    /// Snapshot file present and decoded. The decoded value is in `LoadResult.snapshot`.
    case loaded
    /// Snapshot file present but failed to decode. **The file is left in place** —
    /// composing-store code transitions the store to `.failed` and only `resetToEmpty()`
    /// renames the file out of the way. This is the load-bearing detail that makes
    /// "Quit" non-destructive: a quit-and-relaunch finds the same corrupt file and
    /// re-fails, never silently resetting to an empty store.
    case corrupt
  }

  struct LoadResult: Sendable {
    let snapshot: Snapshot?
    let snapshotStatus: SnapshotStatus
    let ops: [LogOp]
    let malformedLineCount: Int
    /// A failed snapshot or log read. A missing file is normal and has no error.
    let ioFailure: (any Error)?
    /// Whether the log ends in a line with no final LF, so the next append must start a
    /// new line. `nil` when the log read failed: the file keeps what it knew before.
    let needsLogSeparator: Bool?
    var replayBytes: Int = 0
  }

  /// The snapshot and log bytes as read, before any decoding. A missing file has neither
  /// bytes nor an error.
  struct RawLoad: Sendable {
    let snapshotData: Data?
    let snapshotError: (any Error)?
    let logData: Data?
    let logError: (any Error)?
  }

  /// Reads the snapshot (if any) and the log file (if any). The composing store applies
  /// `ops` in order via its own dispatch logic. Malformed lines are skipped and logged but
  /// do not abort the load. A missing snapshot is not an error (returns `.absent`); a
  /// present-but-undecodable snapshot is reported as `.corrupt` with the file untouched.
  func load() -> LoadResult {
    let inputs = readInputs
    let result = inputs.decode(inputs.read())
    adoptLogSeparator(result.needsLogSeparator)
    adoptReplaySize(operationCount: result.ops.count, bytes: result.replayBytes)
    return result
  }

  /// Everything `readFiles` and `decode` need, so a load can run them on any thread with the
  /// same files, log IO and decoding as `load()`.
  struct ReadInputs: Sendable {
    let snapshotURL: URL
    let logURL: URL
    let logIO: any JSONLRecordLogIO
    let dateDecodingStrategy: JSONDecoder.DateDecodingStrategy
    let logger: Logger

    func read() -> RawLoad {
      JSONLRecordFile.readFiles(snapshotURL: snapshotURL, logURL: logURL, logIO: logIO)
    }

    func decode(_ raw: RawLoad) -> LoadResult {
      JSONLRecordFile.decode(
        raw, snapshotURL: snapshotURL, logURL: logURL,
        dateDecodingStrategy: dateDecodingStrategy, logger: logger)
    }
  }

  var readInputs: ReadInputs {
    ReadInputs(
      snapshotURL: snapshotURL, logURL: logURL, logIO: logIO,
      dateDecodingStrategy: dateDecodingStrategy, logger: logger)
  }

  /// Takes on what a load found at the end of the log (`LoadResult.needsLogSeparator`). `nil`
  /// means the log could not be read, so the file keeps what it knew before.
  func adoptLogSeparator(_ separator: Bool?) {
    if let separator { needsLogSeparator = separator }
  }

  func adoptReplaySize(operationCount: Int, bytes: Int) {
    replayOperationCount = operationCount
    replayBytes = bytes
  }

  /// Reads the snapshot, then the log. File IO only: nothing is decoded or logged, so the
  /// read can run on any thread.
  nonisolated static func readFiles(
    snapshotURL: URL, logURL: URL, logIO: any JSONLRecordLogIO
  ) -> RawLoad {
    var snapshotData: Data?
    var snapshotError: (any Error)?
    do {
      snapshotData = try logIO.readIfPresent(at: snapshotURL)
    } catch {
      snapshotError = error
    }
    var logData: Data?
    var logError: (any Error)?
    do {
      logData = try logIO.readIfPresent(at: logURL)
    } catch {
      logError = error
    }
    return RawLoad(
      snapshotData: snapshotData, snapshotError: snapshotError, logData: logData,
      logError: logError)
  }

  /// Decodes what `readFiles` read and logs each failure, snapshot first. A failed log read
  /// is the reported `ioFailure` even when the snapshot read failed too.
  nonisolated static func decode(
    _ raw: RawLoad, snapshotURL: URL, logURL: URL,
    dateDecodingStrategy: JSONDecoder.DateDecodingStrategy, logger: Logger
  ) -> LoadResult {
    var snapshot: Snapshot?
    var snapshotStatus: SnapshotStatus = .absent
    var ioFailure: (any Error)?
    if let error = raw.snapshotError {
      ioFailure = error
      logger.error(
        "Failed to read snapshot at \(snapshotURL.path, privacy: .public): \(String(describing: error), privacy: .public)"
      )
    } else if let data = raw.snapshotData {
      do {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = dateDecodingStrategy
        snapshot = try decoder.decode(Snapshot.self, from: data)
        snapshotStatus = .loaded
      } catch {
        snapshotStatus = .corrupt
        logger.error(
          "Failed to decode snapshot at \(snapshotURL.path, privacy: .public): \(String(describing: error), privacy: .public)"
        )
      }
    }

    var ops: [LogOp] = []
    var malformedLineCount = 0
    let needsLogSeparator: Bool?
    if let error = raw.logError {
      needsLogSeparator = nil
      ioFailure = error
      logger.error(
        "Failed to read log at \(logURL.path, privacy: .public): \(String(describing: error), privacy: .public)"
      )
    } else if let fileData = raw.logData {
      needsLogSeparator = !fileData.isEmpty && fileData.last != 0x0A
      // Bulk-read the log instead of one FileHandle.read(upToCount: 1) per
      // byte. Cold-start measurement on a 184 KB log showed ~270 ms of
      // pure syscall overhead from the per-byte reader; one Data(contentsOf:)
      // brings that to single-digit ms. `split(separator: 0x0A,
      // omittingEmptySubsequences: true)` already drops trailing-newline
      // empties; explicit isEmpty skip handles back-to-back newlines too.
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = dateDecodingStrategy
      for lineSlice in fileData.split(separator: 0x0A) {
        if lineSlice.isEmpty { continue }
        let lineData = Data(lineSlice)
        do {
          let op = try decoder.decode(LogOp.self, from: lineData)
          ops.append(op)
        } catch {
          malformedLineCount += 1
          logger.error(
            "Skipping malformed log line in \(logURL.path, privacy: .public): \(String(describing: error), privacy: .public)"
          )
        }
      }
    } else {
      needsLogSeparator = false
    }

    return LoadResult(
      snapshot: snapshot, snapshotStatus: snapshotStatus, ops: ops,
      malformedLineCount: malformedLineCount, ioFailure: ioFailure,
      needsLogSeparator: needsLogSeparator, replayBytes: raw.logData?.count ?? 0)
  }

  /// Renames the corrupt snapshot to `<name>.broken-<ISO8601>` and writes a fresh empty
  /// snapshot + log. Used by composing stores' `resetToEmpty()` paths after the user picks
  /// destructive Reset action in RecordStoreAlertHost. Until that explicit recovery,
  /// the store remains failed and the corrupt file is preserved.
  func resetToEmpty(emptySnapshot: Snapshot) throws {
    try Self.preserveCorruptSnapshot(at: snapshotURL)
    try writeSnapshot(emptySnapshot)
  }

  nonisolated private static func preserveCorruptSnapshot(at snapshotURL: URL) throws {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
    let timestamp = formatter.string(from: Date())
    let manager = FileManager.default
    if manager.fileExists(atPath: snapshotURL.path) {
      let broken = snapshotURL.deletingPathExtension().appendingPathExtension("broken-\(timestamp)")
      try manager.moveItem(at: snapshotURL, to: broken)
    }
  }

  // MARK: - Append + compaction

  /// Appends and synchronizes each operation independently. The owner closes mutation
  /// admission before requesting a checkpoint; appends never capture a history snapshot.
  func append(_ op: LogOp) {
    submittedRevision += 1
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = dateEncodingStrategy
    let opData: Data
    do {
      opData = try encoder.encode(op)
    } catch {
      logger.error(
        "Failed to encode log op for \(self.logURL.path, privacy: .public): \(String(describing: error), privacy: .public)"
      )
      ioFailureState.fail(error)
      deliverPendingFailure()
      return
    }

    replayOperationCount += 1
    replayBytes += opData.count

    let logURL = self.logURL
    let logger = self.logger
    let logIO = self.logIO
    let ioFailureState = self.ioFailureState
    var payload = Data()
    if needsLogSeparator { payload.append(0x0A) }
    payload.append(opData)
    payload.append(0x0A)
    let lineData = payload

    ioQueue.async { [weak self] in
      // The owner may already have applied a failed operation in memory. No later log
      // append or compaction may claim that state is durable before snapshot recovery.
      guard ioFailureState.currentFailure() == nil else { return }
      do {
        try Self.appendLogLine(data: lineData, to: logURL, logIO: logIO)
      } catch {
        logger.error(
          "Failed to append log line to \(logURL.path, privacy: .public): \(String(describing: error), privacy: .public)"
        )
        ioFailureState.fail(error)
        Task { @MainActor [weak self] in
          self?.deliverPendingFailure()
        }
        return
      }

    }
    // IO failure keeps later queued appends blocked until full-snapshot recovery.
    needsLogSeparator = false
  }

  /// Encodes and replaces a complete snapshot after the composing store has closed admission.
  /// Cancellation never resumes before the physical replacement and required synchronization.
  func checkpoint(
    _ snapshot: consuming Snapshot, recovering: Bool = false, resetCorrupt: Bool = false
  )
    async throws
  {
    let transfer = RecordValueTransfer(consume snapshot)
    let revision = submittedRevision
    let snapshotURL = snapshotURL
    let logURL = logURL
    let dateEncodingStrategy = dateEncodingStrategy
    let fileReplacer = fileReplacer
    let failureState = ioFailureState
    let result: Result<Void, Error> = await withCheckedContinuation { continuation in
      ioQueue.async {
        if !recovering, let failure = failureState.currentFailure() {
          transfer.discard()
          continuation.resume(returning: .failure(failure))
          return
        }
        do {
          try Self.writeTransferredSnapshot(
            transfer, snapshotURL: snapshotURL, logURL: logURL,
            dateEncodingStrategy: dateEncodingStrategy, fileReplacer: fileReplacer,
            resetCorrupt: resetCorrupt)
          if recovering { failureState.clear() }
          continuation.resume(returning: .success(()))
        } catch SnapshotEncodingFailure.failed(let error) {
          continuation.resume(returning: .failure(error))
        } catch {
          failureState.fail(error)
          continuation.resume(returning: .failure(error))
        }
      }
    }
    deliverPendingFailure()
    try result.get()
    replayOperationCount = 0
    replayBytes = 0
    flushedRevision = max(flushedRevision, revision)
    needsLogSeparator = false
  }

  private enum SnapshotEncodingFailure: Error { case failed(any Error) }

  /// The worker frame releases its history before the caller resumes any admitted writer.
  nonisolated private static func writeTransferredSnapshot(
    _ transfer: RecordValueTransfer<Snapshot>, snapshotURL: URL, logURL: URL,
    dateEncodingStrategy: JSONEncoder.DateEncodingStrategy,
    fileReplacer: any AtomicFileReplacing, resetCorrupt: Bool
  ) throws {
    let snapshot = transfer.take()
    let data: Data
    do {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = dateEncodingStrategy
      data = try encoder.encode(snapshot)
    } catch { throw SnapshotEncodingFailure.failed(error) }
    if resetCorrupt { try preserveCorruptSnapshot(at: snapshotURL) }
    try writeSnapshotAndTruncate(
      snapshotData: data, snapshotURL: snapshotURL, logURL: logURL, fileReplacer: fileReplacer)
  }

  // MARK: - Manual snapshot

  /// Synchronously writes a snapshot and truncates the log. Used by `resetToEmpty()` paths
  /// and by tests; production recovery and maintenance await `checkpoint`.
  func writeSnapshot(_ snapshot: Snapshot) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = dateEncodingStrategy
    let data = try encoder.encode(snapshot)
    // Serialize explicit snapshots with queued appends and automatic compactions.
    let snapshotURL = self.snapshotURL
    let logURL = self.logURL
    let fileReplacer = self.fileReplacer
    let ioFailureState = self.ioFailureState
    try ioQueue.sync {
      try Self.writeSnapshotAndTruncate(
        snapshotData: data, snapshotURL: snapshotURL, logURL: logURL,
        fileReplacer: fileReplacer)
      ioFailureState.clear()
    }
    replayOperationCount = 0
    replayBytes = 0
    flushedRevision = submittedRevision
    needsLogSeparator = false
  }

  /// Acknowledges all appends queued before this call only after their file writes and
  /// `fsync` calls have completed. Failure delivery is synchronous on the main actor
  /// before throwing, so the owner cannot report success while its state is still ready.
  func flush() async throws {
    let revision = submittedRevision
    let state = ioFailureState
    let failure: (any Error)? = await withCheckedContinuation { continuation in
      ioQueue.async {
        continuation.resume(returning: state.currentFailure())
      }
    }
    deliverPendingFailure()
    if let failure { throw failure }
    flushedRevision = max(flushedRevision, revision)
  }

  // MARK: - Synchronous IO drain

  /// Blocks the caller until queued IO finishes and delivers any pending failure.
  /// Must not be called from the IO queue.
  func drainSynchronously() {
    ioQueue.sync {}
    deliverPendingFailure()
    if ioFailureState.currentFailure() == nil { flushedRevision = submittedRevision }
  }

  // MARK: - Internal helpers

  private func deliverPendingFailure() {
    if let failure = ioFailureState.takeUnnotifiedFailure() {
      onPersistenceFailure?(failure)
    }
  }

  /// Writes `snapshotData` atomically and truncates the log.
  ///
  /// The snapshot's bytes and directory entry must be synchronized before truncating
  /// the log. Never unlink the previous snapshot: one rename replaces it so a process
  /// interruption leaves either the previous snapshot + log or the new snapshot + log.
  /// Replaying the untruncated log is safe because record mutations are idempotent.
  ///
  /// A leftover `.tmp` is not authoritative; the next attempt replaces it. We do not
  /// adopt temporary bytes during load or change either store's on-disk format.
  /// `nonisolated` because this is called from inside `append`'s `ioQueue.async` block.
  /// Pure file I/O against URLs passed in by value; touches no actor state.
  nonisolated private static func writeSnapshotAndTruncate(
    snapshotData: Data, snapshotURL: URL, logURL: URL,
    fileReplacer: any AtomicFileReplacing
  ) throws {
    // 1) Prepare and synchronize the replacement while the old snapshot stays intact.
    let snapshotTmpURL = snapshotURL.appendingPathExtension("tmp")
    try snapshotData.write(to: snapshotTmpURL, options: .atomic)
    let handle = try FileHandle(forWritingTo: snapshotTmpURL)
    defer { try? handle.close() }
    try handle.synchronize()

    // 2) One rename replaces the snapshot. On failure, keep the old snapshot and log.
    try fileReplacer.replaceItemAtomically(from: snapshotTmpURL, to: snapshotURL)
    try fsyncDirectory(snapshotURL.deletingLastPathComponent())

    // 3) Only now may the log be truncated. A prior error must leave it untouched.
    try Data().write(to: logURL, options: .atomic)
    try fsyncDirectory(logURL.deletingLastPathComponent())
  }

  /// `nonisolated` for the same reason as `writeSnapshotAndTruncate`.
  nonisolated private static func fsyncDirectory(_ url: URL) throws {
    let fd = open(url.path, O_RDONLY)
    guard fd >= 0 else {
      throw NSError(
        domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
    }
    defer { close(fd) }
    guard fsync(fd) == 0 else {
      throw NSError(
        domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
    }
  }

  nonisolated private static func appendLogLine(
    data: Data, to url: URL, logIO: any JSONLRecordLogIO
  ) throws {
    let handle = try logIO.openForAppending(at: url)
    defer { try? handle.close() }
    try logIO.write(data, to: handle)
    try logIO.synchronize(handle)
  }

}
