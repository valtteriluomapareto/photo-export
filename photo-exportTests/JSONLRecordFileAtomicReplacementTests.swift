import Foundation
import Testing
import os

@testable import Photo_Export

@MainActor
struct JSONLRecordFileAtomicReplacementTests {
  private struct Mutation: Codable, Sendable {
    let key: String
    let value: String?
  }

  private typealias Store = JSONLRecordFile<[String: String], Mutation>

  enum Interruption: CaseIterable, Sendable {
    case beforeReplacement
    case afterReplacement
    case missingSource
  }

  private enum InjectedFailure: Error { case interrupted }

  /// Runs the real replacement operation, with deterministic failures at its
  /// boundaries. A thrown error leaves the same files a process interruption
  /// would leave there, without timing a kill against the filesystem.
  private struct InterruptingReplacer: AtomicFileReplacing {
    let interruption: Interruption

    func replaceItemAtomically(from source: URL, to destination: URL) throws {
      switch interruption {
      case .beforeReplacement:
        throw InjectedFailure.interrupted
      case .afterReplacement:
        try FileIOService().replaceItemAtomically(from: source, to: destination)
        throw InjectedFailure.interrupted
      case .missingSource:
        // A real rename failure must preserve the previous snapshot too.
        try FileIOService().replaceItemAtomically(
          from: source.appendingPathExtension("missing"), to: destination)
      }
    }
  }

  private func makeStore(
    in directory: URL, fileReplacer: any AtomicFileReplacing = FileIOService()
  ) -> Store {
    Store(
      snapshotURL: directory.appendingPathComponent("snapshot.json"),
      logURL: directory.appendingPathComponent("log.jsonl"),
      ioQueue: DispatchQueue(label: "JSONL-atomic-\(UUID().uuidString)"),
      logger: Logger(subsystem: "test", category: "JSONLAtomicReplacement"),
      fileReplacer: fileReplacer)
  }

  private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("JSONL-atomic-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  @Test(arguments: Interruption.allCases, [false, true])
  func interruptedReplacementPreservesCompactedHistory(
    interruption: Interruption, automaticCompaction: Bool
  ) throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let oldSnapshot = ["old": "done", "removed": "done", "updated": "original"]
    try makeStore(in: directory).writeSnapshot(oldSnapshot)

    let store = makeStore(
      in: directory, fileReplacer: InterruptingReplacer(interruption: interruption))
    let count = automaticCompaction ? Store.Constants.compactEveryNMutations : 3
    var snapshot = oldSnapshot
    for index in 0..<count {
      let mutation: Mutation
      switch index {
      case 0: mutation = Mutation(key: "removed", value: nil)
      case 1: mutation = Mutation(key: "updated", value: "edited")
      default: mutation = Mutation(key: "new", value: "done")
      }
      snapshot[mutation.key] = mutation.value
      let frozen = snapshot
      store.append(mutation, currentSnapshot: { frozen })
    }
    store.flushForTesting()

    if !automaticCompaction {
      #expect(throws: (any Error).self) { try store.writeSnapshot(snapshot) }
    }

    // Reopen independently: "old" only exists in the compacted snapshot, never
    // in this log. Losing it recreates the duplicate-export bug from issue #138.
    let reopened = makeStore(in: directory).load()
    #expect(reopened.snapshotStatus == .loaded)
    let expectedSnapshot = interruption == .afterReplacement ? snapshot : oldSnapshot
    #expect(reopened.snapshot == expectedSnapshot)
    #expect(reopened.ops.count == count, "The log must survive an interrupted compaction")
    #expect(reopened.malformedLineCount == 0)

    var replayed = try #require(reopened.snapshot)
    for mutation in reopened.ops {
      replayed[mutation.key] = mutation.value
    }
    #expect(replayed == snapshot)
    #expect(replayed["old"] == "done")
    #expect(replayed["removed"] == nil)
    #expect(replayed["updated"] == "edited")

    // A subsequent successful snapshot also works with any leftover .tmp file.
    try makeStore(in: directory).writeSnapshot(replayed)
    let recovered = makeStore(in: directory).load()
    #expect(recovered.snapshot == snapshot)
    #expect(recovered.ops.isEmpty)
    let temporarySnapshot = directory.appendingPathComponent("snapshot.json.tmp")
    #expect(!FileManager.default.fileExists(atPath: temporarySnapshot.path))
  }

  @Test func successfulReplacementKeepsHistoryAndTruncatesLog() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = makeStore(in: directory)
    try store.writeSnapshot(["old": "done"])
    let snapshot = ["old": "done", "new": "done"]
    store.append(Mutation(key: "new", value: "done"), currentSnapshot: { snapshot })
    store.flushForTesting()

    try store.writeSnapshot(snapshot)

    let reopened = makeStore(in: directory).load()
    #expect(reopened.snapshotStatus == .loaded)
    #expect(reopened.snapshot == snapshot)
    #expect(reopened.ops.isEmpty)
  }
}
