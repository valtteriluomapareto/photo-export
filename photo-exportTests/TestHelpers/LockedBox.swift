import Foundation

/// A value shared with `@Sendable` closures in a test, guarded by a lock.
final class LockedBox<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var _value: Value

  init(_ value: Value) { _value = value }

  var value: Value { lock.withLock { _value } }

  func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&_value) } }
}
