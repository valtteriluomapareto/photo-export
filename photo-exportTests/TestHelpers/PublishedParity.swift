import Combine
import Testing

/// A write that leaves the published value as it is, made through the type's real mutation
/// paths: a write of the value already held, or a call that a production guard turns into no
/// write at all.
enum UnchangedWrite {
  /// Made before `change`, against the starting value.
  case before(@MainActor () async -> Void)
  /// Made after `change`, against the changed value.
  case after(@MainActor () async -> Void)
  /// No real mutation path leaves the value unchanged; the reason says why.
  case notDrivable(String)
}

/// What a subscriber sees for an `UnchangedWrite`.
enum UnchangedWriteDelivery {
  /// The value is delivered again, as `$property` does for a write of the same value.
  case emits
  /// Nothing is delivered: the accessor drops repeats (`removeDuplicates`), or the mutation
  /// path skips an equal write (an `if value != new` guard).
  case isDropped
}

/// The checks `assertPublishedParity` makes. Each failure's comment starts with the raw value,
/// so a test can tell which one fired.
enum ParityCheck: String, CaseIterable {
  case replay = "Replay broke: a new subscriber must receive the current value synchronously"
  case unchangedValue = "The unchanged write changed the value"
  case unchangedEmits =
    "Unchanged-write delivery broke: a write of the current value must be delivered again"
  case unchangedDropped =
    "Unchanged-write delivery broke: a write of the current value must not be delivered"
  case synchronous =
    "Synchronous delivery broke: `change` returned before any value was delivered"
  case lastIsStored = "The last delivered value is not the stored value"
  case storedAfterDelivery =
    "Delivery order broke: a sink reading the property must still see the previously delivered value (deliver, then store)"
  case nestedReplay =
    "Nested subscription broke: a subscription made inside a sink must replay the stored (previous) value; replay from the stored value, not CurrentValueSubject.value"
  case nestedLater =
    "Nested subscription broke: a subscription made inside a sink must miss the delivery in flight and receive every later one"
  case resubscribe =
    "Resubscription broke: a new subscription to the same publisher instance must replay the current value, not the value when the publisher was made"
  case writeDuringReplay =
    "Write during replay broke: a write made while a subscriber receives its replayed value must reach that subscriber"
  case reentrantWrite =
    "Re-entrant write broke: a write made inside a sink must be delivered inside the outer delivery, and the outer write's value must end up stored"
  case limitedDemand =
    "Limited demand broke: a subscriber without demand must receive the latest value once demand arrives"
  case writeDuringLimitedReplay =
    "Write during a limited replay broke: a write made while a subscriber with no further demand receives its replay must arrive once, in order, when it asks"
  case demandFromReceive =
    "Demand returned from receive broke: a value kept while the subscriber had no demand must give way to a newer write and never arrive after it"
  case demandWithoutPending =
    "Demand without a pending value broke: one unit of demand must take exactly the next write"
  case steadyDemand =
    "Steady demand broke: a subscriber that asks for one more with every value must receive every write"
}

/// Pins the delivery semantics a named publisher accessor has today, so a later change to the
/// property's storage cannot change what its subscribers see:
///
/// - **Replay:** a new subscriber receives the current value synchronously.
/// - **Synchronous delivery, before the store:** every value `change` produces is delivered
///   before `change` returns, and a sink that reads the value while a delivery is in progress
///   still sees the previously delivered value (the `@Published` willSet order).
/// - **Nested subscription:** a subscription made inside the sink, during the first delivery
///   `change` produces, synchronously receives the stored (previous) value, misses the delivery
///   in flight and receives every later one.
/// - **Unchanged writes:** a write that leaves the value as it is is delivered again, or not
///   delivered when the accessor removes repeats or the mutation path skips equal writes.
/// - **Resubscription:** a new subscription to the same publisher instance, made after `change`,
///   replays the current value. This proves nothing when `change` ends on the value it started
///   from (a run context set and cleared); `ObservableCombineBridgeTests` pins it for the bridge.
///
/// `value` reads what the accessor publishes from the object's current state: the property
/// itself, or for a derived accessor the same combination of properties.
@MainActor
func assertPublishedParity<Value: Equatable>(
  _ publisher: @MainActor () -> AnyPublisher<Value, Never>,
  value: @escaping @MainActor () -> Value,
  change: @MainActor () async -> Void,
  unchangedWrite: UnchangedWrite,
  unchangedWriteDelivery: UnchangedWriteDelivery = .emits,
  sourceLocation: SourceLocation = #_sourceLocation
) async {
  func check(_ condition: Bool, _ failure: ParityCheck, _ detail: String = "") {
    #expect(
      condition, Comment(rawValue: failure.rawValue + detail), sourceLocation: sourceLocation)
  }
  var received: [Value] = []
  var readDuringDelivery: [Value] = []
  // The subscription made during the first delivery `change` produces: what it received while
  // subscribing, and everything it received.
  var nestedAtSubscribe: [Value]?
  var nested: [Value] = []
  var nestedSubscription: AnyCancellable?
  var firstChangeDelivery: Int?
  let source = publisher()
  let subscription = source.sink { delivered in
    received.append(delivered)
    readDuringDelivery.append(value())
    if received.count - 1 == firstChangeDelivery, nestedSubscription == nil {
      nestedSubscription = source.sink { nested.append($0) }
      nestedAtSubscribe = nested
    }
  }
  defer { subscription.cancel() }

  let start = value()
  check(received == [start], .replay, " (received \(received), current \(start))")

  func checkUnchangedWrite(_ write: @MainActor () async -> Void) async {
    let current = value()
    let before = received.count
    await write()
    check(value() == current, .unchangedValue)
    switch unchangedWriteDelivery {
    case .emits:
      check(
        received.count == before + 1 && received.last == current, .unchangedEmits,
        " (\(received.count - before) deliveries)")
    case .isDropped:
      check(received.count == before, .unchangedDropped, " (\(received.count - before) deliveries)")
    }
  }

  if case .before(let write) = unchangedWrite { await checkUnchangedWrite(write) }

  let first = received.count
  firstChangeDelivery = first
  await change()
  check(received.count > first, .synchronous)
  check(received.last == value(), .lastIsStored)
  if received.count > first, first > 0 {
    let stored = received[first - 1]
    check(nestedAtSubscribe == [stored], .nestedReplay, " (got \(nestedAtSubscribe ?? []))")
    check(nested == [stored] + received[(first + 1)...], .nestedLater, " (got \(nested))")
  }
  nestedSubscription?.cancel()

  var resubscribed: [Value] = []
  source.sink { resubscribed.append($0) }.cancel()
  check(
    resubscribed.first == value(), .resubscribe,
    " (got \(resubscribed), current \(value()))")

  if case .after(let write) = unchangedWrite { await checkUnchangedWrite(write) }

  for index in received.indices.dropFirst() {
    check(
      readDuringDelivery[index] == received[index - 1], .storedAfterDelivery,
      " (delivery \(index))")
  }
}

/// `assertPublishedParity` for an accessor that publishes one stored property.
@MainActor
func assertPublishedParity<Object: AnyObject, Value: Equatable>(
  _ object: Object,
  _ keyPath: KeyPath<Object, Value>,
  _ publisher: @MainActor (Object) -> AnyPublisher<Value, Never>,
  change: @MainActor () async -> Void,
  unchangedWrite: UnchangedWrite,
  unchangedWriteDelivery: UnchangedWriteDelivery = .emits,
  sourceLocation: SourceLocation = #_sourceLocation
) async {
  await assertPublishedParity(
    { publisher(object) }, value: { object[keyPath: keyPath] }, change: change,
    unchangedWrite: unchangedWrite, unchangedWriteDelivery: unchangedWriteDelivery,
    sourceLocation: sourceLocation)
}

/// A fresh publisher with two synchronous writes, each storing a value different from the one
/// before it, for `assertSubscriberEdgeParity`.
struct EdgeSubject<Value> {
  let publisher: AnyPublisher<Value, Never>
  let value: @MainActor () -> Value
  let first: @MainActor () -> Void
  let second: @MainActor () -> Void
}

/// Requests `initial` demand on subscription, then more only when asked or when `onReceive`
/// returns it. `onReceive` gets the index of each value and may write to the publisher's owner.
final class DemandRecorder<Value>: Subscriber {
  private(set) var received: [Value] = []
  private(set) var subscription: (any Subscription)?
  private let initial: Subscribers.Demand
  private let onReceive: @MainActor (Int) -> Subscribers.Demand

  init(
    initial: Subscribers.Demand = .max(1),
    onReceive: @escaping @MainActor (Int) -> Subscribers.Demand = { _ in .none }
  ) {
    self.initial = initial
    self.onReceive = onReceive
  }

  func receive(subscription: any Subscription) {
    self.subscription = subscription
    subscription.request(initial)
  }

  func receive(_ input: Value) -> Subscribers.Demand {
    received.append(input)
    let index = received.count - 1
    return MainActor.assumeIsolated { onReceive(index) }
  }

  func receive(completion: Subscribers.Completion<Never>) {}

  func request(_ demand: Subscribers.Demand) { subscription?.request(demand) }
  func cancel() { subscription?.cancel() }
}

/// Pins how a publisher treats subscribers that write back or limit demand, as `@Published`
/// does. These need synchronous writes, which not every accessor's real mutation path has, so
/// they are separate from `assertPublishedParity` and run on a fresh subject each:
///
/// - **Write during replay:** a sink that writes while it receives its replayed value receives
///   that write.
/// - **Re-entrant write:** a sink that writes while it receives a delivery receives the inner
///   write at once; the outer write stores last, so the stored value is the outer one, not the
///   last delivered.
/// - **Limited demand:** a subscriber without outstanding demand receives the latest value, and
///   only that, once it requests more.
/// - **Write during a limited replay:** a subscriber with demand for its replay only, writing
///   while it receives it, gets that write when it next asks, then later writes in order.
/// - **Demand returned from `receive`:** demand a subscriber returns while a value is kept for
///   it does not deliver the kept value; the next write replaces it, and it never arrives late.
/// - **Demand without a pending value:** one unit of demand takes the next write only.
/// - **Steady demand:** a subscriber returning one more with each value receives every write.
@MainActor
func assertSubscriberEdgeParity<Value: Equatable>(
  _ make: @MainActor () -> EdgeSubject<Value>,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  func check(_ condition: Bool, _ failure: ParityCheck, _ detail: String) {
    #expect(
      condition, Comment(rawValue: failure.rawValue + detail), sourceLocation: sourceLocation)
  }

  let replaying = make()
  let replayStart = replaying.value()
  var replayed: [Value] = []
  replaying.publisher.sink { delivered in
    replayed.append(delivered)
    if replayed.count == 1 { replaying.first() }
  }.cancel()
  check(
    replayed == [replayStart, replaying.value()], .writeDuringReplay,
    " (received \(replayed), stored \(replaying.value()))")

  let reentrant = make()
  let reentrantStart = reentrant.value()
  var delivered: [Value] = []
  let subscription = reentrant.publisher.sink { value in
    delivered.append(value)
    if delivered.count == 2 { reentrant.second() }
  }
  reentrant.first()
  subscription.cancel()
  let stored = reentrant.value()
  check(
    delivered.count == 3 && delivered[0] == reentrantStart && delivered[1] == stored
      && delivered[2] != stored, .reentrantWrite,
    " (received \(delivered), stored \(stored))")

  let limited = make()
  let limitedStart = limited.value()
  let recorder = DemandRecorder<Value>()
  limited.publisher.subscribe(recorder)
  limited.first()
  let limitedFirst = limited.value()
  limited.second()
  recorder.request(.max(1))
  recorder.cancel()
  check(
    limitedFirst != limitedStart && limited.value() != limitedFirst
      && recorder.received == [limitedStart, limited.value()], .limitedDemand,
    " (received \(recorder.received), writes \([limitedStart, limitedFirst, limited.value()]))")

  let limitedReplay = make()
  let limitedReplayStart = limitedReplay.value()
  let replayWriter = DemandRecorder<Value> { index in
    if index == 0 { limitedReplay.first() }
    return .none
  }
  limitedReplay.publisher.subscribe(replayWriter)
  let replayWrite = limitedReplay.value()
  replayWriter.request(.max(1))
  limitedReplay.second()
  replayWriter.request(.max(1))
  replayWriter.cancel()
  check(
    replayWriter.received == [limitedReplayStart, replayWrite, limitedReplay.value()],
    .writeDuringLimitedReplay, " (received \(replayWriter.received))")

  let returned = make()
  let returnedStart = returned.value()
  let demandReturner = DemandRecorder<Value> { index in
    guard index == 0 else { return .none }
    returned.first()
    return .max(1)
  }
  returned.publisher.subscribe(demandReturner)
  let afterSubscribe = demandReturner.received
  returned.second()
  demandReturner.request(.max(1))
  demandReturner.cancel()
  check(
    afterSubscribe == [returnedStart]
      && demandReturner.received == [returnedStart, returned.value()],
    .demandFromReceive,
    " (received \(afterSubscribe) after subscribing, \(demandReturner.received) in all)")

  let idle = make()
  let idleStart = idle.value()
  let idleRecorder = DemandRecorder<Value>()
  idle.publisher.subscribe(idleRecorder)
  idleRecorder.request(.max(1))
  idle.first()
  let idleFirst = idle.value()
  idle.second()
  let beforeRequest = idleRecorder.received
  idleRecorder.request(.max(1))
  idleRecorder.cancel()
  check(
    beforeRequest == [idleStart, idleFirst]
      && idleRecorder.received == [idleStart, idleFirst, idle.value()], .demandWithoutPending,
    " (received \(beforeRequest) before asking again, \(idleRecorder.received) in all)")

  let steady = make()
  let steadyStart = steady.value()
  let steadyRecorder = DemandRecorder<Value> { _ in .max(1) }
  steady.publisher.subscribe(steadyRecorder)
  steady.first()
  let steadyFirst = steady.value()
  steady.second()
  steadyRecorder.cancel()
  check(
    steadyRecorder.received == [steadyStart, steadyFirst, steady.value()], .steadyDemand,
    " (received \(steadyRecorder.received))")
}
