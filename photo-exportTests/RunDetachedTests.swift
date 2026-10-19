import Foundation
import Testing

@testable import Photo_Export

/// `runDetached` forwards the caller's cancellation to the detached operation and still
/// waits for the operation to finish.
@Suite(.timeLimit(.minutes(1)))
struct RunDetachedTests {
  private actor Log {
    private(set) var events: [String] = []
    func append(_ event: String) { events.append(event) }
  }

  @Test func cancellingTheCallerReachesTheOperationAfterItsCurrentStep() async throws {
    let gate = AsyncCheckpoint()
    defer { Task { await gate.releaseAll() } }
    let log = Log()
    let caller = Task {
      await runDetached {
        await gate.enter()
        await log.append(Task.isCancelled ? "operation saw cancel" : "operation not cancelled")
      }
      await log.append("caller returned")
    }
    let started = await gate.waitForEnter(count: 1)
    try #require(started)

    caller.cancel()
    await gate.releaseAll()
    await caller.value

    #expect(await log.events == ["operation saw cancel", "caller returned"])
  }

  @Test func aCallerCancelledBeforehandCancelsTheOperation() async {
    let caller = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      // Waits for the forwarded cancellation; without it the suite's time limit fails this.
      return await runDetached { () async -> Bool in
        do {
          try await Task.sleep(for: .seconds(86_400))
          return false
        } catch { return true }
      }
    }
    #expect(await caller.value)
  }

  @Test func theThrowingVariantReportsCancellation() async throws {
    let gate = AsyncCheckpoint()
    defer { Task { await gate.releaseAll() } }
    let caller = Task {
      try await runDetached {
        await gate.enter()
        try Task.checkCancellation()
        return 1
      }
    }
    let started = await gate.waitForEnter(count: 1)
    try #require(started)
    caller.cancel()
    await gate.releaseAll()
    let result = await caller.result
    #expect(throws: CancellationError.self) { try result.get() }
  }
}
