import SwiftUI
import XCTest

@testable import Photo_Export

#if DEBUG
@MainActor
final class BodyInvalidationCounterTests: XCTestCase {
  override func setUp() async throws {
    try await super.setUp()
    BodyInvalidationCounter.shared.reset()
  }

  func testRecordIncrementsPerCall() {
    XCTAssertEqual(BodyInvalidationCounter.shared.count(for: "X"), 0)
    BodyInvalidationCounter.shared.record("X")
    BodyInvalidationCounter.shared.record("X")
    BodyInvalidationCounter.shared.record("Y")
    XCTAssertEqual(BodyInvalidationCounter.shared.count(for: "X"), 2)
    XCTAssertEqual(BodyInvalidationCounter.shared.count(for: "Y"), 1)
  }

  func testResetClearsAllCounts() {
    BodyInvalidationCounter.shared.record("X")
    BodyInvalidationCounter.shared.reset()
    XCTAssertEqual(BodyInvalidationCounter.shared.count(for: "X"), 0)
    XCTAssertTrue(BodyInvalidationCounter.shared.snapshot().isEmpty)
  }

  func testMeasureBodyInvalidationsModifierRecords() {
    let view = Text("Hello")
      .measureBodyInvalidations("TestView")
    // The modifier records on construction; consuming a `_ = view` reference
    // is enough — SwiftUI evaluates body by constructing the View value.
    _ = view
    XCTAssertEqual(BodyInvalidationCounter.shared.count(for: "TestView"), 1)
    _ = Text("Hello").measureBodyInvalidations("TestView")
    XCTAssertEqual(BodyInvalidationCounter.shared.count(for: "TestView"), 2)
  }
}
#endif
