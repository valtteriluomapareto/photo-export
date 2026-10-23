import Foundation

@testable import Photo_Export

/// Wraps the real serial worker so tests can prove a read retained its injected context.
final class RecordingDestinationIO: DestinationIOExecuting, @unchecked Sendable {
  let submissions = LockedBox(0)
  let workerChecks = LockedBox<[Bool]>([])
  private let key = DispatchSpecificKey<Bool>()
  private let worker: DestinationIO
  private let beforeLeaf: @Sendable (Int) -> Void

  init(beforeLeaf: @escaping @Sendable (Int) -> Void = { _ in }) {
    self.beforeLeaf = beforeLeaf
    let queue = DispatchQueue(label: "test.destination-io", qos: .utility)
    queue.setSpecific(key: key, value: true)
    worker = DestinationIO(queue: queue)
  }

  func run<Value: Sendable>(_ operation: @escaping @Sendable () -> Value) async -> Value {
    submissions.mutate { $0 += 1 }
    return await worker.run { [self] in
      workerChecks.mutate {
        $0.append(pthread_main_np() == 0 && DispatchQueue.getSpecific(key: key) == true)
      }
      beforeLeaf(workerChecks.value.count)
      return operation()
    }
  }

  func run<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws
    -> Value
  {
    submissions.mutate { $0 += 1 }
    return try await worker.run { [self] in
      workerChecks.mutate {
        $0.append(pthread_main_np() == 0 && DispatchQueue.getSpecific(key: key) == true)
      }
      beforeLeaf(workerChecks.value.count)
      return try operation()
    }
  }
}
