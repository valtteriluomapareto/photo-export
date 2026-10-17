import Testing

// Temporary #237 CI evidence. Removed before the merge candidate.
struct CIFailureDiagnosticProofTests {
  @Test func earlyExpectationIsVisibleInJobLog() {
    let actual = 1
    #expect(actual == 2, "CI_EXPECT_DIAGNOSTIC_237_EARLY_FAILURE_PROOF")
  }
}
