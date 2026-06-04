import Combine
import Foundation

/// Production `AutoSyncDestinationProviding` wiring. Combines four signals
/// AutoSync needs into a single `DestinationSnapshot` stream:
///
/// 1. `identity` from `ExportDestinationManager` — the stable logical id plus the
///    advisory fingerprint, published as one atomic value. A `nil` `stableId` means
///    "no destination selected" or the drive is currently unavailable.
/// 2. `isAvailable` from `ExportDestinationManager` — drive mounted and writable.
/// 3. `migrationConflict` from `AppLifecycleCoordinator`: non-nil → safety
///    becomes `.unsafeMigrationConflict`.
/// 4. `needsSafetyConfirmation` from `DestinationSafetyMonitor` (Phase 0b):
///    true → safety becomes `.unsafeNeedsConfirmation`. Migration conflict
///    takes precedence — both being true is rare (a fresh destination with
///    legacy records is itself a rare collision) but if it ever happens the
///    migration conflict UX leads.
///
/// `Publishers.CombineLatest4` waits for all four sources to publish before
/// emitting; each is an `@Published` that fires an initial value, so the first
/// emission lands on the next runloop tick after subscribe.
@MainActor
final class DestinationSnapshotAdapter: AutoSyncDestinationProviding {
  private let destinationManager: ExportDestinationManager
  private let lifecycleCoordinator: AppLifecycleCoordinator
  private let safetyMonitor: DestinationSafetyMonitor
  private let cachedPublisher: AnyPublisher<DestinationSnapshot, Never>

  init(
    destinationManager: ExportDestinationManager,
    lifecycleCoordinator: AppLifecycleCoordinator,
    safetyMonitor: DestinationSafetyMonitor
  ) {
    self.destinationManager = destinationManager
    self.lifecycleCoordinator = lifecycleCoordinator
    self.safetyMonitor = safetyMonitor
    self.cachedPublisher = Self.makePublisher(
      destinationManager: destinationManager,
      lifecycleCoordinator: lifecycleCoordinator,
      safetyMonitor: safetyMonitor)
  }

  var destinationSnapshotPublisher: AnyPublisher<DestinationSnapshot, Never> {
    cachedPublisher
  }

  private static func makePublisher(
    destinationManager: ExportDestinationManager,
    lifecycleCoordinator: AppLifecycleCoordinator,
    safetyMonitor: DestinationSafetyMonitor
  ) -> AnyPublisher<DestinationSnapshot, Never> {
    Publishers.CombineLatest4(
      destinationManager.$identity,
      destinationManager.$isAvailable,
      lifecycleCoordinator.$migrationConflict,
      safetyMonitor.$needsSafetyConfirmation
    )
    .map { identity, isAvailable, conflict, needsConfirm in
      let safety: DestinationSafetyState
      if conflict != nil {
        safety = .unsafeMigrationConflict
      } else if needsConfirm {
        safety = .unsafeNeedsConfirmation
      } else {
        safety = .safe
      }
      // Key on the stable id; carry the fingerprint for the safety gate's confidence read.
      return DestinationSnapshot(
        stableId: identity.stableId, fingerprint: identity.fingerprint,
        isAvailable: isAvailable, safety: safety)
    }
    .removeDuplicates()
    .eraseToAnyPublisher()
  }
}
