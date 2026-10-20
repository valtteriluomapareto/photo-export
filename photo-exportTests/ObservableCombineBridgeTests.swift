import Combine
import Observation
import Testing

@testable import Photo_Export

/// A property stored in an `ObservableCombineBridge`, as both owner shapes declare it.
@MainActor
private protocol BridgedCount: AnyObject {
  var count: Int { get set }
  var countPublisher: AnyPublisher<Int, Never> { get }
}

/// The owner while it is still `ObservableObject`: its own registrar, and `objectWillChange`
/// sent before the bridge delivers.
@MainActor
private final class PlumbedOwner: ObservableObject, Observable, BridgedCount {
  private let registrar = ObservationRegistrar()
  private let countStorage = ObservableCombineBridge(0)

  var count: Int {
    get {
      registrar.access(self, keyPath: \.count)
      return countStorage.value
    }
    set {
      objectWillChange.send()
      countStorage.write(newValue) { registrar.withMutation(of: self, keyPath: \.count, $0) }
    }
  }

  var countPublisher: AnyPublisher<Int, Never> { countStorage.publisher }
}

/// The owner after the flip: the macro's registrar, no `objectWillChange`.
@Observable
@MainActor
private final class FlippedOwner: BridgedCount {
  var label = ""
  private let countStorage = ObservableCombineBridge(0)

  var count: Int {
    get {
      access(keyPath: \.count)
      return countStorage.value
    }
    set { countStorage.write(newValue) { withMutation(keyPath: \.count, $0) } }
  }

  var countPublisher: AnyPublisher<Int, Never> { countStorage.publisher }
}

/// The bridge contract: the Combine side delivers exactly as `@Published` does, and the
/// Observation side notifies as the `@Observable` macro does, for both owner shapes.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ObservableCombineBridgeTests {
  enum Shape: CaseIterable { case plumbed, flipped }

  private static func owner(_ shape: Shape) -> any BridgedCount {
    switch shape {
    case .plumbed: PlumbedOwner()
    case .flipped: FlippedOwner()
    }
  }

  /// Replay, synchronous delivery before the store, nested subscription and unchanged-write
  /// delivery, checked by the same helper `PublisherParityTests` uses on every accessor.
  @Test(arguments: Shape.allCases)
  func deliversAsPublished(_ shape: Shape) async {
    let owner = Self.owner(shape)
    await assertPublishedParity(
      { owner.countPublisher }, value: { owner.count },
      change: {
        owner.count = 1
        owner.count = 2
      },
      unchangedWrite: .before { owner.count = owner.count })
  }

  /// Observation's willSet runs before subscribers receive the value, as SwiftUI's own
  /// invalidation does for `@Published`.
  @Test(arguments: Shape.allCases)
  func observationIsNotifiedBeforeDelivery(_ shape: Shape) {
    let owner = Self.owner(shape)
    let probe = ObservationProbe { _ = owner.count }
    var notifiedAtDelivery: [Int] = []
    let subscription = owner.countPublisher.sink { _ in
      notifiedAtDelivery.append(probe.changeCount)
    }
    defer { subscription.cancel() }
    owner.count = 1
    owner.count = 2
    #expect(notifiedAtDelivery == [0, 1, 2])
  }

  /// An equal write is delivered to subscribers but does not notify Observation, matching
  /// `ObservationEqualWriteTests.equalEquatableWriteDoesNotNotify` for a macro property.
  @Test(arguments: Shape.allCases)
  func equalWriteIsDeliveredWithoutNotifyingObservation(_ shape: Shape) {
    let owner = Self.owner(shape)
    let probe = ObservationProbe { _ = owner.count }
    var received: [Int] = []
    let subscription = owner.countPublisher.sink { received.append($0) }
    defer { subscription.cancel() }
    owner.count = owner.count
    #expect(received == [0, 0])
    #expect(probe.changeCount == 0)
    owner.count = 1
    #expect(received == [0, 0, 1])
    #expect(probe.changeCount == 1)
  }

  /// A bridged property and a macro property each notify only their own readers.
  @Test func observationTracksTheReadPropertyOnly() {
    let owner = FlippedOwner()
    let labelReader = ObservationProbe { _ = owner.label }
    let countReader = ObservationProbe { _ = owner.count }
    owner.count = 1
    #expect(countReader.changeCount == 1)
    #expect(labelReader.changeCount == 0)
    owner.label = "changed"
    #expect(countReader.changeCount == 1)
    #expect(labelReader.changeCount == 1)
  }

  /// While the owner is still `ObservableObject`, every write sends `objectWillChange` first,
  /// an equal write included, as `@Published` does.
  @Test func plumbedOwnerSendsObjectWillChangeBeforeEveryDelivery() {
    let owner = PlumbedOwner()
    var events: [String] = []
    let will = owner.objectWillChange.sink { events.append("will") }
    let values = owner.countPublisher.sink { events.append("value \($0)") }
    defer {
      will.cancel()
      values.cancel()
    }
    owner.count = 1
    owner.count = 1
    #expect(events == ["value 0", "will", "value 1", "will", "value 1"])
  }

  /// The bridge delivers in the writer's call stack; nothing is queued for later.
  @Test func deliveryHappensBeforeTheWriteReturns() {
    let owner = FlippedOwner()
    var received: [Int] = []
    let subscription = owner.countPublisher.sink { received.append($0) }
    defer { subscription.cancel() }
    owner.count = 1
    #expect(received == [0, 1])
    #expect(owner.count == 1)
  }
}
