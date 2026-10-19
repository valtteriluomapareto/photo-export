import Foundation
import Testing
import os

@testable import Photo_Export

@MainActor
struct JSONLRecordFileTailRecoveryTests {
  private struct Snapshot: Codable, Sendable, Equatable { let ids: [String] }
  private struct Op: Codable, Sendable, Equatable { let id: String }
  enum Tail: CaseIterable, Sendable { case empty, terminated, complete, partial }
  enum Fault: CaseIterable, Sendable { case open, partialWrite, synchronize }
  private enum Failure: Error { case injected }

  private final class RecordingIO: JSONLRecordLogIO, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [Data] = []
    private let production = ProductionJSONLRecordLogIO()
    let fault: Fault?
    init(fault: Fault? = nil) { self.fault = fault }
    var writes: [Data] { lock.withLock { captured } }
    func readIfPresent(at url: URL) throws -> Data? { try production.readIfPresent(at: url) }
    func openForAppending(at url: URL) throws -> FileHandle {
      if fault == .open { throw Failure.injected }
      return try production.openForAppending(at: url)
    }
    func write(_ data: Data, to handle: FileHandle) throws {
      lock.withLock { captured.append(data) }
      if fault == .partialWrite {
        try production.write(Data(data.prefix(max(1, data.count / 2))), to: handle)
        throw Failure.injected
      }
      try production.write(data, to: handle)
    }
    func synchronize(_ handle: FileHandle) throws {
      if fault == .synchronize { throw Failure.injected }
      try production.synchronize(handle)
    }
  }

  private struct FailedReplacement: AtomicFileReplacing {
    func replaceItemAtomically(from source: URL, to destination: URL) throws {
      throw Failure.injected
    }
  }

  private func directory() throws -> URL {
    let url = TestScratch.directory("JSONLTail")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func file(
    _ root: URL, io: any JSONLRecordLogIO = ProductionJSONLRecordLogIO(),
    replacer: any AtomicFileReplacing = FileIOService()
  ) -> JSONLRecordFile<Snapshot, Op> {
    JSONLRecordFile(
      snapshotURL: root.appendingPathComponent("snapshot.json"),
      logURL: root.appendingPathComponent("log.jsonl"),
      ioQueue: DispatchQueue(label: "JSONLTail-\(UUID())"),
      logger: Logger(subsystem: "test", category: "JSONLTail"), fileReplacer: replacer, logIO: io)
  }

  private func seed(_ tail: Tail, at root: URL) throws -> Data {
    let text: String
    switch tail {
    case .empty: text = ""
    case .terminated: text = "{\"id\":\"a\"}\n"
    case .complete: text = "{\"id\":\"a\"}\n{\"id\":\"b\"}"
    case .partial: text = "{\"id\":\"a\"}\n{\"id\":\"partial"
    }
    let bytes = Data(text.utf8)
    try bytes.write(to: root.appendingPathComponent("log.jsonl"))
    return bytes
  }

  @Test(arguments: [Tail.complete, .partial])
  func appendAfterRecoveredTailSurvivesFurtherReloads(tail: Tail) async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = try seed(tail, at: root)
    let first = file(root)
    let initial = first.load()
    let expectedPrefix = tail == .complete ? ["a", "b"] : ["a"]
    #expect(initial.ops.map(\.id) == expectedPrefix)
    first.append(Op(id: "c"), currentSnapshot: { Snapshot(ids: expectedPrefix + ["c"]) })
    first.append(Op(id: "d"), currentSnapshot: { Snapshot(ids: expectedPrefix + ["c", "d"]) })
    try await first.flush()
    let raw = try Data(contentsOf: root.appendingPathComponent("log.jsonl"))
    #expect(raw.starts(with: original + Data([0x0A])))
    let second = file(root)
    let reloaded = second.load()
    #expect(reloaded.ops.map(\.id) == expectedPrefix + ["c", "d"])
    #expect(reloaded.malformedLineCount == (tail == .complete ? 0 : 1))
    second.append(
      Op(id: "e"), currentSnapshot: { Snapshot(ids: expectedPrefix + ["c", "d", "e"]) })
    try await second.flush()
    let last = file(root).load()
    #expect(last.ops.map(\.id) == expectedPrefix + ["c", "d", "e"])
    #expect(last.malformedLineCount == (tail == .complete ? 0 : 1))
  }

  @Test(arguments: Tail.allCases)
  func admittedOperationUsesOneDelimitedWrite(tail: Tail) async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try seed(tail, at: root)
    let io = RecordingIO()
    let subject = file(root, io: io)
    _ = subject.load()
    subject.append(Op(id: "c"), currentSnapshot: { Snapshot(ids: ["c"]) })
    try await subject.flush()
    let writes = io.writes
    try #require(writes.count == 1, "One operation and all boundary bytes must use one write")
    let payload = writes[0]
    #expect(payload.last == 0x0A)
    #expect((payload.first == 0x0A) == (tail == .complete || tail == .partial))
    #expect(payload.filter { $0 == 0x0A }.count == (tail == .complete || tail == .partial ? 2 : 1))
    let lines = payload.split(separator: 0x0A)
    try #require(lines.count == 1)
    #expect(try JSONDecoder().decode(Op.self, from: Data(lines[0])) == Op(id: "c"))
  }

  @Test(arguments: Fault.allCases)
  func repairFailureBlocksLaterOperationsUntilFullSnapshotRecovery(fault: Fault) async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try seed(.complete, at: root)
    let subject = file(root, io: RecordingIO(fault: fault))
    _ = subject.load()
    var failures = 0
    subject.onPersistenceFailure = { _ in failures += 1 }
    let retained = Snapshot(ids: ["a", "b", "c", "d"])
    subject.append(Op(id: "c"), currentSnapshot: { retained })
    subject.append(Op(id: "d"), currentSnapshot: { retained })
    await #expect(throws: Failure.self) { try await subject.flush() }
    #expect(failures == 1)
    #expect(subject.hasUnflushedChanges)
    let beforeRetry = file(root).load()
    #expect(
      beforeRetry.ops.contains(Op(id: "b")), "Recovered B must not merge with the failed repair")
    #expect(!beforeRetry.ops.contains(Op(id: "d")), "Later D must not pass a failed write or sync")
    try subject.writeSnapshot(retained)
    try await subject.flush()
    #expect(!subject.hasUnflushedChanges)
    let recording = RecordingIO()
    let reopened = file(root, io: recording)
    #expect(reopened.load().snapshot == retained)
    reopened.append(Op(id: "e"), currentSnapshot: { Snapshot(ids: retained.ids + ["e"]) })
    try await reopened.flush()
    #expect(recording.writes.count == 1)
    #expect(recording.writes.first?.first != 0x0A)
    let final = file(root).load()
    #expect(final.snapshot == retained)
    #expect(final.ops == [Op(id: "e")])
    #expect(final.malformedLineCount == 0)
  }

  @Test(arguments: [false, true])
  func successfulSnapshotOrResetClearsUnconsumedBoundary(reset: Bool) async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try seed(.complete, at: root)
    let io = RecordingIO()
    let subject = file(root, io: io)
    _ = subject.load()
    let snapshot = Snapshot(ids: reset ? [] : ["a", "b"])
    if reset {
      try subject.resetToEmpty(emptySnapshot: snapshot)
    } else {
      try subject.writeSnapshot(snapshot)
    }
    subject.append(Op(id: "c"), currentSnapshot: { Snapshot(ids: snapshot.ids + ["c"]) })
    try await subject.flush()
    #expect(io.writes.count == 1)
    #expect(io.writes.first?.first != 0x0A)
    #expect(file(root).load().ops == [Op(id: "c")])
  }

  @Test func failedSnapshotKeepsTheUnconsumedBoundary() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try seed(.complete, at: root)
    let subject = file(root, replacer: FailedReplacement())
    _ = subject.load()
    #expect(throws: Failure.self) { try subject.writeSnapshot(Snapshot(ids: ["a", "b"])) }
    subject.append(Op(id: "c"), currentSnapshot: { Snapshot(ids: ["a", "b", "c"]) })
    try await subject.flush()
    let reloaded = file(root).load()
    #expect(reloaded.snapshot == nil)
    #expect(reloaded.ops.map(\.id) == ["a", "b", "c"])
    #expect(reloaded.malformedLineCount == 0)
  }
}
