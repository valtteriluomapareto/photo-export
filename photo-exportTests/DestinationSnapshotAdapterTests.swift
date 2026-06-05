import Combine
import Foundation
import Testing

@testable import Photo_Export

/// `DestinationSnapshotAdapter` folds four signals into one `DestinationSnapshot`. The
/// safety-state precedence (migration-conflict > needs-confirmation > safe) is documented on the
/// adapter but otherwise only ridden by one CI-only integration test that exercises the all-safe
/// path. These isolated tests pin the mapping. No security-scoped filesystem access is needed
/// (the record stores just create temp dirs), so they run everywhere.
@MainActor
struct DestinationSnapshotAdapterTests {

  @MainActor
  private struct Harness {
    let adapter: DestinationSnapshotAdapter
    let coordinator: AppLifecycleCoordinator
    let monitor: DestinationSafetyMonitor
    let monitorIdentity: CurrentValueSubject<DestinationIdentity, Never>
    let storeRoot: URL
    let suite: String
    let defaults: UserDefaults

    func cleanup() {
      try? FileManager.default.removeItem(at: storeRoot)
      defaults.removePersistentDomain(forName: suite)
    }
  }

  private func makeHarness(
    configureResult: ConfigureRecordStoresResult = .success,
    scanResult: Bool = false
  ) -> Harness {
    let suite = "AdapterTest-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let manager = ExportDestinationManager(
      skipRestore: true, userDefaults: defaults,
      bookmarkDefaultsKey: "bm-\(UUID().uuidString)",
      stableIdDefaultsKey: "sid-\(UUID().uuidString)")
    let coordinator = AppLifecycleCoordinator(
      cancelActiveWork: {}, interruptForDestinationUnavailable: {},
      configureRecordStores: { _ in configureResult })
    let storeRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("AdapterStore-\(UUID().uuidString)", isDirectory: true)
    let recordStore = ExportRecordStore(baseDirectoryURL: storeRoot)
    let collectionStore = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    let monitorIdentity = CurrentValueSubject<DestinationIdentity, Never>(.unavailable)
    let monitor = DestinationSafetyMonitor(
      identityPublisher: monitorIdentity.eraseToAnyPublisher(),
      exportRecordStore: recordStore,
      collectionExportRecordStore: collectionStore,
      confirmationStore: InMemoryDestinationSafetyConfirmationStore(),
      scanDirectory: { @MainActor in scanResult })
    let adapter = DestinationSnapshotAdapter(
      destinationManager: manager, lifecycleCoordinator: coordinator, safetyMonitor: monitor)
    return Harness(
      adapter: adapter, coordinator: coordinator, monitor: monitor,
      monitorIdentity: monitorIdentity, storeRoot: storeRoot, suite: suite, defaults: defaults)
  }

  private func someConflictTrigger() -> DestinationIdentitySnapshot {
    DestinationIdentitySnapshot(
      fingerprint: .makeLow(
        volumeRootPath: nil, relativePathFromVolumeRoot: "/x",
        standardizedPath: "/Volumes/X/x"))
  }

  private func settle() async {
    for _ in 0..<6 { await Task.yield() }
  }

  @Test func mapsNoConflictNoConfirmationToSafe() async {
    let h = makeHarness()
    defer { h.cleanup() }
    var snapshots: [DestinationSnapshot] = []
    let cancellable = h.adapter.destinationSnapshotPublisher.sink { snapshots.append($0) }
    defer { cancellable.cancel() }
    await settle()
    #expect(snapshots.last?.safety == .safe)
  }

  @Test func mapsNeedsConfirmationToUnsafe() async {
    let h = makeHarness(scanResult: true)  // files present on disk
    defer { h.cleanup() }
    h.monitor.attach()
    var snapshots: [DestinationSnapshot] = []
    let cancellable = h.adapter.destinationSnapshotPublisher.sink { snapshots.append($0) }
    defer { cancellable.cancel() }

    // Drive the monitor to flag: non-nil stable id, empty records, unconfirmed, files present.
    h.monitorIdentity.send(DestinationIdentity(stableId: "S", fingerprint: nil))
    await settle()

    #expect(h.monitor.needsSafetyConfirmation == true)
    #expect(snapshots.last?.safety == .unsafeNeedsConfirmation)
  }

  @Test func mapsMigrationConflictToUnsafe() async {
    let h = makeHarness(configureResult: .migrationConflict(newId: "n", legacyId: "l"))
    defer { h.cleanup() }
    var snapshots: [DestinationSnapshot] = []
    let cancellable = h.adapter.destinationSnapshotPublisher.sink { snapshots.append($0) }
    defer { cancellable.cancel() }

    h.coordinator.apply(destination: someConflictTrigger())  // configure → migrationConflict set
    await settle()

    #expect(h.coordinator.migrationConflict != nil)
    #expect(snapshots.last?.safety == .unsafeMigrationConflict)
  }

  @Test func migrationConflictTakesPrecedenceOverNeedsConfirmation() async {
    let h = makeHarness(
      configureResult: .migrationConflict(newId: "n", legacyId: "l"), scanResult: true)
    defer { h.cleanup() }
    h.monitor.attach()
    var snapshots: [DestinationSnapshot] = []
    let cancellable = h.adapter.destinationSnapshotPublisher.sink { snapshots.append($0) }
    defer { cancellable.cancel() }

    h.monitorIdentity.send(DestinationIdentity(stableId: "S", fingerprint: nil))  // → needsConfirm
    h.coordinator.apply(destination: someConflictTrigger())  // → migrationConflict
    await settle()

    #expect(h.monitor.needsSafetyConfirmation == true)
    #expect(h.coordinator.migrationConflict != nil)
    #expect(snapshots.last?.safety == .unsafeMigrationConflict)  // conflict wins
  }
}
