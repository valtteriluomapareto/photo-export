import Combine
import Foundation
import Testing

@testable import Photo_Export

/// Phase 0a (auto-sync plan): bootstrap and destination-change handling now live in
/// `AppLifecycleCoordinator`. Same-id destination assignments must NOT call
/// `cancelAndClear()` or reconfigure the record stores; only true id changes do. The
/// coordinator now carries the full `DestinationFingerprint` so downstream code (safety
/// gate, AutoSync) can react to `identityConfidence` without recomputing it from a URL.
@MainActor
struct AppLifecycleCoordinatorTests {

  private static func snapshot(_ id: String?, confidence: DestinationIdentityConfidence = .high)
    -> DestinationIdentitySnapshot
  {
    guard let id else { return .none }
    let fingerprint = DestinationFingerprint(
      schemaVersion: DestinationFingerprint.currentSchemaVersion,
      volumeUUIDString: confidence == .high ? "uuid-\(id)" : nil,
      volumeRootPath: nil,
      relativePathFromVolumeRoot: "/dummy",
      standardizedPath: "/Volumes/dummy/\(id)",
      identityConfidence: confidence
    )
    // Replace the snapshot's id with the supplied id so tests can use stable strings — the
    // hash derivation is verified separately in DestinationFingerprintTests.
    return DestinationIdentitySnapshot(id: id, fingerprint: fingerprint)
  }

  @Test func sameIdAssignmentIsANoOp() {
    var cancelCount = 0
    var configureCalls: [String?] = []
    let coordinator = AppLifecycleCoordinator(
      cancelActiveWork: { cancelCount += 1 },
      configureRecordStores: { newId in
        configureCalls.append(newId)
        return .success
      }
    )

    coordinator.apply(destination: Self.snapshot("dest-A"))
    coordinator.apply(destination: Self.snapshot("dest-A"))
    coordinator.apply(destination: Self.snapshot("dest-A"))

    #expect(cancelCount == 1)
    #expect(configureCalls == ["dest-A"])
  }

  @Test func differentIdsCancelAndReconfigure() {
    var cancelCount = 0
    var configureCalls: [String?] = []
    let coordinator = AppLifecycleCoordinator(
      cancelActiveWork: { cancelCount += 1 },
      configureRecordStores: { newId in
        configureCalls.append(newId)
        return .success
      }
    )

    coordinator.apply(destination: Self.snapshot("dest-A"))
    coordinator.apply(destination: Self.snapshot("dest-B"))
    coordinator.apply(destination: .none)

    #expect(cancelCount == 3)
    #expect(configureCalls == ["dest-A", "dest-B", nil])
  }

  @Test func attachAppliesInitialIdAndIsIdempotent() {
    var cancelCount = 0
    var configureCalls: [String?] = []
    let coordinator = AppLifecycleCoordinator(
      cancelActiveWork: { cancelCount += 1 },
      configureRecordStores: { newId in
        configureCalls.append(newId)
        return .success
      }
    )

    let publisher = Empty<DestinationFingerprint?, Never>().eraseToAnyPublisher()
    coordinator.attach(
      initial: Self.snapshot("dest-A"), fingerprintPublisher: publisher)
    coordinator.attach(
      initial: Self.snapshot("dest-X"), fingerprintPublisher: publisher)
    coordinator.attach(
      initial: .none, fingerprintPublisher: publisher)

    #expect(cancelCount == 1)
    #expect(configureCalls == ["dest-A"])
    #expect(coordinator.lastConfiguredDestinationId == "dest-A")
  }

  @Test func currentDestinationCarriesIdentityConfidence() {
    let coordinator = AppLifecycleCoordinator(
      cancelActiveWork: {},
      configureRecordStores: { _ in .success }
    )

    coordinator.apply(destination: Self.snapshot("dest-A", confidence: .low))

    #expect(coordinator.currentDestination.id == "dest-A")
    #expect(coordinator.currentDestination.fingerprint?.identityConfidence == .low)
  }

  @Test func migrationConflictPropagatesToCoordinatorState() {
    let coordinator = AppLifecycleCoordinator(
      cancelActiveWork: {},
      configureRecordStores: { _ in
        .migrationConflict(newId: "new-id", legacyId: "legacy-id")
      }
    )

    coordinator.apply(destination: Self.snapshot("new-id"))

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

    coordinator.apply(destination: Self.snapshot("first"))
    #expect(coordinator.migrationConflict != nil)

    nextResult = .success
    coordinator.apply(destination: Self.snapshot("second"))

    #expect(coordinator.migrationConflict == nil)
  }

  @Test func migrationFailedPreservesAnyPriorConflict() {
    var nextResult: ConfigureRecordStoresResult = .migrationConflict(
      newId: "n", legacyId: "l")
    let coordinator = AppLifecycleCoordinator(
      cancelActiveWork: {},
      configureRecordStores: { _ in nextResult }
    )

    coordinator.apply(destination: Self.snapshot("first"))
    let priorConflict = coordinator.migrationConflict
    #expect(priorConflict != nil)

    // Transient I/O failure during the next configure: must NOT clear the prior conflict
    // — a real legacy/stable mismatch surfaced earlier still needs user resolution.
    nextResult = .migrationFailed(message: "io error")
    coordinator.apply(destination: Self.snapshot("second"))

    #expect(coordinator.migrationConflict == priorConflict)
  }

  @Test func migrationFailedFromCleanStateDoesNotInventAConflict() {
    let coordinator = AppLifecycleCoordinator(
      cancelActiveWork: {},
      configureRecordStores: { _ in .migrationFailed(message: "io error") }
    )

    coordinator.apply(destination: Self.snapshot("pending"))

    #expect(coordinator.migrationConflict == nil)
  }

  @Test func publisherEventsDriveTransitions() {
    var cancelCount = 0
    var configureCalls: [String?] = []
    let coordinator = AppLifecycleCoordinator(
      cancelActiveWork: { cancelCount += 1 },
      configureRecordStores: { newId in
        configureCalls.append(newId)
        return .success
      }
    )

    let subject = PassthroughSubject<DestinationFingerprint?, Never>()
    coordinator.attach(
      initial: .none,
      fingerprintPublisher: subject.eraseToAnyPublisher()
    )

    let fpA = Self.snapshot("dest-A").fingerprint
    let fpB = Self.snapshot("dest-B").fingerprint
    let idA = fpA?.id
    let idB = fpB?.id

    subject.send(fpA)
    subject.send(fpA)  // duplicate id; removeDuplicates filters
    subject.send(fpB)

    #expect(configureCalls == [idA, idB])
    #expect(cancelCount == 2)
    #expect(coordinator.lastConfiguredDestinationId == idB)
  }
}
