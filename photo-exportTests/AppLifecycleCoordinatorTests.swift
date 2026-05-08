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

  /// Builds a snapshot whose id is derived from a fingerprint constructed from `tag` so
  /// each call produces a stable, distinct id. Tests assert against the snapshot's
  /// derived `id` rather than `tag` directly — the snapshot's id is the SHA-256 hex of
  /// the fingerprint's components, which is what `AppLifecycleCoordinator` compares.
  private static func snapshot(
    _ tag: String, confidence: DestinationIdentityConfidence = .high
  ) -> DestinationIdentitySnapshot {
    let fingerprint: DestinationFingerprint
    switch confidence {
    case .high:
      fingerprint = .makeHigh(
        volumeUUIDString: "uuid-\(tag)",
        volumeRootPath: nil,
        relativePathFromVolumeRoot: "/\(tag)",
        standardizedPath: "/Volumes/\(tag)"
      )
    case .low:
      fingerprint = .makeLow(
        volumeRootPath: nil,
        relativePathFromVolumeRoot: "/\(tag)",
        standardizedPath: "/Volumes/\(tag)"
      )
    }
    return DestinationIdentitySnapshot(fingerprint: fingerprint)
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

    let snap = Self.snapshot("dest-A")
    coordinator.apply(destination: snap)
    coordinator.apply(destination: snap)
    coordinator.apply(destination: snap)

    #expect(cancelCount == 1)
    #expect(configureCalls == [snap.id])
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

    let snapA = Self.snapshot("dest-A")
    let snapB = Self.snapshot("dest-B")
    coordinator.apply(destination: snapA)
    coordinator.apply(destination: snapB)
    coordinator.apply(destination: .none)

    #expect(cancelCount == 3)
    #expect(configureCalls == [snapA.id, snapB.id, nil])
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
    let snapA = Self.snapshot("dest-A")
    coordinator.attach(initial: snapA, fingerprintPublisher: publisher)
    coordinator.attach(initial: Self.snapshot("dest-X"), fingerprintPublisher: publisher)
    coordinator.attach(initial: .none, fingerprintPublisher: publisher)

    #expect(cancelCount == 1)
    #expect(configureCalls == [snapA.id])
    #expect(coordinator.lastConfiguredDestinationId == snapA.id)
  }

  @Test func sameIdDoesNotRePublishCurrentDestinationWhenSnapshotIsEqual() {
    let coordinator = AppLifecycleCoordinator(
      cancelActiveWork: {},
      configureRecordStores: { _ in .success }
    )
    var emissions = 0
    let cancellable = coordinator.$currentDestination.dropFirst().sink { _ in
      emissions += 1
    }

    let snap = Self.snapshot("dest-A")
    coordinator.apply(destination: snap)
    coordinator.apply(destination: snap)
    coordinator.apply(destination: snap)

    cancellable.cancel()

    // Three apply calls, only one is a real change: the first. Subsequent same-snapshot
    // applies must not re-fire @Published.
    #expect(emissions == 1)
  }

  @Test func currentDestinationCarriesIdentityConfidence() {
    let coordinator = AppLifecycleCoordinator(
      cancelActiveWork: {},
      configureRecordStores: { _ in .success }
    )

    let snap = Self.snapshot("dest-A", confidence: .low)
    coordinator.apply(destination: snap)

    #expect(coordinator.currentDestination.id == snap.id)
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
