import Foundation
import Observation

/// Re-registering `withObservationTracking` counter. The primitive is
/// one-shot, so this helper hops to the main queue after each fire to
/// re-register without re-reading the pre-mutation state.
@MainActor
final class ObservationCounter {
  private(set) var changeCount: Int = 0

  private let read: @MainActor () -> Void
  private var pending: [UUID: CheckedContinuation<Int, any Error>] = [:]

  init(read: @escaping @MainActor () -> Void) {
    self.read = read
    register()
  }

  /// Suspends until the next tracked-property change. Throws
  /// `ObservationCounterTimeout` if no change arrives within `timeout` so a
  /// misuse fails loudly instead of hanging CI.
  func waitForNextChange(timeout: Duration = .seconds(1)) async throws -> Int {
    let id = UUID()
    return try await withCheckedThrowingContinuation { continuation in
      pending[id] = continuation
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: timeout)
        guard let self else { return }
        if let cont = self.pending.removeValue(forKey: id) {
          cont.resume(throwing: ObservationCounterTimeout())
        }
      }
    }
  }

  private func register() {
    withObservationTracking {
      read()
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.changeCount += 1
        let waiting = self.pending
        self.pending.removeAll()
        for (_, cont) in waiting {
          cont.resume(returning: self.changeCount)
        }
        self.register()
      }
    }
  }
}

struct ObservationCounterTimeout: Error {}
