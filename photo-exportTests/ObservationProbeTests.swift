import Observation
import Testing

@testable import Photo_Export

@Observable
@MainActor
private final class ObservationProbeModel {
  var value = 0
  var other = 0
  @ObservationIgnored var ignored = 0
}

@MainActor
struct ObservationProbeTests {
  @Test func countsAChangeBeforeTheSetterReturns() {
    let model = ObservationProbeModel()
    let probe = ObservationProbe { _ = model.value }
    #expect(probe.changeCount == 0)
    model.value = 1
    #expect(probe.changeCount == 1)
  }

  @Test func reRegistersSoEveryChangeCounts() {
    let model = ObservationProbeModel()
    let probe = ObservationProbe { _ = model.value }
    for next in 1...3 { model.value = next }
    #expect(probe.changeCount == 3)
  }

  @Test func countsEachReadPropertyAndOnlyThose() {
    let model = ObservationProbeModel()
    let valueOnly = ObservationProbe { _ = model.value }
    let both = ObservationProbe {
      _ = model.value
      _ = model.other
    }
    model.other = 1
    model.value = 1
    #expect(valueOnly.changeCount == 1)
    #expect(both.changeCount == 2)
  }

  @Test func ignoredPropertiesDoNotCount() {
    let model = ObservationProbeModel()
    let probe = ObservationProbe { _ = model.ignored }
    model.ignored = 1
    #expect(probe.changeCount == 0)
  }

  @Test func stopEndsCounting() {
    let model = ObservationProbeModel()
    let probe = ObservationProbe { _ = model.value }
    model.value = 1
    probe.stop()
    model.value = 2
    model.value = 3
    #expect(probe.changeCount == 1)
  }
}
