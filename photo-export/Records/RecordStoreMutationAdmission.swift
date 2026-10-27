import Foundation

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
