import Foundation

/// Runs admitted synchronous IO to physical completion, independently of caller cancellation.
/// A leaf must not await, submit nested work or synchronously wait for an actor.
protocol DestinationIOExecuting: Sendable {
  func run<Value: Sendable>(_ operation: @escaping @Sendable () -> Value) async -> Value
  func run<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws
    -> Value
}

/// One serial utility worker retained for a logical export destination.
final class DestinationIO: DestinationIOExecuting {
  private let queue: DispatchQueue

  init(queue: DispatchQueue = DispatchQueue(label: "photo-export.destination-io", qos: .utility)) {
    self.queue = queue
  }

  func run<Value: Sendable>(_ operation: @escaping @Sendable () -> Value) async -> Value {
    await withCheckedContinuation { continuation in
      queue.async { continuation.resume(returning: operation()) }
    }
  }

  func run<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws
    -> Value
  {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { continuation.resume(with: Result { try operation() }) }
    }
  }
}
