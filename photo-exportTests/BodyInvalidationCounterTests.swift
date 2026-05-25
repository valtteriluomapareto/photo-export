import SwiftUI
import Testing

@testable import Photo_Export

#if DEBUG
@MainActor
@Suite(.serialized)
struct BodyInvalidationCounterTests {
  init() {
    BodyInvalidationCounter.shared.reset()
  }

  @Test func recordIncrementsPerCall() {
    #expect(BodyInvalidationCounter.shared.count(for: "X") == 0)
    BodyInvalidationCounter.shared.record("X")
    BodyInvalidationCounter.shared.record("X")
    BodyInvalidationCounter.shared.record("Y")
    #expect(BodyInvalidationCounter.shared.count(for: "X") == 2)
    #expect(BodyInvalidationCounter.shared.count(for: "Y") == 1)
  }

  @Test func resetClearsAllCounts() {
    BodyInvalidationCounter.shared.record("X")
    BodyInvalidationCounter.shared.reset()
    #expect(BodyInvalidationCounter.shared.count(for: "X") == 0)
    #expect(BodyInvalidationCounter.shared.snapshot().isEmpty)
  }

  @Test func measureBodyInvalidationsModifierRecords() {
    _ = Text("Hello").measureBodyInvalidations("TestView")
    #expect(BodyInvalidationCounter.shared.count(for: "TestView") == 1)
    _ = Text("Hello").measureBodyInvalidations("TestView")
    #expect(BodyInvalidationCounter.shared.count(for: "TestView") == 2)
  }
}
#endif
