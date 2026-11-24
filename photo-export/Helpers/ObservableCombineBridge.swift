import Combine
import Foundation
import os

/// Holds a property that SwiftUI tracks through Observation while Combine subscribers keep
/// exactly what `@Published` delivers: replay, delivery before the store, demand and re-entry.
/// Main-actor bound; cancelling is allowed from any thread. The rules and their tests are in
/// `docs/reference/observation-migration-recipe.md` §The bridge.
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
    // Combine does not mark subscribers Sendable; attachment stays synchronous and checks its actor.
    nonisolated(unsafe) let mainActorSubscriber = subscriber
    MainActor.assumeIsolated { bridge.attach(mainActorSubscriber) }
  }
}

/// One subscriber's demand, and the latest value it has not had demand for yet.
@MainActor
private final class BridgeSubscription<Value: Equatable>: Subscription {
  private weak var bridge: ObservableCombineBridge<Value>?
  private var subscriber: AnySubscriber<Value, Never>?
  private var demand = Subscribers.Demand.none
  private var pending: Value?
  /// Set by `cancel()` on any thread, so delivery stops before the release reaches the main queue.
  private let cancelled = OSAllocatedUnfairLock(initialState: false)

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
    cancelled.withLock { $0 = true }
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
    guard !cancelled.withLock({ $0 }), let subscriber, demand > 0, let value = pending else {
      return
    }
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
