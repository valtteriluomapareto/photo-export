import Foundation

/// A test-only synchronization primitive that replaces "sleep N ms then poll for
/// transient state" patterns with deterministic checkpoints.
///
/// Two-sided contract:
/// - Code under test calls `await checkpoint.enter()` at the point we want to
///   observe and pause execution. The call suspends until a matching
///   `release()` (or `releaseAll()`) is issued.
/// - Tests call `await checkpoint.waitForEnter(count:)` to suspend until N
///   writers have arrived, then call `release(_:)` to let some or all of them
///   continue. `releaseAll()` lets every current and future enter through (used
///   by harness teardown).
///
/// Why an actor rather than a lock + continuations: the actor's mailbox already
/// gives us exclusive access to mutable state, so we don't have to reason about
/// whether a `release()` racing with an `enter()` can leak a continuation.
///
/// Cancellation: if the surrounding `Task` is cancelled while suspended in
/// `enter()`, the continuation will leak unless `releaseAll()` is called during
/// teardown. Test harnesses must call `releaseAll()` in their cleanup so a
/// `cancelAndClear()` (or any other cancellation path) doesn't strand a
/// suspended write task forever.
actor AsyncCheckpoint {
  private var enteredCount = 0
  private var pending: [CheckedContinuation<Void, Never>] = []
  private var spareReleases = 0
  private struct Observer {
    let id: Int
    let target: Int
    let continuation: CheckedContinuation<Void, Never>
  }
  private var observers: [Observer] = []
  private var nextObserverID = 0
  private var isShutdown = false

  /// Number of `enter()` calls that have arrived so far. Lets tests assert
  /// "exactly N writers reached the gate."
  var enteredSoFar: Int { enteredCount }

  /// Registered `waitForEnter` observers; lets tests prove a cancelled wait leaves none behind.
  var observerCountForTesting: Int { observers.count }

  /// Called by the code under test (typically inside a fake's async method).
  /// Records the arrival, fires any matching `waitForEnter` observers, then
  /// suspends until a `release` ticket is available.
  func enter() async {
    enteredCount += 1
    fireObservers()
    if isShutdown {
      return
    }
    if spareReleases > 0 {
      spareReleases -= 1
      return
    }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      pending.append(continuation)
    }
  }

  /// Releases up to `count` queued enters. If fewer are queued, the remaining
  /// tickets become "spare" and the next `enter()` will pass through without
  /// suspending.
  func release(_ count: Int = 1) {
    var remaining = count
    while remaining > 0, !pending.isEmpty {
      pending.removeFirst().resume()
      remaining -= 1
    }
    spareReleases += remaining
  }

  /// Suspends until `enteredSoFar >= count`, the gate shuts down, or the waiting task is
  /// cancelled (for example by its test's `.timeLimit`). Returns whether the count was reached,
  /// so callers can `#require` it without a separate wall-clock deadline.
  @discardableResult
  func waitForEnter(count: Int) async -> Bool {
    if enteredCount >= count || isShutdown { return enteredCount >= count }
    let id = nextObserverID
    nextObserverID += 1
    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        // Cancellation that arrived before registration never finds this observer to resume.
        if Task.isCancelled {
          continuation.resume()
        } else {
          observers.append(Observer(id: id, target: count, continuation: continuation))
        }
      }
    } onCancel: {
      Task { await self.cancelObserver(id) }
    }
    return enteredCount >= count
  }

  private func cancelObserver(_ id: Int) {
    guard let index = observers.firstIndex(where: { $0.id == id }) else { return }
    observers.remove(at: index).continuation.resume()
  }

  /// Permanently opens the gate. Resumes every pending `enter()` and every
  /// `waitForEnter`; future `enter()` calls return immediately. Required in
  /// test harness teardown so a stranded write task can't outlive the test.
  func releaseAll() {
    isShutdown = true
    let toResume = pending
    pending.removeAll()
    for continuation in toResume { continuation.resume() }
    let toFire = observers
    observers.removeAll()
    for observer in toFire { observer.continuation.resume() }
  }

  private func fireObservers() {
    var remaining: [Observer] = []
    var toFire: [CheckedContinuation<Void, Never>] = []
    for observer in observers {
      if observer.target <= enteredCount {
        toFire.append(observer.continuation)
      } else {
        remaining.append(observer)
      }
    }
    observers = remaining
    for continuation in toFire { continuation.resume() }
  }
}
