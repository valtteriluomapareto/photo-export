import Observation
import XCTest

@testable import Photo_Export

@Observable
@MainActor
private final class ObservationCounterTestModel {
  var value: Int = 0
  var unrelated: String = ""
}

@MainActor
final class ObservationCounterTests: XCTestCase {
  private typealias Model = ObservationCounterTestModel

  func testCountsSequentialChangesByReRegistering() async {
    let model = Model()
    let counter = ObservationCounter { [model] in _ = model.value }

    model.value = 1
    _ = await counter.waitForNextChange()
    model.value = 2
    _ = await counter.waitForNextChange()
    model.value = 3
    let final = await counter.waitForNextChange()

    XCTAssertEqual(counter.changeCount, 3)
    XCTAssertEqual(final, 3)
  }

  func testIgnoresMutationsToUntrackedProperties() async {
    let model = Model()
    let counter = ObservationCounter { [model] in _ = model.value }

    model.unrelated = "ignored"
    // Give any (incorrect) re-registration a chance to fire. A tiny yield
    // is enough — ObservationCounter increments inside a Task on the main
    // queue, so anything pending would have landed by now.
    await Task.yield()
    XCTAssertEqual(counter.changeCount, 0)

    model.value = 1
    _ = await counter.waitForNextChange()
    XCTAssertEqual(counter.changeCount, 1)
  }

  func testStopFreezesCounterAfterNextChange() async {
    let model = Model()
    let counter = ObservationCounter { [model] in _ = model.value }

    counter.stop()
    model.value = 1
    _ = await counter.waitForNextChange()
    XCTAssertEqual(counter.changeCount, 1)

    // After stop(), the counter does not re-register, so further mutations
    // produce no additional change events.
    model.value = 2
    await Task.yield()
    XCTAssertEqual(counter.changeCount, 1)
  }

  func testResetReturnsCountToZeroWithoutAffectingObservation() async {
    let model = Model()
    let counter = ObservationCounter { [model] in _ = model.value }

    model.value = 1
    _ = await counter.waitForNextChange()
    counter.reset()
    XCTAssertEqual(counter.changeCount, 0)

    model.value = 2
    _ = await counter.waitForNextChange()
    XCTAssertEqual(counter.changeCount, 1)
  }
}
