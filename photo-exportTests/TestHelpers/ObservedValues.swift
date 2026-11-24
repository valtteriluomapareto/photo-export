/// Records changed values without a Combine subscription or an asynchronous delivery hop.
/// Observation fires before storage changes, so each callback captures the previous committed
/// value. Reading `values` appends the current value to complete the sequence. Equal writes
/// stay silent, and the initial value is not a change.
@MainActor
final class ObservedValues<Value> {
  private let read: @MainActor () -> Value
  private var previous: [Value] = []
  private var probe: ObservationProbe?

  init(_ read: @escaping @MainActor () -> Value) {
    self.read = read
    probe = ObservationProbe(
      { _ = read() },
      onChange: { [weak self] in
        self?.previous.append(read())
      })
  }

  var values: [Value] {
    previous.isEmpty ? [] : Array(previous.dropFirst()) + [read()]
  }
}
