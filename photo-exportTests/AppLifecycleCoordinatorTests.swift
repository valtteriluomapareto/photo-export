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

  /// Wraps a fingerprint into a no-drift identity whose stable id tracks the fingerprint id.
  private static func identity(_ fingerprint: DestinationFingerprint?) -> DestinationIdentity {
    DestinationIdentity(stableId: fingerprint?.id, fingerprint: fingerprint)
  }

  @Test func sameIdAssignmentIsANoOp() {
    var cancelCount = 0
    var configureCalls: [String?] = []
    let coordinator = AppLifecycleCoordinator(
      cancelActiveWork: { cancelCount += 1 },
      interruptForDestinationUnavailable: {},
      configureRecordStores: { newId in
        configureCalls.append(newId)
        return .success
      }
    )

    let snap = Self.snapshot("dest-A")
    coordinator.apply(destination: snap)
    coordinator.apply(destination: snap)
    coordinator.apply(destination: snap)

    // First apply is nil → snap (first selection, no cleanup); 2nd/3rd are same-id no-ops.
    // So cancelCount stays at 0 and configure runs exactly once.
    #expect(cancelCount == 0)
    #expect(configureCalls == [snap.id])
  }

  @Test func transitionTypesRouteToTheCorrectCleanup() {
    var cancelCount = 0
    var interruptCount = 0
    var configureCalls: [String?] = []
    let coordinator = AppLifecycleCoordinator(
      cancelActiveWork: { cancelCount += 1 },
      interruptForDestinationUnavailable: { interruptCount += 1 },
      configureRecordStores: { newId in
        configureCalls.append(newId)
        return .success
      }
    )

    let snapA = Self.snapshot("dest-A")
    let snapB = Self.snapshot("dest-B")
    coordinator.apply(destination: snapA)  // nil → A: first selection (no cleanup)
    coordinator.apply(destination: snapB)  // A → B: true change (cancel)
    coordinator.apply(destination: .none)  // B → nil: unmount (interrupt)
    coordinator.apply(destination: snapA)  // nil → A: remount (no cleanup)

    #expect(cancelCount == 1)
    #expect(interruptCount == 1)
    #expect(configureCalls == [snapA.id, snapB.id, nil, snapA.id])
  }

  @Test func attachAppliesInitialIdAndIsIdempotent() {
    var cancelCount = 0
    var configureCalls: [String?] = []
    let coordinator = AppLifecycleCoordinator(
      cancelActiveWork: { cancelCount += 1 },
      interruptForDestinationUnavailable: {},
      configureRecordStores: { newId in
        configureCalls.append(newId)
        return .success
      }
    )

    let publisher = Empty<DestinationIdentity, Never>().eraseToAnyPublisher()
    let snapA = Self.snapshot("dest-A")
    coordinator.attach(initial: snapA, identityPublisher: publisher)
    coordinator.attach(initial: Self.snapshot("dest-X"), identityPublisher: publisher)
    coordinator.attach(initial: .none, identityPublisher: publisher)

    // First attach: nil → snapA (first selection, no cancel). Subsequent attaches are
    // idempotent no-ops. cancelCount remains 0.
    #expect(cancelCount == 0)
    #expect(configureCalls == [snapA.id])
    #expect(coordinator.lastConfiguredDestinationId == snapA.id)
  }

  @Test func sameIdDoesNotRePublishCurrentDestinationWhenSnapshotIsEqual() {
    let coordinator = AppLifecycleCoordinator(
      cancelActiveWork: {},
      interruptForDestinationUnavailable: {},
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
      interruptForDestinationUnavailable: {},
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
      interruptForDestinationUnavailable: {},
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
      interruptForDestinationUnavailable: {},
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
      interruptForDestinationUnavailable: {},
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
      interruptForDestinationUnavailable: {},
      configureRecordStores: { _ in .migrationFailed(message: "io error") }
    )

    coordinator.apply(destination: Self.snapshot("pending"))

    #expect(coordinator.migrationConflict == nil)
  }

  /// Same-id fingerprint refresh (e.g. drive rename — same UUID + relative path, different
  /// `volumeRootPath` / `standardizedPath`) must propagate through the publisher so
  /// `currentDestination` reflects the freshest metadata. The dedup must be on full
  /// fingerprint equality, not just id.
  @Test func sameIdFingerprintRefreshUpdatesCurrentDestination() {
    let coordinator = AppLifecycleCoordinator(
      cancelActiveWork: {},
      interruptForDestinationUnavailable: {},
      configureRecordStores: { _ in .success }
    )

    let original = DestinationFingerprint.makeHigh(
      volumeUUIDString: "uuid-stable",
      volumeRootPath: "/Volumes/MyDrive",
      relativePathFromVolumeRoot: "/photos",
      standardizedPath: "/Volumes/MyDrive/photos"
    )
    let renamed = DestinationFingerprint.makeHigh(
      volumeUUIDString: "uuid-stable",
      volumeRootPath: "/Volumes/PhotoBackup",
      relativePathFromVolumeRoot: "/photos",
      standardizedPath: "/Volumes/PhotoBackup/photos"
    )

    // Same id (UUID + relative path identical), different metadata.
    #expect(original.id == renamed.id)
    #expect(original != renamed)

    let subject = PassthroughSubject<DestinationIdentity, Never>()
    coordinator.attach(
      initial: .none, identityPublisher: subject.eraseToAnyPublisher())

    subject.send(Self.identity(original))
    #expect(coordinator.currentDestination.fingerprint == original)

    subject.send(Self.identity(renamed))
    #expect(coordinator.currentDestination.fingerprint == renamed)
  }

  @Test func publisherEventsDriveTransitions() {
    var cancelCount = 0
    var configureCalls: [String?] = []
    let coordinator = AppLifecycleCoordinator(
      cancelActiveWork: { cancelCount += 1 },
      interruptForDestinationUnavailable: {},
      configureRecordStores: { newId in
        configureCalls.append(newId)
        return .success
      }
    )

    let subject = PassthroughSubject<DestinationIdentity, Never>()
    coordinator.attach(
      initial: .none,
      identityPublisher: subject.eraseToAnyPublisher()
    )

    let fpA = Self.snapshot("dest-A").fingerprint
    let fpB = Self.snapshot("dest-B").fingerprint
    let idA = fpA?.id
    let idB = fpB?.id

    subject.send(Self.identity(fpA))
    subject.send(Self.identity(fpA))  // duplicate identity; removeDuplicates filters
    subject.send(Self.identity(fpB))

    // nil → A: first selection (no cancel). A → A: filtered duplicate. A → B: true change
    // (cancel). cancelCount is 1.
    #expect(configureCalls == [idA, idB])
    #expect(cancelCount == 1)
    #expect(coordinator.lastConfiguredDestinationId == idB)
  }

  @Test func clearMigrationConflictAfterReconcileGCsLegacyAndClearsFlag() {
    var gcCalls: [String] = []
    let coordinator = AppLifecycleCoordinator(
      cancelActiveWork: {},
      interruptForDestinationUnavailable: {},
      configureRecordStores: { _ in
        .migrationConflict(newId: "new-A", legacyId: "legacy-B")
      },
      gcLegacyState: { legacyId in gcCalls.append(legacyId) }
    )

    coordinator.apply(destination: Self.snapshot("dest-A"))
    #expect(
      coordinator.migrationConflict
        == MigrationConflictState(newId: "new-A", legacyId: "legacy-B"))

    coordinator.clearMigrationConflictAfterReconcile()

    #expect(gcCalls == ["legacy-B"])
    #expect(coordinator.migrationConflict == nil)
  }

  /// #127: a network-share remount keeps the same **stable id** but drifts the fingerprint.
  /// That must be classified as the same destination — no `cancelActiveWork()`, no record-store
  /// reconfigure — only a metadata refresh on `currentDestination`. Keying on `fingerprint.id`
  /// (the old behavior) would mis-fire a destination change here and re-export everything.
  @Test func remountWithDriftedFingerprintIsTreatedAsSameDestination() {
    var cancelCount = 0
    var configureCalls: [String?] = []
    let coordinator = AppLifecycleCoordinator(
      cancelActiveWork: { cancelCount += 1 },
      interruptForDestinationUnavailable: {},
      configureRecordStores: { newId in
        configureCalls.append(newId)
        return .success
      }
    )

    let subject = PassthroughSubject<DestinationIdentity, Never>()
    coordinator.attach(initial: .none, identityPublisher: subject.eraseToAnyPublisher())

    let stableId = "stable-S"
    let fpMountA = DestinationFingerprint.makeLow(
      volumeRootPath: nil, relativePathFromVolumeRoot: "/backup",
      standardizedPath: "/Volumes/mount-A/backup")
    let fpMountB = DestinationFingerprint.makeLow(
      volumeRootPath: nil, relativePathFromVolumeRoot: "/backup",
      standardizedPath: "/Volumes/mount-B/backup")
    #expect(fpMountA.id != fpMountB.id)  // the drift is real

    subject.send(DestinationIdentity(stableId: stableId, fingerprint: fpMountA))
    subject.send(DestinationIdentity(stableId: stableId, fingerprint: fpMountB))

    // Configured once (nil → S); the drift is a same-id metadata refresh, not a re-key.
    #expect(configureCalls == [stableId])
    #expect(cancelCount == 0)
    #expect(coordinator.currentDestination.id == stableId)
    #expect(coordinator.currentDestination.fingerprint == fpMountB)
  }

  @Test func clearMigrationConflictAfterReconcileIsIdempotent() {
    var gcCalls: [String] = []
    let coordinator = AppLifecycleCoordinator(
      cancelActiveWork: {},
      interruptForDestinationUnavailable: {},
      configureRecordStores: { _ in .success },
      gcLegacyState: { legacyId in gcCalls.append(legacyId) }
    )

    // No conflict in flight — calling the resolver is a no-op.
    coordinator.clearMigrationConflictAfterReconcile()
    coordinator.clearMigrationConflictAfterReconcile()

    #expect(gcCalls.isEmpty)
    #expect(coordinator.migrationConflict == nil)
  }
}
