import Observation

/// Counts Observation change notifications for what `read` touches, synchronously.
///
/// `withObservationTracking` is one-shot and calls `onChange` from the mutation's willSet. The
/// probe counts that call and re-registers right there, so every later change counts too and a
/// test can assert immediately after a write, without awaiting. Because re-registration runs
/// during willSet, `read` sees the old values: give it a fixed set of reads (the dependencies a
/// view or query registers), not reads that branch on the values being changed. Mutate the
/// observed objects on the main actor.
@MainActor
final class ObservationProbe {
  private(set) var changeCount = 0
  private let read: @MainActor () -> Void
  private let onChange: @MainActor () -> Void
  private var isActive = true

  init(
    _ read: @escaping @MainActor () -> Void,
    onChange: @escaping @MainActor () -> Void = {}
  ) {
    self.read = read
    self.onChange = onChange
    register()
  }

  /// Stops counting; the pending registration fires once more without effect.
  func stop() { isActive = false }

  private func register() {
    withObservationTracking {
      read()
    } onChange: { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.isActive else { return }
        self.changeCount += 1
        self.register()
        self.onChange()
      }
    }
  }
}
