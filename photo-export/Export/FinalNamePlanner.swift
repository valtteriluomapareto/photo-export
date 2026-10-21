import Foundation
import OSLog

/// Chooses the name a staged file commits under, from what its folder already holds.
///
/// A `.suffix` slot's candidates are walked in order (`IMG.JPG`, `IMG (1).JPG`, …). The first
/// with nothing at it that no other record names is a move: a record whose file was deleted
/// keeps its name until Import Existing Backup drops it. An earlier candidate is adopted
/// instead when it is a regular file with one link, not empty, the size of the stage, named
/// by no other record, byte-for-byte equal to the stage, and its folder stores it under a
/// spelling of the candidate's name. A `.refuse` slot is always planned as a move to its one
/// name: claims are not checked here (`resolveSlot` checks them before staging), and the
/// commit fails if a file is there.
///
/// Reads go through the `FileSystemService` seam and run off the main actor. No digests are
/// kept: both files are on disk, so a chunked compare that stops at the first difference is
/// cheaper than hashing either.
struct FinalNamePlanner: Sendable {
  enum Plan: Equatable, Sendable {
    case move(URL)
    /// `storedName` is the existing file's name as its folder spells it.
    case adopt(URL, storedName: String, identity: FileItemIdentity)
  }

  /// The head and tail reads, small because most mismatches show in one of them.
  static let defaultEdgeChunkSize = 1 << 20
  /// The reads in between, larger so a long equal file costs fewer round trips.
  static let defaultMiddleChunkSize = 8 << 20
  /// Bytes compared between two `shouldStop` calls, each a hop to the main actor.
  static let defaultStopCheckInterval = 32 << 20

  private static let logger = Logger.app(.finalNamePlanner)

  let fileSystem: any FileSystemService
  let edgeChunkSize: Int
  let middleChunkSize: Int
  let stopCheckInterval: Int

  init(
    fileSystem: any FileSystemService,
    edgeChunkSize: Int = FinalNamePlanner.defaultEdgeChunkSize,
    middleChunkSize: Int = FinalNamePlanner.defaultMiddleChunkSize,
    stopCheckInterval: Int = FinalNamePlanner.defaultStopCheckInterval
  ) {
    self.fileSystem = fileSystem
    self.edgeChunkSize = edgeChunkSize
    self.middleChunkSize = middleChunkSize
    self.stopCheckInterval = stopCheckInterval
  }

  /// With `mayAdopt` false the walk only looks for a free name. `isClaimed` says whether
  /// another record names a candidate; such a candidate is never moved to or adopted. Task
  /// cancellation is checked before every chunk read; `shouldStop` before the first and then
  /// once per `stopCheckInterval` bytes. Either stops planning with `CancellationError`, and
  /// nothing is adopted.
  func plan(
    slot: ExportDestinationResolver.Slot, stagedURL: URL, mayAdopt: Bool = true,
    isClaimed: @Sendable (String) async -> Bool,
    shouldStop: @Sendable () async -> Bool
  ) async throws -> Plan {
    guard case .suffix = slot.policy else { return .move(slot.naturalURL) }
    let stagedSize = try fileSystem.itemIdentity(at: stagedURL)?.size ?? 0
    var index = 0
    while let candidate = slot.candidate(index) {
      try Task.checkCancellation()
      guard let identity = try fileSystem.itemIdentity(at: candidate) else {
        if await !isClaimed(candidate.lastPathComponent) { return .move(candidate) }
        index += 1
        continue
      }
      // A second hard link would leave two names for one file; another record could claim
      // the other.
      if mayAdopt, identity.isRegularFile, identity.linkCount == 1, identity.size > 0,
        identity.size == stagedSize,
        await !isClaimed(candidate.lastPathComponent),
        try await contentsEqual(
          stagedURL, candidate, size: identity.size, shouldStop: shouldStop),
        let storedName = storedName(of: candidate)
      {
        return .adopt(candidate, storedName: storedName, identity: identity)
      }
      index += 1
    }
    throw FileIOService.destinationExistsError()
  }

  /// The candidate's name as its folder stores it, or nil when it cannot be read or is not
  /// a spelling of the candidate's own name. Without it the record could name a file the
  /// folder does not list under that name.
  private func storedName(of candidate: URL) -> String? {
    do {
      let storedName = try fileSystem.storedName(at: candidate)
      if FilenameKey.sameName(storedName, candidate.lastPathComponent) { return storedName }
      Self.logger.notice(
        "\(candidate.lastPathComponent, privacy: .public) is stored as \(storedName, privacy: .public); not adopted"
      )
    } catch {
      Self.logger.notice(
        "No stored name for \(candidate.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
    }
    return nil
  }

  /// Compares the two files chunk by chunk in `chunkRanges` order, through one open handle
  /// per file. A failure to open or read either file means the candidate cannot be proven
  /// equal, so it is not adopted.
  func contentsEqual(
    _ staged: URL, _ candidate: URL, size: Int64, shouldStop: @Sendable () async -> Bool
  ) async throws -> Bool {
    let stagedFile: any FileReadHandle
    let candidateFile: any FileReadHandle
    do {
      stagedFile = try fileSystem.openForReading(at: staged, bypassingCache: false)
      do {
        candidateFile = try fileSystem.openForReading(at: candidate, bypassingCache: true)
      } catch {
        stagedFile.close()
        throw error
      }
    } catch {
      Self.logNotCompared(candidate, error)
      return false
    }
    defer {
      stagedFile.close()
      candidateFile.close()
    }
    var sinceStopCheck = stopCheckInterval
    let ranges = Self.chunkRanges(size: size, edge: edgeChunkSize, middle: middleChunkSize)
    for range in ranges {
      try Task.checkCancellation()
      if sinceStopCheck >= stopCheckInterval {
        if await shouldStop() { throw CancellationError() }
        sinceStopCheck = 0
      }
      let stagedBytes: Data
      let candidateBytes: Data
      do {
        stagedBytes = try await stagedFile.read(offset: range.offset, length: range.length)
        candidateBytes = try await candidateFile.read(offset: range.offset, length: range.length)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        Self.logNotCompared(candidate, error)
        return false
      }
      guard stagedBytes.count == range.length, stagedBytes == candidateBytes else { return false }
      sinceStopCheck += range.length
    }
    return true
  }

  private static func logNotCompared(_ candidate: URL, _ error: Error) {
    logger.notice(
      "Could not compare with \(candidate.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
    )
  }

  /// The head and the tail in `edge`-sized reads, then the rest in order in `middle`-sized
  /// reads. A different photo or a re-encoded file usually differs in its header or trailer,
  /// so most mismatches cost two small reads.
  static func chunkRanges(size: Int64, edge: Int, middle: Int) -> [(offset: Int64, length: Int)] {
    let edgeSize = Int64(edge)
    guard size > 2 * edgeSize else {
      return stride(from: Int64(0), to: size, by: edge).map {
        (offset: $0, length: Int(min(edgeSize, size - $0)))
      }
    }
    let tail = size - edgeSize
    let rest = stride(from: edgeSize, to: tail, by: middle).map {
      (offset: $0, length: Int(min(Int64(middle), tail - $0)))
    }
    return [(offset: 0, length: edge), (offset: tail, length: edge)] + rest
  }
}
