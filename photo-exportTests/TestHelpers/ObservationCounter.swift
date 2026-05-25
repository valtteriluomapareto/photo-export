import Foundation
import Observation

/// Test helper for `withObservationTracking`. SwiftUI's Observation tracking
/// primitive is one-shot — after the `onChange` block fires, the tracking
/// scope is dead until you set up a new one. Most tests want a *running*
/// count of how many times tracked properties changed, so this helper
/// re-registers itself automatically.
///
/// Wiring:
///
/// ```swift
/// let counter = ObservationCounter { [model] in _ = model.someProperty }
/// model.someProperty = "new"
/// await counter.waitForNextChange()
/// XCTAssertEqual(counter.changeCount, 1)
/// ```
///
/// The `read` closure should touch *only* the properties whose changes the
/// test cares about — any property read while tracking is registered counts
/// as a dependency, so unrelated reads inflate the count.
@MainActor
final class ObservationCounter {
  /// Number of times the `read` closure's tracked properties have changed
  /// since the counter was created (or last reset).
  private(set) var changeCount: Int = 0

  private let read: @MainActor () -> Void
  private var isObserving: Bool = true
  private var continuations: [CheckedContinuation<Int, Never>] = []

  init(read: @escaping @MainActor () -> Void) {
    self.read = read
    register()
  }

  /// Stops re-registering after the next change. The counter freezes at its
  /// current value — useful when a test wants to assert "no further changes
  /// happen during phase B" after measuring phase A.
  func stop() {
    isObserving = false
  }

  /// Resets the counter to zero. Does not affect the underlying tracking
  /// registration; subsequent mutations continue to increment from 0.
  func reset() {
    changeCount = 0
  }

  /// Suspends until the next tracked-property change. Returns the new value
  /// of `changeCount` after that change lands. Tests that mutate observable
  /// state synchronously can `await` this to deflake the
  /// "tracking re-registers on the main queue" hop.
  func waitForNextChange() async -> Int {
    await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
  }

  private func register() {
    withObservationTracking {
      read()
    } onChange: { [weak self] in
      // Observation invokes `onChange` synchronously before the mutation
      // actually lands. Hop to the main queue so the increment + the
      // re-registration both happen after the new property value is visible.
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.changeCount += 1
        let waiting = self.continuations
        self.continuations.removeAll()
        for continuation in waiting {
          continuation.resume(returning: self.changeCount)
        }
        if self.isObserving {
          self.register()
        }
      }
    }
  }
}
