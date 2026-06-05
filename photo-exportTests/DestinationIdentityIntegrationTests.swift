import Combine
import Foundation
import Testing

@testable import Photo_Export

/// Hand-wired #127 regression: a network-share remount drifts the fingerprint but keeps the
/// **stable id**, and every consumer that keys per-destination state must resolve to that same
/// id afterwards. This wires the real `ExportDestinationManager` → `DestinationSnapshotAdapter`
/// → `AppLifecycleCoordinator` + `DestinationSafetyMonitor` and drives a drift, asserting the
/// record-store configure target, the lifecycle id, the adapter's emitted snapshot id, and the
/// safety key all stay `S`. The "zero duplicate files" leg is covered transitively: the record
/// stores are never reconfigured for a new id (so the on-disk record dir is untouched). The
/// AutoSync dirty-state leg is covered by
/// `AutoSyncReducerTests.remountWithDriftedFingerprintKeepsStableIdAndPreservesDirty`.
///
/// Exercises the real security-scope path in `validate(url:)`, so it shares the
/// `BareTmpScopeProbe` disable guard — runs on CI's `macos-15` runner.
@MainActor
struct DestinationIdentityIntegrationTests {

  private func lowConfidence(_ path: String) -> DestinationFingerprint {
    .makeLow(volumeRootPath: nil, relativePathFromVolumeRoot: path, standardizedPath: path)
  }

  @Test(
    .disabled(
      if: BareTmpScopeProbe.bareTmpRejectsScopeStart(),
      "Local macOS quirk: startAccessingSecurityScopedResource() returns false for bare container tmp URLs, tripping the #92 bail-out in validate(). CI's macos-15 runner runs this."
    ))
  func remountDriftKeepsEveryKeyOnStableId() async throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("RemountIntegration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let recordsRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("RemountRecords-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: recordsRoot) }

    let suite = "RemountIntegration-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    var currentFP: DestinationFingerprint? = lowConfidence("/Volumes/mount-A/backup")
    let manager = ExportDestinationManager(
      skipRestore: true, userDefaults: defaults,
      bookmarkDefaultsKey: "Bookmark-\(UUID().uuidString)",
      stableIdDefaultsKey: "StableId-\(UUID().uuidString)",
      fingerprintProvider: { _ in currentFP })
    manager.persistSelectedFolderForTesting(dir)
    let stableId = try #require(manager.destinationId)

    let timelineStore = ExportRecordStore(baseDirectoryURL: recordsRoot)
    let collectionStore = CollectionExportRecordStore(baseDirectoryURL: recordsRoot)

    var configureCalls: [String?] = []
    let coordinator = AppLifecycleCoordinator(
      cancelActiveWork: {},
      interruptForDestinationUnavailable: {},
      configureRecordStores: { newId in
        configureCalls.append(newId)
        return PhotoExportApp.configureRecordStores(
          for: newId, destinationManager: manager,
          timelineStore: timelineStore, collectionStore: collectionStore)
      })

    let confirmationStore = InMemoryDestinationSafetyConfirmationStore()
    try confirmationStore.confirm(destinationId: stableId)
    let safetyMonitor = DestinationSafetyMonitor(
      identityPublisher: manager.$identity.eraseToAnyPublisher(),
      exportRecordStore: timelineStore,
      collectionExportRecordStore: collectionStore,
      confirmationStore: confirmationStore,
      scanDirectory: { @MainActor in false })

    let adapter = DestinationSnapshotAdapter(
      destinationManager: manager, lifecycleCoordinator: coordinator,
      safetyMonitor: safetyMonitor)

    coordinator.attach(
      initial: DestinationIdentitySnapshot(identity: manager.identity),
      identityPublisher: manager.$identity.eraseToAnyPublisher())
    safetyMonitor.attach()

    var snapshots: [DestinationSnapshot] = []
    let cancellable = adapter.destinationSnapshotPublisher.sink { snapshots.append($0) }
    defer { cancellable.cancel() }

    // Baseline: configured once for S; the adapter is emitting S.
    #expect(configureCalls == [stableId])
    #expect(snapshots.last?.stableId == stableId)

    // Remount drift: same folder, different fingerprint id.
    currentFP = lowConfidence("/Volumes/mount-B/backup")
    #expect(currentFP?.id != stableId)
    manager.revalidateForTesting()
    for _ in 0..<5 { await Task.yield() }

    // Every key still resolves to S.
    #expect(manager.destinationId == stableId)
    #expect(coordinator.currentDestination.id == stableId)
    #expect(configureCalls == [stableId])  // NOT re-keyed → record dir untouched → no re-export
    #expect(snapshots.last?.stableId == stableId)
    #expect(snapshots.last?.fingerprint == currentFP)  // advisory fingerprint refreshed
    // Safety leg: the confirmation is keyed on S, and because the monitor dedups on stableId the
    // drift doesn't even re-fire evaluation — so there is no re-prompt on remount. (The unit
    // `confirmationPersistsAcrossRemountDrift` covers the keying directly; here we assert the
    // wired monitor stays quiet.)
    #expect(confirmationStore.isConfirmed(destinationId: stableId))
    #expect(safetyMonitor.needsSafetyConfirmation == false)
  }
}
