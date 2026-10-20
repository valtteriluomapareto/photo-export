import Combine
import Observation
import Testing

@testable import Photo_Export

/// A property written the way an `@Observable` owner writes a bridged property.
@Observable
@MainActor
private final class BridgedModel {
  @ObservationIgnored private let bridge = ObservableCombineBridge(0)
  var value: Int {
    get {
      access(keyPath: \.value)
      return bridge.value
    }
    set {
      guard bridge.needsNotification(for: newValue) else { return bridge.send(newValue) }
      withMutation(keyPath: \.value) { bridge.send(newValue) }
    }
  }
  var publisher: AnyPublisher<Int, Never> { bridge.publisher }

  var events: [String] = []
}

/// The bridge's delivery contract: what `@Published` delivers to Combine subscribers, with an
/// Observation notification in the willSet position.
@MainActor
struct ObservableCombineBridgeTests {
  @Test func matchesPublishedParity() async {
    let model = BridgedModel()
    await assertPublishedParity(
      model, \.value, { $0.publisher },
      change: { model.value = 1 },
      unchangedWrite: .before { model.value = model.value })
  }

  @Test func aReadInsideTheSinkReturnsThePreviousValue() {
    let model = BridgedModel()
    var reads: [Int] = []
    let subscription = model.publisher.sink { _ in reads.append(model.value) }
    model.value = 1
    model.value = 2
    #expect(reads == [0, 0, 1])
    #expect(model.value == 2)
    subscription.cancel()
  }

  @Test func aSubscriptionInsideTheSinkReplaysTheStoredValueAndMissesTheDeliveryInFlight() {
    let model = BridgedModel()
    var nested: [Int] = []
    var nestedSubscription: AnyCancellable?
    let subscription = model.publisher.dropFirst().sink { _ in
      guard nestedSubscription == nil else { return }
      nestedSubscription = model.publisher.sink { nested.append($0) }
    }
    model.value = 1
    #expect(nested == [0])
    model.value = 2
    #expect(nested == [0, 2])
    subscription.cancel()
    nestedSubscription?.cancel()
  }

  @Test func observationIsNotifiedBeforeTheCombineSend() {
    let model = BridgedModel()
    var order: [String] = []
    withObservationTracking {
      _ = model.value
    } onChange: {
      MainActor.assumeIsolated { order.append("willSet") }
    }
    let subscription = model.publisher.dropFirst().sink { _ in order.append("send") }
    model.value = 1
    #expect(order == ["willSet", "send"])
    subscription.cancel()
  }

  @Test func deliveryIsSynchronous() {
    let model = BridgedModel()
    var received: [Int] = []
    let subscription = model.publisher.sink { received.append($0) }
    #expect(received == [0])
    model.value = 1
    #expect(received == [0, 1])
    subscription.cancel()
  }

  @Test func anUnchangedWriteIsDeliveredButDoesNotNotifyObservation() {
    let model = BridgedModel()
    let probe = ObservationProbe { _ = model.value }
    var received: [Int] = []
    let subscription = model.publisher.sink { received.append($0) }
    model.value = 0
    #expect(received == [0, 0])
    #expect(probe.changeCount == 0)
    model.value = 1
    #expect(received == [0, 0, 1])
    #expect(probe.changeCount == 1)
    subscription.cancel()
  }

  @Test func observationTracksOnlyTheBridgedProperty() {
    let model = BridgedModel()
    let probe = ObservationProbe { _ = model.value }
    model.events.append("unrelated")
    #expect(probe.changeCount == 0)
    model.value = 1
    model.value = 2
    #expect(probe.changeCount == 2)
  }
}
