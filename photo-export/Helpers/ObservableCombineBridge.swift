import Combine

/// Storage for a property that SwiftUI tracks through Observation while Combine subscribers
/// (AutoSync, the destination adapter) keep `@Published` delivery: synchronous, delivered
/// before the value is stored, replaying the stored value to a new subscriber, and delivered
/// again for a write of the value already held.
///
/// The owner declares the property by hand, registering the read in the getter and writing
/// through `write(_:observingMutation:)`; see `docs/reference/observation-migration-recipe.md`
/// §The bridge for both owner shapes.
///
/// The value is replayed from this storage, not from a `CurrentValueSubject`: the subject
/// changes its value before it delivers, so a subscription made inside a sink would replay the
/// value in flight instead of the stored one.
final class ObservableCombineBridge<Value: Equatable> {
  private var stored: Value
  private let subject = PassthroughSubject<Value, Never>()

  init(_ value: Value) {
    stored = value
  }

  /// The stored value. Read it through the owner's property so the read is tracked.
  var value: Value { stored }

  /// Replays the stored value on subscription, then delivers every write.
  var publisher: AnyPublisher<Value, Never> {
    Deferred { [self] in subject.prepend(stored) }.eraseToAnyPublisher()
  }

  /// Delivers `newValue` and then stores it, inside `observingMutation` (the owner's
  /// `withMutation`). A write equal to the stored value skips `observingMutation`, as the
  /// `@Observable` macro skips notifying for it, but is still delivered.
  func write(_ newValue: Value, observingMutation: (() -> Void) -> Void) {
    guard newValue != stored else {
      deliverAndStore(newValue)
      return
    }
    observingMutation { deliverAndStore(newValue) }
  }

  private func deliverAndStore(_ newValue: Value) {
    subject.send(newValue)
    stored = newValue
  }
}
