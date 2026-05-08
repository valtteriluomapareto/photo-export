import Foundation

@testable import Photo_Export

/// Deterministic clock for AutoSync unit tests. Advances only when `advance(by:)` is called,
/// so debounce and retry-timer logic can be exercised without wall-clock waits.
///
/// Usage:
/// ```swift
/// let clock = TestClock()
/// var fired = false
/// clock.schedule(after: 30) { fired = true }
/// clock.advance(by: 10)
/// #expect(fired == false)
/// clock.advance(by: 20)
/// #expect(fired == true)
/// ```
@MainActor
final class TestClock: AutoSyncClock {
  private var current: Date
  private var pending: [PendingWork] = []
  /// Ids removed by `cancel(_:)` while an `advance(by:)` call is mid-flight. The cancelled
  /// item may already have moved out of `pending` and into the in-flight `dueItems` array,
  /// so `cancel` records the id here and the firing loop checks before invoking each work.
  /// This preserves the contract that `cancel()` always prevents work from running, even
  /// when both the cancel and the work fall in the same `advance` window.
  private var cancelledDuringAdvance: Set<UUID> = []

  init(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
    self.current = start
  }

  func now() -> Date { current }

  @discardableResult
  func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> AutoSyncCancellable {
    let item = PendingWork(
      id: UUID(),
      fireAt: current.addingTimeInterval(max(0, delay)),
      work: work
    )
    pending.append(item)
    pending.sort { lhs, rhs in lhs.fireAt < rhs.fireAt }
    return TestCancellable(id: item.id, clock: self)
  }

  /// Advances the clock by `duration` seconds, firing every pending work whose `fireAt` is at
  /// or before the new time, in `fireAt` order. Work scheduled by a fired closure runs only
  /// when the clock is advanced again — the same semantics a real timer has.
  ///
  /// If a firing closure cancels another item whose `fireAt` is also within the current
  /// window, that item is skipped (its id is recorded in `cancelledDuringAdvance` and the
  /// firing loop checks before each invocation).
  func advance(by duration: TimeInterval) {
    let target = current.addingTimeInterval(max(0, duration))
    var dueItems: [PendingWork] = []
    pending.removeAll { item in
      guard item.fireAt <= target else { return false }
      dueItems.append(item)
      return true
    }
    dueItems.sort { lhs, rhs in lhs.fireAt < rhs.fireAt }
    cancelledDuringAdvance.removeAll(keepingCapacity: true)
    for item in dueItems {
      if cancelledDuringAdvance.contains(item.id) {
        continue
      }
      current = item.fireAt
      item.work()
    }
    cancelledDuringAdvance.removeAll(keepingCapacity: true)
    current = target
  }

  /// Number of scheduled-but-not-yet-fired closures. Exposed for test assertions on
  /// cancellation behavior.
  var pendingCount: Int { pending.count }

  fileprivate func cancel(_ id: UUID) {
    pending.removeAll { $0.id == id }
    cancelledDuringAdvance.insert(id)
  }

  private struct PendingWork {
    let id: UUID
    let fireAt: Date
    let work: () -> Void
  }
}

private final class TestCancellable: AutoSyncCancellable {
  private let id: UUID
  private weak var clock: TestClock?

  init(id: UUID, clock: TestClock) {
    self.id = id
    self.clock = clock
  }

  func cancel() {
    clock?.cancel(id)
  }
}
