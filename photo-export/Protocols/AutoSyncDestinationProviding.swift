import Combine
import Foundation

/// AutoSync's view of the destination subsystem. `ExportDestinationManager` /
/// `AppLifecycleCoordinator` provide the production stream; tests inject a fake
/// driven by `PassthroughSubject` to push specific snapshots.
///
/// The publisher emits a `DestinationSnapshot` whenever any component (fingerprint,
/// availability, safety) changes. New subscribers receive the current snapshot
/// immediately.
@MainActor
protocol AutoSyncDestinationProviding: AnyObject {
  var destinationSnapshotPublisher: AnyPublisher<DestinationSnapshot, Never> { get }
}

/// AutoSync's view of the user's scope selection (Settings → Auto Export checkboxes).
/// Production code reads from `UserDefaults` via a settings store; tests use an
/// in-memory fake.
@MainActor
protocol AutoExportScopeProviding: AnyObject {
  var scopeSelectionPublisher: AnyPublisher<AutoExportScopeSelection, Never> { get }
}

/// AutoSync's view of the import subsystem. Tracks whether `startImport()` is
/// currently running so the reducer can route to `.waiting(.importActive)`.
@MainActor
protocol AutoSyncImportProviding: AnyObject {
  var isImportingPublisher: AnyPublisher<Bool, Never> { get }
}
