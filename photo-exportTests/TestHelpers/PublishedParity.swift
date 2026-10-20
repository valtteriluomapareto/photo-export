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
