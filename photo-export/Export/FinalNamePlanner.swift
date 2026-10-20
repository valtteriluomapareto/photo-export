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

  static let defaultChunkSize = 1 << 20

  private static let logger = Logger(
    subsystem: "com.valtteriluoma.photo-export", category: "FinalNamePlanner")

  let fileSystem: any FileSystemService
  let chunkSize: Int

  init(fileSystem: any FileSystemService, chunkSize: Int = FinalNamePlanner.defaultChunkSize) {
    self.fileSystem = fileSystem
    self.chunkSize = chunkSize
  }

  /// `isClaimed` says whether another record names a candidate. `shouldStop` is asked before
  /// each chunk read; when it answers true, or the task is cancelled, planning throws
  /// `CancellationError` and nothing is adopted.
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

  /// Compares the two files chunk by chunk in `chunkRanges` order. A read error on either
  /// file means the candidate cannot be proven equal, so it is not adopted.
  func contentsEqual(
    _ staged: URL, _ candidate: URL, size: Int64, shouldStop: @Sendable () async -> Bool
  ) async throws -> Bool {
    for range in Self.chunkRanges(size: size, chunkSize: chunkSize) {
      if await shouldStop() { throw CancellationError() }
      try Task.checkCancellation()
      let stagedBytes: Data
      let candidateBytes: Data
      do {
        stagedBytes = try await fileSystem.readChunk(
          at: staged, offset: range.offset, length: range.length)
        candidateBytes = try await fileSystem.readChunk(
          at: candidate, offset: range.offset, length: range.length)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        Self.logger.notice(
          "Could not compare with \(candidate.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
        return false
      }
      guard stagedBytes.count == range.length, stagedBytes == candidateBytes else { return false }
    }
    return true
  }

  /// The head, then the tail, then the rest in order. A different photo or a re-encoded
  /// file usually differs in its header or trailer, so most mismatches cost two reads.
  static func chunkRanges(size: Int64, chunkSize: Int) -> [(offset: Int64, length: Int)] {
    let chunk = Int64(chunkSize)
    guard size > 2 * chunk else {
      return stride(from: Int64(0), to: size, by: chunkSize).map {
        (offset: $0, length: Int(min(chunk, size - $0)))
      }
    }
    let tail = size - chunk
    let middle = stride(from: chunk, to: tail, by: chunkSize).map {
      (offset: $0, length: Int(min(chunk, tail - $0)))
    }
    return [(offset: 0, length: chunkSize), (offset: tail, length: chunkSize)] + middle
  }
}
