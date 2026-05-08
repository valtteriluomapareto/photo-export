import Foundation

/// Abstraction over time used by AutoSync and the export managers. The default production
/// implementation reads the system clock; tests inject `TestClock` (in `photo-exportTests/`)
/// to advance time deterministically without wall-clock waits.
///
/// Scoped to AutoSync's needs (read-now + schedule-after + cancel) rather than conforming to
/// `Swift.Clock` to keep the surface small and the test-double implementation tractable. All
/// callers and implementations are `@MainActor`-bound to match the rest of the manager layer.
@MainActor
protocol AutoSyncClock {
  /// Current wall-clock time. Used for timestamping run summaries, retry windows, and
  /// debounce `fireAt` values.
  func now() -> Date

  /// Schedules `work` to run after `delay` seconds from now. Returns a token whose `cancel()`
  /// prevents the work from running. `delay <= 0` schedules at the next runloop tick.
  @discardableResult
  func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> AutoSyncCancellable
}

/// Token returned by `AutoSyncClock.schedule`. `cancel()` is idempotent — calling it more
/// than once is safe.
@MainActor
protocol AutoSyncCancellable: AnyObject {
  func cancel()
}

/// Production clock backed by `Date()` and `Task.sleep(nanoseconds:)`. The scheduled task
/// runs on the main actor, matching the rest of the manager layer.
///
/// Cancellation contract: `cancel()` and the scheduled work both execute on `@MainActor`.
/// The main actor does not preempt, so the `isCancelled` check + `work()` invocation are
/// atomic with respect to any other main-actor code, including a `cancel()` call from another
/// `Task`. This means: after `cancel()` returns, the work either (a) has not yet reached
/// its `isCancelled` check and will not run, or (b) has already completed. There is no
/// interleaving where `cancel()` arrives "between" the check and the invocation. This
/// matches the `TestClock` contract where in-window cancellation is honored.
@MainActor
final class SystemAutoSyncClock: AutoSyncClock {
  init() {}

  func now() -> Date { Date() }

  @discardableResult
  func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> AutoSyncCancellable {
    let task = Task { @MainActor in
      let nanos = UInt64(max(0, delay) * 1_000_000_000)
      try? await Task.sleep(nanoseconds: nanos)
      if Task.isCancelled { return }
      work()
    }
    return TaskAutoSyncCancellable(task: task)
  }
}

private final class TaskAutoSyncCancellable: AutoSyncCancellable {
  private let task: Task<Void, Never>
  init(task: Task<Void, Never>) {
    self.task = task
  }
  func cancel() {
    task.cancel()
  }
}
