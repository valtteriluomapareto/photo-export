import Foundation
import OSLog

/// Chooses the name a staged file commits under, from what its folder already holds.
///
/// A `.suffix` slot's candidates are walked in order (`IMG.JPG`, `IMG (1).JPG`, …). The first
/// with nothing at it is a move. An earlier candidate is adopted instead when it is a regular
/// file, not empty, the size of the stage, named by no other record, and byte-for-byte equal
/// to the stage. A `.refuse` slot always moves to its one name.
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

  private static let logger = Logger(
    subsystem: "com.valtteriluoma.photo-export", category: "FinalNamePlanner")

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

  /// `isClaimed` says whether another record names a candidate. Task cancellation is checked
  /// before every chunk read; `shouldStop` before the first and then once per
  /// `stopCheckInterval` bytes. Either stops planning with `CancellationError`, and nothing
  /// is adopted.
  func plan(
    slot: ExportDestinationResolver.Slot, stagedURL: URL,
    isClaimed: @Sendable (String) async -> Bool,
    shouldStop: @Sendable () async -> Bool
  ) async throws -> Plan {
    guard case .suffix = slot.policy else { return .move(slot.naturalURL) }
    let stagedSize = try fileSystem.itemIdentity(at: stagedURL)?.size ?? 0
    var index = 0
    while let candidate = slot.candidate(index) {
      try Task.checkCancellation()
      guard let identity = try fileSystem.itemIdentity(at: candidate) else {
        return .move(candidate)
      }
      if identity.isRegularFile, identity.size > 0, identity.size == stagedSize,
        await !isClaimed(candidate.lastPathComponent),
        try await contentsEqual(
          stagedURL, candidate, size: identity.size, shouldStop: shouldStop)
      {
        // Without the stored spelling the record could name a file the folder does not list.
        do {
          let storedName = try fileSystem.storedName(at: candidate)
          return .adopt(candidate, storedName: storedName, identity: identity)
        } catch {
          Self.logger.notice(
            "No stored name for \(candidate.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
          )
        }
      }
      index += 1
    }
    throw FileIOService.destinationExistsError()
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
