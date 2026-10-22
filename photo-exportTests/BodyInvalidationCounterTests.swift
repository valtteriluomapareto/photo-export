import Testing

@testable import Photo_Export

#if DEBUG
  @MainActor
  @Suite(.serialized, .timeLimit(.minutes(1)))
  struct BodyInvalidationCounterTests {
    @Test func recordIncrementsPerCall() {
      let counter = BodyInvalidationCounter()
      #expect(counter.count(for: "X") == 0)
      counter.record("X")
      counter.record("X")
      counter.record("Y")
      #expect(counter.count(for: "X") == 2)
      #expect(counter.count(for: "Y") == 1)
    }

    @Test func resetClearsAllCounts() {
      let counter = BodyInvalidationCounter()
      counter.record("X")
      counter.reset()
      #expect(counter.count(for: "X") == 0)
      #expect(counter.snapshot().isEmpty)
    }
  }
#endif
