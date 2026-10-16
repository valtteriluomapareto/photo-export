import Testing

@testable import Photo_Export

struct ThumbnailPreheatRegistrationsTests {
  @Test func overlappingConsumersOnlyStopTheirFinalRegistrations() {
    var registrations = ThumbnailPreheatRegistrations<String>()
    #expect(registrations.register(["A", "B"], resolve: { $0 }) == ["A", "B"])
    #expect(registrations.register(["B", "C"], resolve: { $0 }) == ["C"])
    #expect(registrations.release(["A", "B"]) == ["A"])
    #expect(registrations.release(["B", "C"]) == ["B", "C"])
    #expect(registrations.register(["A", "B", "C"], resolve: { $0 }) == ["A", "B", "C"])
    #expect(registrations.release(["A", "B", "C"]) == ["A", "B", "C"])
  }

  @Test func duplicateIdsWithinEachBatchOnlyCountOnce() {
    var registrations = ThumbnailPreheatRegistrations<String>()
    #expect(registrations.register(["A", "A", "B"], resolve: { $0 }) == ["A", "B"])
    #expect(registrations.register(["A", "A"], resolve: { $0 }) == [])
    #expect(registrations.release(["A", "A", "missing"]) == [])
    #expect(registrations.release(["A", "B", "B"]) == ["A", "B"])
    #expect(registrations.release(["A", "B"]) == [])
  }

  @Test func unresolvedRegistrationCannotConsumeAnotherConsumersResource() {
    var registrations = ThumbnailPreheatRegistrations<String>()
    #expect(registrations.register(["A"], resolve: { _ in nil }) == [])
    #expect(registrations.register(["A"], resolve: { _ in "resolved-A" }) == ["resolved-A"])
    #expect(registrations.release(["A"]) == [])
    #expect(registrations.release(["A"]) == ["resolved-A"])
  }

  @Test func finalReleaseUsesRetainedResourceAfterResolverIsInvalidated() {
    var registrations = ThumbnailPreheatRegistrations<String>()
    var resources = ["A": "original-A"]
    #expect(registrations.register(["A"], resolve: { resources[$0] }) == ["original-A"])
    resources.removeAll()
    #expect(registrations.register(["A", "B"], resolve: { resources[$0] }) == [])
    #expect(registrations.release(["A"]) == [])
    #expect(registrations.release(["A", "B"]) == ["original-A"])
    resources["A"] = "replacement-A"
    #expect(registrations.register(["A"], resolve: { resources[$0] }) == ["replacement-A"])
    #expect(registrations.release(["A"]) == ["replacement-A"])
  }
}
