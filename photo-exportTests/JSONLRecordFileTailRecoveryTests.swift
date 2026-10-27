import Foundation
import Testing
import os

@testable import Photo_Export

@MainActor
struct JSONLRecordFileTailRecoveryTests {
  private struct Snapshot: Codable, Sendable, Equatable { let ids: [String] }
  private struct Operation: Codable, Sendable, Equatable { let id: String }
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
  ) -> JSONLRecordFile<Snapshot, Operation> {
    JSONLRecordFile(
      snapshotURL: root.appendingPathComponent("snapshot.json"),
      logURL: root.appendingPathComponent("log.jsonl"),
      ioQueue: DispatchQueue(label: "JSONLTail-\(UUID())"),
      logger: Logger(subsystem: TestLogging.subsystem, category: "JSONLTail"),
      fileReplacer: replacer, logIO: io)
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
    let initial = (await first.load())
    let expectedPrefix = tail == .complete ? ["a", "b"] : ["a"]
    #expect(initial.ops.map(\.id) == expectedPrefix)
    first.append(Operation(id: "c"))
    first.append(
      Operation(id: "d"))
    try await first.flush()
    let raw = try Data(contentsOf: root.appendingPathComponent("log.jsonl"))
    #expect(raw.starts(with: original + Data([0x0A])))
    let second = file(root)
    let reloaded = (await second.load())
    #expect(reloaded.ops.map(\.id) == expectedPrefix + ["c", "d"])
    #expect(reloaded.malformedLineCount == (tail == .complete ? 0 : 1))
    second.append(
      Operation(id: "e"))
    try await second.flush()
    let last = (await file(root).load())
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
    _ = (await subject.load())
    subject.append(Operation(id: "c"))
    try await subject.flush()
    let writes = io.writes
    try #require(writes.count == 1, "One operation and all boundary bytes must use one write")
    let payload = writes[0]
    #expect(payload.last == 0x0A)
    #expect((payload.first == 0x0A) == (tail == .complete || tail == .partial))
    #expect(payload.filter { $0 == 0x0A }.count == (tail == .complete || tail == .partial ? 2 : 1))
    let lines = payload.split(separator: 0x0A)
    try #require(lines.count == 1)
    #expect(try JSONDecoder().decode(Operation.self, from: Data(lines[0])) == Operation(id: "c"))
  }

  @Test(arguments: Fault.allCases)
  func repairFailureBlocksLaterOperationsUntilFullSnapshotRecovery(fault: Fault) async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try seed(.complete, at: root)
    let subject = file(root, io: RecordingIO(fault: fault))
    _ = (await subject.load())
    var failures = 0
    subject.onPersistenceFailure = { _ in failures += 1 }
    let retained = Snapshot(ids: ["a", "b", "c", "d"])
    subject.append(Operation(id: "c"))
    subject.append(Operation(id: "d"))
    await #expect(throws: Failure.self) { try await subject.flush() }
    #expect(failures == 1)
    #expect(subject.hasUnflushedChanges)
    let beforeRetry = (await file(root).load())
    #expect(
      beforeRetry.ops.contains(Operation(id: "b")),
      "Recovered B must not merge with the failed repair")
    #expect(
      !beforeRetry.ops.contains(Operation(id: "d")), "Later D must not pass a failed write or sync")
    try await subject.checkpoint(retained, recovering: true)
    try await subject.flush()
    #expect(!subject.hasUnflushedChanges)
    let recording = RecordingIO()
    let reopened = file(root, io: recording)
    #expect((await reopened.load()).snapshot == retained)
    reopened.append(Operation(id: "e"))
    try await reopened.flush()
    #expect(recording.writes.count == 1)
    #expect(recording.writes.first?.first != 0x0A)
    let final = (await file(root).load())
    #expect(final.snapshot == retained)
    #expect(final.ops == [Operation(id: "e")])
    #expect(final.malformedLineCount == 0)
  }

  @Test(arguments: [false, true])
  func successfulSnapshotOrResetClearsUnconsumedBoundary(reset: Bool) async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try seed(.complete, at: root)
    let io = RecordingIO()
    let subject = file(root, io: io)
    _ = (await subject.load())
    let snapshot = Snapshot(ids: reset ? [] : ["a", "b"])
    try await subject.checkpoint(snapshot, recovering: true, resetCorrupt: reset)
    subject.append(Operation(id: "c"))
    try await subject.flush()
    #expect(io.writes.count == 1)
    #expect(io.writes.first?.first != 0x0A)
    #expect((await file(root).load()).ops == [Operation(id: "c")])
  }

}
