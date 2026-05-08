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
      configureRecordStores: { newId in
        spy.configureCalls.append(newId)
        return .success
      }
    )
    return (coordinator, { spy })
  }

  @Test func sameIdAssignmentIsANoOp() {
    var spy = Spy()
    let coordinator = AppLifecycleCoordinator(
      cancelActiveWork: { spy.cancelCount += 1 },
      configureRecordStores: { newId in
        spy.configureCalls.append(newId)
        return .success
      }
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
      configureRecordStores: { newId in
        spy.configureCalls.append(newId)
        return .success
      }
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
      configureRecordStores: { newId in
        spy.configureCalls.append(newId)
        return .success
      }
    )

    let publisher = Empty<String?, Never>().eraseToAnyPublisher()
    coordinator.attach(initialDestinationId: "dest-A", destinationIdPublisher: publisher)
    coordinator.attach(initialDestinationId: "dest-X", destinationIdPublisher: publisher)
    coordinator.attach(initialDestinationId: nil, destinationIdPublisher: publisher)

    #expect(spy.cancelCount == 1)
    #expect(spy.configureCalls == ["dest-A"])
    #expect(coordinator.lastConfiguredDestinationId == "dest-A")
  }

  @Test func migrationConflictPropagatesToCoordinatorState() {
    let coordinator = AppLifecycleCoordinator(
      cancelActiveWork: {},
      configureRecordStores: { _ in
        .migrationConflict(newId: "new-id", legacyId: "legacy-id")
      }
    )

    coordinator.apply(destinationId: "new-id")

    #expect(
      coordinator.migrationConflict
        == MigrationConflictState(newId: "new-id", legacyId: "legacy-id"))
  }

  @Test func successResultClearsAnyPriorConflict() {
    var nextResult: ConfigureRecordStoresResult = .migrationConflict(
      newId: "n", legacyId: "l")
    let coordinator = AppLifecycleCoordinator(
      cancelActiveWork: {},
      configureRecordStores: { _ in nextResult }
    )

    coordinator.apply(destinationId: "first")
    #expect(coordinator.migrationConflict != nil)

    nextResult = .success
    coordinator.apply(destinationId: "second")

    #expect(coordinator.migrationConflict == nil)
  }

  @Test func migrationFailedDoesNotSurfaceAsConflict() {
    let coordinator = AppLifecycleCoordinator(
      cancelActiveWork: {},
      configureRecordStores: { _ in .migrationFailed(message: "io error") }
    )

    coordinator.apply(destinationId: "pending")

    #expect(coordinator.migrationConflict == nil)
  }

  @Test func publisherEventsDriveTransitions() {
    var spy = Spy()
    let coordinator = AppLifecycleCoordinator(
      cancelActiveWork: { spy.cancelCount += 1 },
      configureRecordStores: { newId in
        spy.configureCalls.append(newId)
        return .success
      }
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
