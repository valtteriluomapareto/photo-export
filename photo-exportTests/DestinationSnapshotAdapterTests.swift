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
@Suite(.timeLimit(.minutes(2)))
struct DestinationSnapshotAdapterTests {

  @MainActor
  private struct Harness {
    let adapter: DestinationSnapshotAdapter
    let coordinator: AppLifecycleCoordinator
    let monitor: DestinationSafetyMonitor
    let folder: URL
    let storeRoot: URL
    let suite: String
    let defaults: UserDefaults

    func cleanup() {
      try? FileManager.default.removeItem(at: folder)
      try? FileManager.default.removeItem(at: storeRoot)
      defaults.removePersistentDomain(forName: suite)
    }

    /// Waits until the monitor has checked the selected destination.
    func checked() async -> Bool {
      await eventually("destination checked") {
        monitor.verdict.stableId != nil
      }
    }
  }

  /// A selected destination whose identity feeds both the adapter and the monitor.
  private func makeHarness(
    configureResult: ConfigureRecordStoresResult = .success,
    scanResult: Bool = false
  ) async -> Harness {
    let suite = TestScratch.suiteName("AdapterTest")
    let defaults = TestScratch.defaults(suiteName: suite)
    let folder = TestScratch.directory("AdapterFolder")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let manager = ExportDestinationManager(
      skipRestore: true, userDefaults: defaults,
      bookmarkDefaultsKey: "bm-\(UUID().uuidString)",
      stableIdDefaultsKey: "sid-\(UUID().uuidString)",
      bookmarkSaver: { _ in true }, volumeNotificationCenter: NotificationCenter(),
      validationScopeAcquirer: { _ in true }, validationScopeReleaser: { _ in })
    await manager.persistSelectionAndWait(folder)
    let coordinator = AppLifecycleCoordinator(
      cancelActiveWork: {}, interruptForDestinationUnavailable: {},
      configureRecordStores: { _ in configureResult })
    let storeRoot = TestScratch.directory("AdapterStore")
    let recordStore = ExportRecordStore(baseDirectoryURL: storeRoot)
    let collectionStore = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    let monitor = DestinationSafetyMonitor(
      identityPublisher: manager.identityPublisher,
      exportRecordStore: recordStore,
      collectionExportRecordStore: collectionStore,
      confirmationStore: InMemoryDestinationSafetyConfirmationStore(),
      scanDirectory: { @MainActor in scanResult })
    let adapter = DestinationSnapshotAdapter(
      destinationManager: manager, lifecycleCoordinator: coordinator, safetyMonitor: monitor)
    return Harness(
      adapter: adapter, coordinator: coordinator, monitor: monitor, folder: folder,
      storeRoot: storeRoot, suite: suite, defaults: defaults)
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

  @Test func mapsNoConflictNoConfirmationToSafe() async throws {
    let h = await makeHarness()
    defer { h.cleanup() }
    var snapshots: [DestinationSnapshot] = []
    let cancellable = h.adapter.destinationSnapshotPublisher.sink { snapshots.append($0) }
    defer { cancellable.cancel() }
    h.monitor.attach()
    try #require(await h.checked())
    #expect(snapshots.last?.safety == .safe)
  }

  @Test func mapsNeedsConfirmationToUnsafe() async throws {
    let h = await makeHarness(scanResult: true)  // files present on disk
    defer { h.cleanup() }
    var snapshots: [DestinationSnapshot] = []
    let cancellable = h.adapter.destinationSnapshotPublisher.sink { snapshots.append($0) }
    defer { cancellable.cancel() }

    // The monitor flags: selected destination, empty records, unconfirmed, files present.
    h.monitor.attach()
    try #require(await h.checked())

    #expect(h.monitor.needsSafetyConfirmation == true)
    #expect(snapshots.last?.safety == .unsafeNeedsConfirmation)
  }

  @Test func mapsMigrationConflictToUnsafe() async {
    let h = await makeHarness(configureResult: .migrationConflict(newId: "n", legacyId: "l"))
    defer { h.cleanup() }
    var snapshots: [DestinationSnapshot] = []
    let cancellable = h.adapter.destinationSnapshotPublisher.sink { snapshots.append($0) }
    defer { cancellable.cancel() }

    h.coordinator.apply(destination: someConflictTrigger())  // configure → migrationConflict set
    await settle()

    #expect(h.coordinator.migrationConflict != nil)
    #expect(snapshots.last?.safety == .unsafeMigrationConflict)
  }

  @Test func migrationConflictTakesPrecedenceOverNeedsConfirmation() async throws {
    let h = await makeHarness(
      configureResult: .migrationConflict(newId: "n", legacyId: "l"), scanResult: true)
    defer { h.cleanup() }
    var snapshots: [DestinationSnapshot] = []
    let cancellable = h.adapter.destinationSnapshotPublisher.sink { snapshots.append($0) }
    defer { cancellable.cancel() }

    h.monitor.attach()
    try #require(await h.checked())  // → needsConfirm
    h.coordinator.apply(destination: someConflictTrigger())  // → migrationConflict
    await settle()

    #expect(h.monitor.needsSafetyConfirmation == true)
    #expect(h.coordinator.migrationConflict != nil)
    #expect(snapshots.last?.safety == .unsafeMigrationConflict)  // conflict wins
  }

  /// A selected destination reads `.checking` until the monitor has a verdict for it.
  @Test func selectedDestinationReadsCheckingUntilItsVerdict() async throws {
    let folder = TestScratch.directory("AdapterChecking")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let storeRoot = TestScratch.directory("AdapterCheckingStore")
    let manager = ExportDestinationManager(
      skipRestore: true, userDefaults: TestScratch.defaults("AdapterChecking"),
      bookmarkSaver: { _ in true }, volumeNotificationCenter: NotificationCenter(),
      validationScopeAcquirer: { _ in true }, validationScopeReleaser: { _ in })
    await manager.persistSelectionAndWait(folder)
    try #require(manager.destinationId != nil)
    let coordinator = AppLifecycleCoordinator(
      cancelActiveWork: {}, interruptForDestinationUnavailable: {},
      configureRecordStores: { _ in .success })
    let scan = AsyncCheckpoint()
    let monitor = DestinationSafetyMonitor(
      identityPublisher: manager.identityPublisher,
      exportRecordStore: ExportRecordStore(baseDirectoryURL: storeRoot),
      collectionExportRecordStore: CollectionExportRecordStore(baseDirectoryURL: storeRoot),
      confirmationStore: InMemoryDestinationSafetyConfirmationStore(),
      scanDirectory: { @MainActor in
        await scan.enter()
        return false
      })
    let adapter = DestinationSnapshotAdapter(
      destinationManager: manager, lifecycleCoordinator: coordinator, safetyMonitor: monitor)
    var snapshots: [DestinationSnapshot] = []
    let cancellable = adapter.destinationSnapshotPublisher.sink { snapshots.append($0) }
    try await withCleanup {
      #expect(snapshots.last?.safety == .checking)
      monitor.attach()
      try #require(await scan.waitForEnter(count: 1))
      #expect(snapshots.last?.safety == .checking)

      await scan.releaseAll()
      #expect(await eventually("checked") { snapshots.last?.safety == .safe })
      #expect(snapshots.map(\.safety) == [.checking, .safe])
    } cleanup: {
      cancellable.cancel()
      await scan.releaseAll()
      try? FileManager.default.removeItem(at: folder)
      try? FileManager.default.removeItem(at: storeRoot)
    }
  }
}
