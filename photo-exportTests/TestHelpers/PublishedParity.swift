import Combine
import Testing

/// A write that stores the value the property already holds, made through the type's real
/// mutation paths.
enum UnchangedWrite {
  /// Made before `change`, against the starting value.
  case before(@MainActor () -> Void)
  /// Made after `change`, against the changed value.
  case after(@MainActor () -> Void)
  /// No real mutation path writes an unchanged value; the reason says why.
  case notDrivable(String)
}

/// What a subscriber sees for an `UnchangedWrite`.
enum UnchangedWriteDelivery {
  /// The value is delivered again, as `$property` does.
  case emits
  /// Nothing is delivered: the accessor drops repeats (`removeDuplicates`).
  case isDropped
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
/// - **Unchanged writes:** a write of the current value is delivered again, or dropped when
///   the accessor removes repeats.
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
  #expect(received == [start], "a new subscriber receives the current value synchronously",
    sourceLocation: sourceLocation)

  func checkUnchangedWrite(_ write: @MainActor () -> Void) {
    let current = value()
    let before = received.count
    write()
    #expect(value() == current, "the unchanged write must not change the value",
      sourceLocation: sourceLocation)
    switch unchangedWriteDelivery {
    case .emits:
      #expect(received.count == before + 1, "a write of the current value is delivered again",
        sourceLocation: sourceLocation)
      #expect(received.last == current, sourceLocation: sourceLocation)
    case .isDropped:
      #expect(received.count == before, "the accessor drops a repeated value",
        sourceLocation: sourceLocation)
    }
  }

  if case .before(let write) = unchangedWrite { checkUnchangedWrite(write) }

  let first = received.count
  firstChangeDelivery = first
  await change()
  #expect(received.count > first, "change produced no delivery before it returned",
    sourceLocation: sourceLocation)
  #expect(received.last == value(), "the last delivery is the stored value",
    sourceLocation: sourceLocation)
  if received.count > first {
    let stored = received[first - 1]
    #expect(
      nestedAtSubscribe == [stored],
      "a subscription made during a delivery replays the stored (previous) value",
      sourceLocation: sourceLocation)
    #expect(
      nested == [stored] + received[(first + 1)...],
      "a subscription made during a delivery misses that delivery but gets every later one",
      sourceLocation: sourceLocation)
  }
  nestedSubscription?.cancel()

  if case .after(let write) = unchangedWrite { checkUnchangedWrite(write) }

  for index in received.indices.dropFirst() {
    #expect(
      readDuringDelivery[index] == received[index - 1],
      "delivery \(index) arrived after the value was stored",
      sourceLocation: sourceLocation)
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
  sourceLocation: SourceLocation = #_sourceLocation
) async {
  await assertPublishedParity(
    { publisher(object) }, value: { object[keyPath: keyPath] }, change: change,
    unchangedWrite: unchangedWrite, sourceLocation: sourceLocation)
}
