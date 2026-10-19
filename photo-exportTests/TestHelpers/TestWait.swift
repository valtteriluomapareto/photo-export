import Foundation
import Testing

/// Waits until `predicate` holds, re-checking after each 10 ms turn.
///
/// There is deliberately no per-wait wall-clock deadline. On the 3-vCPU CI runner every test
/// shares one congested main actor, and a trivial synchronous test can wait seconds for its first
/// turn, so fixed 3–15 s deadlines measured scheduler load rather than progress (issue #277). The
/// backstop is the enclosing test's `.timeLimit`: when it expires Swift Testing cancels the test,
/// and this returns `false` after recording which condition was still pending. Callers then
/// `#require`/`#expect` the result as before.
@MainActor
func eventually(
  _ label: String,
  sourceLocation: SourceLocation = #_sourceLocation,
  _ predicate: () async -> Bool
) async -> Bool {
  if Test.current != nil, Test.current?.timeLimit == nil {
    Issue.record(
      "eventually(\"\(label)\") needs a .timeLimit on its test or suite as its hang backstop",
      sourceLocation: sourceLocation)
  }
  let clock = ContinuousClock()
  let start = clock.now
  var reportedSlow = false
  while true {
    if await predicate() { return true }
    if Task.isCancelled {
      Issue.record(
        "Cancelled while waiting for: \(label)", sourceLocation: sourceLocation)
      return false
    }
    if !reportedSlow, clock.now - start > .seconds(10) {
      reportedSlow = true
      print("eventually(\"\(label)\") still pending after 10 s at \(sourceLocation)")
    }
    try? await Task.sleep(for: .milliseconds(10))
  }
}

/// Awaits `task` to finish, or returns `false` as soon as the waiting task is cancelled.
///
/// `await task.value` ignores cancellation of the awaiting task. When the awaited work is held by
/// a gate that only teardown releases, a test cancelled by its `.timeLimit` would otherwise never
/// return to that teardown.
func finished<Success: Sendable, Failure: Error>(
  _ task: Task<Success, Failure>
) async -> Bool {
  let resumption = SingleResumption()
  return await withTaskCancellationHandler {
    await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      resumption.install(continuation)
      Task {
        _ = await task.result
        resumption.resume(returning: true)
      }
    }
  } onCancel: {
    resumption.resume(returning: false)
  }
}

/// Resumes a continuation exactly once, whichever of completion or cancellation comes first,
/// including cancellation that arrives before the continuation is installed.
private final class SingleResumption: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Bool, Never>?
  private var pending: Bool?

  func install(_ continuation: CheckedContinuation<Bool, Never>) {
    let early: Bool? = lock.withLock {
      if let pending { return pending }
      self.continuation = continuation
      return nil
    }
    if let early { continuation.resume(returning: early) }
  }

  func resume(returning value: Bool) {
    let continuation: CheckedContinuation<Bool, Never>? = lock.withLock {
      if let continuation = self.continuation {
        self.continuation = nil
        pending = value
        return continuation
      }
      if pending == nil { pending = value }
      return nil
    }
    continuation?.resume(returning: value)
  }
}
