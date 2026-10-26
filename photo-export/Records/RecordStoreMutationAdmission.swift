import Foundation
import Synchronization

/// Conservatively estimates replay work; the checkpoint boundary leaves headroom for one batch.
struct RecordReplayBudget: Sendable {
  private let operationNanoseconds: UInt64
  private let byteNanoseconds: UInt64
  private var operationWork: UInt64 = 0
  private var byteWork: UInt64 = 0
  private(set) var operationCount = 0

  init(operationNanoseconds: UInt64 = 200_000, byteNanoseconds: UInt64 = 250) {
    self.operationNanoseconds = operationNanoseconds
    self.byteNanoseconds = byteNanoseconds
  }

  var hasWork: Bool { operationWork > 0 || byteWork > 0 }
  var needsCheckpoint: Bool { max(operationWork, byteWork) >= 750_000_000 }
  var needsIdleCheckpoint: Bool { operationCount >= 1_000 || needsCheckpoint }

  mutating func record(encodedBytes: Int) {
    operationCount += 1
    operationWork = min(UInt64.max - operationNanoseconds, operationWork) + operationNanoseconds
    let bytes = UInt64(max(0, encodedBytes))
    let work = bytes.multipliedReportingOverflow(by: byteNanoseconds)
    let addition = work.overflow ? UInt64.max : work.partialValue
    byteWork = min(UInt64.max - addition, byteWork) + addition
  }

  /// Adopts replay work counted off-main without walking the loaded log again.
  mutating func adopt(operationCount: Int, encodedBytes: Int, measuredNanoseconds: UInt64 = 0) {
    self.operationCount = max(0, operationCount)
    let operations = UInt64(self.operationCount).multipliedReportingOverflow(
      by: operationNanoseconds)
    let bytes = UInt64(max(0, encodedBytes)).multipliedReportingOverflow(by: byteNanoseconds)
    operationWork = max(
      operations.overflow ? UInt64.max : operations.partialValue, measuredNanoseconds)
    byteWork = bytes.overflow ? UInt64.max : bytes.partialValue
  }

  mutating func didCheckpoint() {
    operationWork = 0
    byteWork = 0
    operationCount = 0
  }
}

struct RecordMutationTicket: Equatable {
  let file: ObjectIdentifier?
  let load: UInt64
  let epoch: UInt64
}

/// Owns a store's physical checkpoint boundary. Mutations remain synchronous once admitted.
@MainActor
final class RecordStoreMutationAdmission {
  private(set) var isClosed = false
  private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
  private var depth = 0
  private var pendingCheckpoint: (@MainActor () async -> Void)?
  private var checkpointTask: Task<Void, Never>?
  var pendingWaiterCount: Int { waiters.count }

  func waitUntilOpen(respectingCancellation: Bool = true) async throws {
    if respectingCancellation { try Task.checkCancellation() }
    while isClosed {
      let id = UUID()
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Void, Error>) in
          if respectingCancellation && Task.isCancelled {
            continuation.resume(throwing: CancellationError())
          } else {
            waiters[id] = continuation
          }
        }
      } onCancel: {
        guard respectingCancellation else { return }
        Task { @MainActor [weak self] in
          self?.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        }
      }
      if respectingCancellation { try Task.checkCancellation() }
    }
  }

  func perform<T>(_ body: () throws -> T) rethrows -> T {
    precondition(!isClosed, "History mutation requires open admission")
    depth += 1
    defer {
      depth -= 1
      if depth == 0, let pending = pendingCheckpoint {
        pendingCheckpoint = nil
        _ = requestCheckpoint(pending)
      }
    }
    return try body()
  }

  /// Installs the completed transition in one main turn before other waiters resume.
  func installAfterMaintenance<T>(_ body: () throws -> T) rethrows -> T {
    precondition(isClosed)
    isClosed = false
    defer { isClosed = true }
    return try perform(body)
  }

  @discardableResult
  func requestCheckpoint(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
    if let checkpointTask { return checkpointTask }
    guard depth == 0 else {
      pendingCheckpoint = operation
      return nil
    }
    isClosed = true
    let task = Task {
      await operation()
      checkpointTask = nil
      isClosed = false
      let ready = waiters
      waiters.removeAll()
      for continuation in ready.values { continuation.resume() }
    }
    checkpointTask = task
    return task
  }
}

/// Compatibility callers block while the actual preparation runs on its serial worker.
/// DispatchQueue.sync may execute on the caller's thread, so it cannot establish this boundary.
enum RecordPreparationWorker {
  private final class ResultBox<Value: Sendable>: Sendable {
    private let result = Mutex<Value?>(nil)
    func put(_ value: Value) {
      result.withLock { $0 = value }
    }
    func take() -> Value {
      result.withLock { stored in
        defer { stored = nil }
        return stored!
      }
    }
  }

  nonisolated static func perform<Value: Sendable>(
    on queue: DispatchQueue,
    _ work: @escaping @Sendable () -> Value
  ) -> Value {
    let result = ResultBox<Value>()
    let complete = DispatchSemaphore(value: 0)
    queue.async(qos: .userInteractive, flags: .enforceQoS) {
      precondition(!Thread.isMainThread)
      result.put(work())
      complete.signal()
    }
    complete.wait()
    return result.take()
  }
}
