import Combine
import Foundation
import Testing

@testable import Photo_Export

/// A newly picked folder is not safe until the safety monitor has looked inside it. While its
/// listing is still running (a sleeping disk or a slow network share), Auto Export must not
/// start a run there: the folder may hold someone else's files the user has not confirmed.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct NewDestinationSafetyHoldTests {

  private static func lowConfidence(_ path: String) -> DestinationFingerprint {
    .makeLow(volumeRootPath: nil, relativePathFromVolumeRoot: path, standardizedPath: path)
  }

  @Test func autoExportWaitsForTheNewFolderSafetyScan() async throws {
    let firstDir = TestScratch.directory("SafetyHoldFirst")
    let newDir = TestScratch.directory("SafetyHoldNew")
    for dir in [firstDir, newDir] {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    let storeRoot = TestScratch.directory("SafetyHoldRecords")
    let suite = TestScratch.suiteName("SafetyHold")
    let defaults = TestScratch.defaults(suiteName: suite)

    var fingerprint: DestinationFingerprint? = Self.lowConfidence("/Volumes/A/backup")
    let destinationManager = ExportDestinationManager(
      skipRestore: true, userDefaults: defaults,
      bookmarkDefaultsKey: "Bookmark-\(UUID().uuidString)",
      stableIdDefaultsKey: "StableId-\(UUID().uuidString)",
      fingerprintProvider: { _ in fingerprint },
      sameFolderEvidenceProvider: { _ in .differentFromStored },
      bookmarkSaver: { _ in true },
      validationScopeAcquirer: { _ in true }, validationScopeReleaser: { _ in })
    await destinationManager.persistSelectionAndWait(firstDir)
    let firstId = try #require(destinationManager.destinationId)

    let timelineStore = ExportRecordStore(baseDirectoryURL: storeRoot)
    let collectionStore = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    let lifecycle = AppLifecycleCoordinator(
      cancelActiveWork: {}, interruptForDestinationUnavailable: {},
      configureRecordStores: { newId in
        AppCore.configureRecordStores(
          for: newId, destinationManager: destinationManager,
          timelineStore: timelineStore, collectionStore: collectionStore)
      })
    let confirmations = InMemoryDestinationSafetyConfirmationStore()
    try confirmations.confirm(destinationId: firstId)
    // The new folder holds files; its listing stays held until the test releases it.
    let scanGate = AsyncCheckpoint()
    let safetyMonitor = DestinationSafetyMonitor(
      identityPublisher: destinationManager.identityPublisher,
      exportRecordStore: timelineStore, collectionExportRecordStore: collectionStore,
      confirmationStore: confirmations,
      scanDirectory: { @MainActor in
        await scanGate.enter()
        return true
      })
    let adapter = DestinationSnapshotAdapter(
      destinationManager: destinationManager, lifecycleCoordinator: lifecycle,
      safetyMonitor: safetyMonitor)
    lifecycle.attach(
      initial: DestinationIdentitySnapshot(identity: destinationManager.identity),
      identityPublisher: destinationManager.identityPublisher)

    let builder = FakeAutoSyncEnvironmentBuilder()
    let autoSync = AutoSyncManager()
    try await withCleanup {
      await timelineStore.waitUntilSettled()
      await collectionStore.waitUntilSettled()

      builder.userDefaults.set(true, forKey: AutoSyncManager.enabledDefaultsKey)
      builder.scopes.subject.send(AutoExportScopeSelection(timeline: true))
      autoSync.attach(
        to: AutoSyncEnvironment(
          exportRunner: builder.exportRunner, destination: adapter, scopes: builder.scopes,
          photos: builder.photos, importing: builder.importing,
          dirtyStateStore: builder.dirtyStore, retryStateStore: builder.retryStore,
          runSummaryStore: builder.runSummaryStore,
          perDestinationTokenStore: builder.perDestinationTokenStore,
          currentRunStore: builder.currentRunStore, clock: builder.clock,
          photosAuthorization: builder.photosAuthorization,
          userDefaults: builder.userDefaults))
      let runner = builder.exportRunner
      // As in `AppCore`, the monitor attaches after Auto Export: the launch waits for the check
      // of the confirmed folder, then runs as the launch run.
      safetyMonitor.attach()
      #expect(
        await eventually("launch run scheduled") {
          if case .scheduled(.appLaunch, _) = autoSync.state { return true }
          return false
        })
      builder.clock.advance(by: AutoSyncReducer.debounceDelay(for: .appLaunch))
      #expect(await eventually("launch run") { runner.receivedContexts.count == 1 })
      #expect(runner.receivedContexts.first?.reason == .appLaunch)
      #expect(
        await eventually("launch run ends") {
          if case .running = autoSync.state { return false }
          return true
        })

      // Pick a different, non-empty folder with no history. Its listing is held.
      fingerprint = Self.lowConfidence("/Volumes/B/backup")
      await destinationManager.selectFolderAndWait(newDir)
      let newId = try #require(destinationManager.destinationId)
      try #require(newId != firstId)
      let scanning = await scanGate.waitForEnter(count: 1)
      try #require(scanning)

      // Nothing is scheduled while the listing is held, even past the destination debounce or
      // after Export Now.
      #expect(builder.clock.pendingCount == 0)
      builder.clock.advance(by: 60)
      autoSync.runNow()
      builder.clock.advance(by: 60)
      for _ in 0..<10 { await Task.yield() }
      #expect(runner.receivedContexts.count == 1, "no run before the new folder is checked")

      // The listing finds files: the folder needs the user's confirmation.
      await scanGate.releaseAll()
      #expect(
        await eventually("blocked as unsafe") {
          autoSync.state == .blocked(.destinationUnsafe)
        })
    } cleanup: {
      autoSync.setEnabled(false)
      await scanGate.releaseAll()
      timelineStore.drainSynchronously()
      collectionStore.drainSynchronously()
      try? FileManager.default.removeItem(at: storeRoot)
      try? FileManager.default.removeItem(at: firstDir)
      try? FileManager.default.removeItem(at: newDir)
      defaults.removePersistentDomain(forName: suite)
    }
  }
}
