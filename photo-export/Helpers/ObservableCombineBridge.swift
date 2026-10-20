import Combine
import Foundation

/// Holds a property that SwiftUI tracks through Observation while Combine subscribers
/// (AutoSync, the destination adapter) keep `@Published` delivery: synchronous, delivered
/// before the value is stored, replaying the stored value to a new subscriber, and delivered
/// again for a write of the value already held.
///
/// The owner declares the property by hand, registering the read in the getter and writing
/// through `write(_:observingMutation:)`; see `docs/reference/observation-migration-recipe.md`
/// §The bridge for both owner shapes.
///
/// Each subscription joins the bridge before it receives its replay, so a write made while a
/// subscriber receives the replayed value reaches it. Values are delivered only while the
/// subscriber has demand; otherwise one value is kept per subscriber, the latest write winning,
/// and delivered when it next requests. Demand a subscriber returns from `receive` is recorded
/// without delivering the kept value, which waits for the next write or request. All of this is
/// what `@Published` does. The replay is the stored value, not a `CurrentValueSubject`'s: the
/// subject changes its value before it delivers, so a subscription made inside a sink would
/// replay the value in flight. Subscribers receive each write in the order they subscribed, and
/// a cancelled subscriber receives nothing more, not even the write in flight.
///
/// Main-actor bound like its owners: subscribing or requesting off the main actor traps.
/// Cancelling off the main actor is allowed, as it is for `@Published` (an `AnyCancellable`
/// released in a background deinit), and takes effect once it reaches the main queue.
@MainActor
final class ObservableCombineBridge<Value: Equatable> {
  private var stored: Value
  private var subscriptions: [BridgeSubscription<Value>] = []

  init(_ value: Value) {
    stored = value
  }

  /// The stored value. Read it through the owner's property so the read is tracked.
  var value: Value { stored }

  /// Replays the stored value on subscription, then delivers every write.
  var publisher: AnyPublisher<Value, Never> { BridgePublisher(bridge: self).eraseToAnyPublisher() }

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
    // A subscription made during this delivery replays the stored value and misses this one.
    for subscription in subscriptions { subscription.offer(newValue) }
    stored = newValue
  }

  fileprivate func attach<S: Subscriber>(_ subscriber: S)
  where S.Input == Value, S.Failure == Never {
    let subscription = BridgeSubscription(bridge: self, subscriber: subscriber, replay: stored)
    subscriptions.append(subscription)
    subscriber.receive(subscription: subscription)
  }

  fileprivate func detach(_ subscription: BridgeSubscription<Value>) {
    subscriptions.removeAll { $0 === subscription }
  }
}

private struct BridgePublisher<Value: Equatable>: Publisher {
  typealias Output = Value
  typealias Failure = Never

  let bridge: ObservableCombineBridge<Value>

  func receive<S: Subscriber>(subscriber: S) where S.Input == Value, S.Failure == Never {
    MainActor.assumeIsolated { bridge.attach(subscriber) }
  }
}

/// One subscriber's demand, and the latest value it has not had demand for yet.
@MainActor
private final class BridgeSubscription<Value: Equatable>: Subscription {
  private weak var bridge: ObservableCombineBridge<Value>?
  private var subscriber: AnySubscriber<Value, Never>?
  private var demand = Subscribers.Demand.none
  private var pending: Value?

  init<S: Subscriber>(bridge: ObservableCombineBridge<Value>, subscriber: S, replay: Value)
  where S.Input == Value, S.Failure == Never {
    self.bridge = bridge
    self.subscriber = AnySubscriber(subscriber)
    pending = replay
  }

  func offer(_ value: Value) {
    guard subscriber != nil else { return }
    pending = value
    drain()
  }

  nonisolated func request(_ demand: Subscribers.Demand) {
    MainActor.assumeIsolated { add(demand) }
  }

  nonisolated func cancel() {
    if Thread.isMainThread {
      MainActor.assumeIsolated { end() }
    } else {
      DispatchQueue.main.async { MainActor.assumeIsolated { self.end() } }
    }
  }

  private func add(_ more: Subscribers.Demand) {
    demand += more
    drain()
  }

  /// The only delivery path: hands over the kept value if there is demand for it. Demand that
  /// `receive` returns is only recorded, so a value kept meanwhile waits, as with `@Published`.
  private func drain() {
    guard let subscriber, demand > 0, let value = pending else { return }
    pending = nil
    demand -= 1
    demand += subscriber.receive(value)
  }

  private func end() {
    subscriber = nil
    pending = nil
    bridge?.detach(self)
  }
}
