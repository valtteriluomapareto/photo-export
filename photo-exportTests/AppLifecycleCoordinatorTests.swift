import Combine
import Foundation
import Testing

@testable import Photo_Export

/// Phase 0a (auto-sync plan): bootstrap and destination-change handling now live in
/// `AppLifecycleCoordinator`. Same-fingerprint destination assignments must NOT call
/// `cancelAndClear()` or reconfigure the record stores; only true id changes do.
@MainActor
struct AppLifecycleCoordinatorTests {

  private struct Spy {
    var cancelCount = 0
    var configureCalls: [String?] = []
  }

  private func makeCoordinator() -> (AppLifecycleCoordinator, () -> Spy) {
    var spy = Spy()
    let coordinator = AppLifecycleCoordinator(
      cancelActiveWork: { spy.cancelCount += 1 },
      configureRecordStores: { spy.configureCalls.append($0) }
    )
    return (coordinator, { spy })
  }

  @Test func sameIdAssignmentIsANoOp() {
    var spy = Spy()
    let coordinator = AppLifecycleCoordinator(
      cancelActiveWork: { spy.cancelCount += 1 },
      configureRecordStores: { spy.configureCalls.append($0) }
    )

    coordinator.apply(destinationId: "dest-A")
    coordinator.apply(destinationId: "dest-A")
    coordinator.apply(destinationId: "dest-A")

    #expect(spy.cancelCount == 1)
    #expect(spy.configureCalls == ["dest-A"])
  }

  @Test func differentIdsCancelAndReconfigure() {
    var spy = Spy()
    let coordinator = AppLifecycleCoordinator(
      cancelActiveWork: { spy.cancelCount += 1 },
      configureRecordStores: { spy.configureCalls.append($0) }
    )

    coordinator.apply(destinationId: "dest-A")
    coordinator.apply(destinationId: "dest-B")
    coordinator.apply(destinationId: nil)

    #expect(spy.cancelCount == 3)
    #expect(spy.configureCalls == ["dest-A", "dest-B", nil])
  }

  @Test func attachAppliesInitialIdAndIsIdempotent() {
    var spy = Spy()
    let coordinator = AppLifecycleCoordinator(
      cancelActiveWork: { spy.cancelCount += 1 },
      configureRecordStores: { spy.configureCalls.append($0) }
    )

    let publisher = Empty<String?, Never>().eraseToAnyPublisher()
    coordinator.attach(initialDestinationId: "dest-A", destinationIdPublisher: publisher)
    coordinator.attach(initialDestinationId: "dest-X", destinationIdPublisher: publisher)
    coordinator.attach(initialDestinationId: nil, destinationIdPublisher: publisher)

    #expect(spy.cancelCount == 1)
    #expect(spy.configureCalls == ["dest-A"])
    #expect(coordinator.lastConfiguredDestinationId == "dest-A")
  }

  @Test func publisherEventsDriveTransitions() {
    var spy = Spy()
    let coordinator = AppLifecycleCoordinator(
      cancelActiveWork: { spy.cancelCount += 1 },
      configureRecordStores: { spy.configureCalls.append($0) }
    )

    let subject = PassthroughSubject<String?, Never>()
    coordinator.attach(
      initialDestinationId: nil,
      destinationIdPublisher: subject.eraseToAnyPublisher()
    )

    subject.send("dest-A")
    subject.send("dest-A")  // duplicate; removeDuplicates filters
    subject.send("dest-B")

    #expect(spy.configureCalls == ["dest-A", "dest-B"])
    #expect(spy.cancelCount == 2)
    #expect(coordinator.lastConfiguredDestinationId == "dest-B")
  }
}
