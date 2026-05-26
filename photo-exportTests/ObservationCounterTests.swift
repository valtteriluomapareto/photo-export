import Foundation
import Observation
import Testing

@testable import Photo_Export

@Observable
@MainActor
private final class ObservationCounterTestModel {
  var value: Int = 0
  var unrelated: String = ""
}

@MainActor
struct ObservationCounterTests {
  @Test func countsSequentialChangesByReRegistering() async throws {
    let model = ObservationCounterTestModel()
    let counter = ObservationCounter { [model] in _ = model.value }

    model.value = 1
    _ = try await counter.waitForNextChange()
    model.value = 2
    _ = try await counter.waitForNextChange()
    model.value = 3
    let final = try await counter.waitForNextChange()

    #expect(counter.changeCount == 3)
    #expect(final == 3)
  }

  @Test func waitForNextChangeTimesOutWhenNoMutationArrives() async throws {
    let model = ObservationCounterTestModel()
    let counter = ObservationCounter { [model] in _ = model.value }
    await #expect(throws: ObservationCounterTimeout.self) {
      _ = try await counter.waitForNextChange(timeout: .milliseconds(50))
    }
  }

  @Test func mutatingUntrackedPropertyDoesNotIncrement() async throws {
    let model = ObservationCounterTestModel()
    let counter = ObservationCounter { [model] in _ = model.value }
    model.unrelated = "ignored"
    // Wait the full timeout to prove no observer fired for the untracked write.
    await #expect(throws: ObservationCounterTimeout.self) {
      _ = try await counter.waitForNextChange(timeout: .milliseconds(100))
    }
    #expect(counter.changeCount == 0)
    model.value = 1
    _ = try await counter.waitForNextChange()
    #expect(counter.changeCount == 1)
  }
}
