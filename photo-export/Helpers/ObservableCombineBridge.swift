import Combine

/// `@Published` delivery for a property of an `@Observable` type that Combine code subscribes
/// to through a named accessor.
///
/// The owner holds the bridge as an `@ObservationIgnored let` and writes the property by hand:
///
/// ```swift
/// var value: Int {
///   get {
///     access(keyPath: \.value)
///     return bridge.value
///   }
///   set {
///     guard bridge.needsNotification(for: newValue) else { return bridge.send(newValue) }
///     withMutation(keyPath: \.value) { bridge.send(newValue) }
///   }
/// }
/// var valuePublisher: AnyPublisher<Int, Never> { bridge.publisher }
/// ```
///
/// That keeps `@Published`'s order: Observation's willSet, then the Combine delivery, then the
/// store, so a sink that reads the property still sees the previous value. Every write is
/// delivered, including one that stores the value already held, as `@Published` does. An
/// equal write does not notify Observation, matching what the `@Observable` macro does for a
/// stored `Equatable` property (`ObservationEqualWriteTests`).
final class ObservableCombineBridge<Value> {
  /// The stored value. Kept apart from the subject: a `CurrentValueSubject` updates its value
  /// before delivering, while a `@Published` sink reads the old one.
  private(set) var value: Value
  private let subject = PassthroughSubject<Value, Never>()

  init(_ value: Value) {
    self.value = value
  }

  /// Delivers `newValue` synchronously to every subscriber, then stores it.
  func send(_ newValue: Value) {
    subject.send(newValue)
    value = newValue
  }

  /// Replays the stored value to a new subscriber, then forwards every later `send`. A
  /// subscription made inside a sink replays the previous value and misses the delivery in
  /// flight, as with `$property`.
  var publisher: AnyPublisher<Value, Never> {
    Deferred { Just(self.value) }.append(subject).eraseToAnyPublisher()
  }
}

extension ObservableCombineBridge where Value: Equatable {
  /// Whether a write of `newValue` changes the value, so the owner wraps it in `withMutation`.
  func needsNotification(for newValue: Value) -> Bool {
    newValue != value
  }
}
