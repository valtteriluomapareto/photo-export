import Foundation
import Testing

/// Deliberately ungated: CI must fail when the existing destination tests would skip.
struct RequiredDestinationScopeTests {
  @Test func requiredDestinationScopeTestsCanRun() {
    guard ProcessInfo.processInfo.environment["REQUIRE_SCOPE_TESTS"] == "1" else { return }
    #expect(
      !BareTmpScopeProbe.bareTmpRejectsScopeStart(),
      "CI requires the destination-identity tests: bare temporary-folder scope access failed, so 19 regression tests would skip. Check the runner environment before merging."
    )
  }
}
