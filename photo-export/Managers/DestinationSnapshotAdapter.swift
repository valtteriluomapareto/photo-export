import Combine
import Foundation

/// Production `AutoSyncDestinationProviding` wiring. Combines the three signals
/// AutoSync needs into a single `DestinationSnapshot` stream:
///
/// 1. `destinationFingerprint` from `ExportDestinationManager` — the canonical
///    identity. Nil means "no destination selected" (or the drive is unmounted
///    with no cached fingerprint).
/// 2. `isAvailable` from `ExportDestinationManager` — drive mounted and writable.
/// 3. Safety state, derived for Phase 2 from `AppLifecycleCoordinator.migrationConflict`:
///    a non-nil conflict → `.unsafeMigrationConflict`. Phase 0b's destination
///    safety scan will replace this with the richer
///    `.unsafeNeedsConfirmation` path; until then a clean fingerprint is
///    treated as `.safe`.
///
/// `Publishers.CombineLatest3` waits for all three sources to publish before
/// emitting; both `ExportDestinationManager` and `AppLifecycleCoordinator`
/// publish initial values via `@Published`, so the first emission lands on the
/// next runloop tick after subscribe.
@MainActor
final class DestinationSnapshotAdapter: AutoSyncDestinationProviding {
  private let destinationManager: ExportDestinationManager
  private let lifecycleCoordinator: AppLifecycleCoordinator
  private let cachedPublisher: AnyPublisher<DestinationSnapshot, Never>

  init(
    destinationManager: ExportDestinationManager,
    lifecycleCoordinator: AppLifecycleCoordinator
  ) {
    self.destinationManager = destinationManager
    self.lifecycleCoordinator = lifecycleCoordinator
    self.cachedPublisher = Self.makePublisher(
      destinationManager: destinationManager, lifecycleCoordinator: lifecycleCoordinator)
  }

  var destinationSnapshotPublisher: AnyPublisher<DestinationSnapshot, Never> {
    cachedPublisher
  }

  private static func makePublisher(
    destinationManager: ExportDestinationManager,
    lifecycleCoordinator: AppLifecycleCoordinator
  ) -> AnyPublisher<DestinationSnapshot, Never> {
    Publishers.CombineLatest3(
      destinationManager.$destinationFingerprint,
      destinationManager.$isAvailable,
      lifecycleCoordinator.$migrationConflict
    )
    .map { fingerprint, isAvailable, conflict in
      let safety: DestinationSafetyState =
        conflict != nil ? .unsafeMigrationConflict : .safe
      return DestinationSnapshot(
        fingerprint: fingerprint, isAvailable: isAvailable, safety: safety)
    }
    .removeDuplicates()
    .eraseToAnyPublisher()
  }
}
