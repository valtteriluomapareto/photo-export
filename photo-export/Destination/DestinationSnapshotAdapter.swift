import Combine
import Foundation

/// Production `AutoSyncDestinationProviding` wiring. Combines three signals
/// AutoSync needs into a single `DestinationSnapshot` stream:
///
/// 1. Coherent destination access from `ExportDestinationManager`, published after
///    the identity and its record stores have adopted the validation result.
/// 2. `migrationConflict` from `AppLifecycleCoordinator`: non-nil → safety
///    becomes `.unsafeMigrationConflict`.
/// 3. `verdict` from `DestinationSafetyMonitor`: a verdict for another stable id means this
///    destination has not been checked yet → `.checking`; otherwise needing confirmation →
///    `.unsafeNeedsConfirmation`. Migration conflict takes precedence — both being true is
///    rare (a fresh destination with legacy records is itself a rare collision) but if it
///    ever happens the migration conflict UX leads.
///
/// Each source replays its initial value, so the first snapshot is synchronous.
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
    Publishers.CombineLatest3(
      destinationManager.accessPublisher,
      lifecycleCoordinator.migrationConflictPublisher,
      safetyMonitor.verdictPublisher
    )
    .map { access, conflict, verdict in
      let identity = access.identity
      let safety: DestinationSafetyState
      if conflict != nil {
        safety = .unsafeMigrationConflict
      } else if verdict.stableId != identity.stableId {
        safety = .checking
      } else if verdict.needsConfirmation {
        safety = .unsafeNeedsConfirmation
      } else {
        safety = .safe
      }
      // Key on the stable id; carry the fingerprint for the safety gate's confidence read.
      return DestinationSnapshot(
        stableId: identity.stableId, fingerprint: identity.fingerprint,
        isAvailable: access.isAvailable, isWritable: access.isWritable,
        isValidating: access.isValidating, safety: safety)
    }
    .removeDuplicates()
    .eraseToAnyPublisher()
  }
}
