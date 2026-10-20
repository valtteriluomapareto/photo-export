import Observation
import Testing

@testable import Photo_Export

private struct Opaque {
  var raw = 0
}

private final class Reference {}

@Observable
@MainActor
private final class EqualWriteModel {
  var number = 0
  var opaque = Opaque()
  var reference = Reference()
}

/// Characterizes whether Observation notifies on a write that stores a value equal to the one
/// already held, on the toolchain that builds the tests. The `@Observable` macro's behaviour
/// here has changed between toolchains, and a view that re-renders (or stops re-rendering) on
/// such writes depends on it, so a toolchain bump that changes it fails here first. The Combine
/// accessors are unaffected: `PublisherParityTests` pins that they deliver every write.
@MainActor
struct ObservationEqualWriteTests {
  @Test func equalEquatableWriteDoesNotNotify() {
    let model = EqualWriteModel()
    let probe = ObservationProbe { _ = model.number }
    model.number = model.number
    #expect(probe.changeCount == 0)
    model.number = 1
    #expect(probe.changeCount == 1)
  }

  @Test func identicalReferenceWriteDoesNotNotify() {
    let model = EqualWriteModel()
    let probe = ObservationProbe { _ = model.reference }
    model.reference = model.reference
    #expect(probe.changeCount == 0)
    model.reference = Reference()
    #expect(probe.changeCount == 1)
  }

  @Test func nonEquatableWriteAlwaysNotifies() {
    let model = EqualWriteModel()
    let probe = ObservationProbe { _ = model.opaque }
    model.opaque = model.opaque
    #expect(probe.changeCount == 1)
  }
}
