import Foundation
import Testing

@testable import Photo_Export

@MainActor
struct ExportManagerHelperTests {
  // Use a minimal ExportManager instance for testing pure helpers.
  // These tests exercise filename utilities and queue counter logic.
  private func makeManager() async -> (ExportManager, ExportRecordStore) {
    let tempDir = TestScratch.directory("ExportManagerHelper")
    let recordStore = ExportRecordStore(baseDirectoryURL: tempDir)
    await recordStore.configureAndWait(for: "test")
    // Left unconfigured: the timeline-only readiness test depends on it.
    let collections = CollectionExportRecordStore(baseDirectoryURL: tempDir)
    let photoLib = PhotoLibraryManager()
    let destMgr = ExportDestinationManager(
      skipRestore: true, userDefaults: TestScratch.defaults("DestinationManager"))
    let manager = ExportManager(
      photoLibraryService: photoLib,
      exportDestination: destMgr,
      exportRecordStore: recordStore,
      collectionExportRecordStore: collections,
      userDefaults: TestScratch.defaults("ExportManagerHelper"))
    return (manager, recordStore)
  }

  // `splitFilename` and `uniqueFileURL` helper tests moved to
  // `ExportDestinationResolverTests` along with the underlying code.

  // MARK: - Queue counter state

  @Test func testQueuedCountDictionaryStartsEmpty() async {
    let (mgr, _) = await makeManager()
    #expect(mgr.queuedCount(year: 2025, month: 1) == 0)
    #expect(mgr.totalJobsEnqueued == 0)
    #expect(mgr.totalJobsCompleted == 0)
  }

  @Test func testPauseAndResumeToggle() async {
    let (mgr, _) = await makeManager()
    // Pause on non-running manager is a no-op
    mgr.pause()
    #expect(mgr.isPaused == false)

    // Resume on non-paused manager is a no-op
    mgr.resume()
    #expect(mgr.isPaused == false)
  }

  // MARK: - canExport gates

  /// Phase 1.5 split canExport into two store-scoped readiness checks. Timeline starts
  /// must require the **timeline** store to be `.ready`; depending on the collection
  /// store would block legitimate timeline export when only the timeline store is
  /// configured (the typical pre-Phase-3 state).
  @Test func canExportTimelineRequiresTimelineReady() async {
    let (mgr, _) = await makeManager()
    // makeManager() configured the timeline store with a destination; collection store
    // was never configured → it stays `.unconfigured`. Timeline export should still work.
    #expect(mgr.canExportTimeline == true)
    #expect(mgr.canExportCollection == false)
  }

  // MARK: - manualExportShouldConfirmSupersede

  /// Idle manager → no supersede confirmation needed; actions dispatch directly.
  /// The autoSync/manual-source cases are intentionally exercised via
  /// `AutoSyncReducerTests` and the toolbar's integration paths rather than
  /// hand-rolled runExport orchestration here — those tests already cover the
  /// active-run branches via the reducer's `ExportRunState` plumbing.
  @Test func manualExportShouldConfirmSupersedeIsFalseWhenIdle() async {
    let (mgr, _) = await makeManager()
    #expect(mgr.activeRunContext == nil)
    #expect(mgr.manualExportShouldConfirmSupersede == false)
  }

  // MARK: - convertHEICToJPEG toggle (issue #47)

  /// The toggle defaults to off when nothing's been persisted, mirrors
  /// through to both record stores on the way in, and persists to the same
  /// `UserDefaults` key on the way out. Pinning this prevents drift in the
  /// "view-side stores see the right answer" contract that
  /// `MonthContentView` / `CollectionContentView` rely on.
  @Test func convertHEICToJPEGToggleDefaultsOffAndMirrorsToStores() async {
    let defaults = TestScratch.defaults("heic47")
    let tempDir = TestScratch.directory("ExportManagerHelper")
    let timeline = ExportRecordStore(baseDirectoryURL: tempDir)
    await timeline.configureAndWait(for: "test")
    let collection = CollectionExportRecordStore(baseDirectoryURL: tempDir)
    await collection.configureAndWait(for: "test")
    let photoLib = PhotoLibraryManager()
    let destMgr = ExportDestinationManager(
      skipRestore: true, userDefaults: TestScratch.defaults("DestinationManager"))
    let manager = ExportManager(
      photoLibraryService: photoLib,
      exportDestination: destMgr,
      exportRecordStore: timeline,
      collectionExportRecordStore: collection,
      userDefaults: defaults)

    #expect(
      manager.convertHEICToJPEG == false,
      "Toggle must default to false when nothing is persisted")
    #expect(timeline.convertHEICToJPEG == false)
    #expect(collection.convertHEICToJPEG == false)

    manager.convertHEICToJPEG = true

    #expect(manager.convertHEICToJPEG == true)
    #expect(
      timeline.convertHEICToJPEG == true,
      "Manager didSet must mirror the toggle into the timeline store")
    #expect(
      collection.convertHEICToJPEG == true,
      "Manager didSet must mirror the toggle into the collection store")
    #expect(
      defaults.bool(forKey: ExportManager.convertHEICToJPEGDefaultsKey) == true,
      "Manager didSet must persist the toggle to UserDefaults")
  }

  /// A second `ExportManager` initialised with the same `UserDefaults`
  /// suite reads back the persisted toggle and pushes it into the record
  /// stores during init (didSet is suppressed during init, so the manual
  /// sync at the bottom of `ExportManager.init` is what guarantees this).
  @Test func convertHEICToJPEGTogglePersistsAcrossManagerInits() async {
    let suiteName = TestScratch.suiteName("heic47-persist")
    let defaults = TestScratch.defaults(suiteName: suiteName)
    defaults.set(true, forKey: ExportManager.convertHEICToJPEGDefaultsKey)

    let tempDir = TestScratch.directory("ExportManagerHelper")
    let timeline = ExportRecordStore(baseDirectoryURL: tempDir)
    await timeline.configureAndWait(for: "test")
    let collection = CollectionExportRecordStore(baseDirectoryURL: tempDir)
    await collection.configureAndWait(for: "test")
    let photoLib = PhotoLibraryManager()
    let destMgr = ExportDestinationManager(
      skipRestore: true, userDefaults: TestScratch.defaults("DestinationManager"))
    let manager = ExportManager(
      photoLibraryService: photoLib,
      exportDestination: destMgr,
      exportRecordStore: timeline,
      collectionExportRecordStore: collection,
      userDefaults: defaults)

    #expect(
      manager.convertHEICToJPEG == true,
      "Manager must read the persisted toggle from UserDefaults at init")
    #expect(
      timeline.convertHEICToJPEG == true,
      "Manager init must mirror the persisted toggle into the timeline store")
    #expect(
      collection.convertHEICToJPEG == true,
      "Manager init must mirror the persisted toggle into the collection store")
  }

  // MARK: - livePhotosPairedExport toggle (issue #49)

  /// Round-trip persistence for the Live Photos paired-export toggle. Unlike
  /// `convertHEICToJPEG`, this one intentionally does NOT push into the record stores
  /// (toggling it doesn't change `requiredVariants` in a way that would affect
  /// `isExported`), so the test only pins the UserDefaults read/write contract — but
  /// that contract is the entire reason the Settings toggle survives a relaunch.
  @Test func livePhotosPairedExportTogglePersistsAcrossManagerInits() async {
    let suiteName = TestScratch.suiteName("livePhotos49-persist")
    let defaults = TestScratch.defaults(suiteName: suiteName)

    // Fresh suite: toggle defaults off, didSet persists to defaults.
    let initial = await makeManagerForTogglePersistence(userDefaults: defaults)
    #expect(
      initial.livePhotosPairedExport == false,
      "Toggle must default to false when nothing is persisted")
    initial.livePhotosPairedExport = true
    #expect(
      defaults.bool(forKey: ExportManager.livePhotosPairedExportDefaultsKey) == true,
      "Manager didSet must persist the toggle to UserDefaults")

    // A second manager built against the same suite reads the persisted value at init.
    let reloaded = await makeManagerForTogglePersistence(userDefaults: defaults)
    #expect(
      reloaded.livePhotosPairedExport == true,
      "Manager init must read the persisted toggle from UserDefaults")
  }

  // MARK: - videoLayout toggle (issue #38)

  /// Round-trip persistence for the Separate Videos into Subfolder toggle. The
  /// `ExportVideoLayout` enum persists by `rawValue` (string) so an older app version
  /// can ignore an unknown future case without crashing; pin that the string-form
  /// round-trip works in both directions. As with `livePhotosPairedExport`, there is
  /// deliberately no store push for this toggle (per the `videoLayout.didSet`
  /// docstring: reconcile correctness rides on the per-variant `subfolder` field,
  /// not on the live store mirror), so this test only pins the UserDefaults contract.
  @Test func videoLayoutTogglePersistsAcrossManagerInits() async {
    let suiteName = TestScratch.suiteName("videoLayout38-persist")
    let defaults = TestScratch.defaults(suiteName: suiteName)

    let initial = await makeManagerForTogglePersistence(userDefaults: defaults)
    #expect(
      initial.videoLayout == .flat,
      "Toggle must default to .flat when nothing is persisted")
    initial.videoLayout = .subfolder
    #expect(
      defaults.string(forKey: ExportManager.videoLayoutDefaultsKey)
        == ExportVideoLayout.subfolder.rawValue,
      "Manager didSet must persist the toggle's rawValue to UserDefaults")

    let reloaded = await makeManagerForTogglePersistence(userDefaults: defaults)
    #expect(
      reloaded.videoLayout == .subfolder,
      "Manager init must read the persisted toggle from UserDefaults")
  }

  /// Shared rig for the two persistence tests above. The base `makeManager()` helper
  /// doesn't take a `UserDefaults` argument, and the two record stores are required so
  /// `ExportManager.init` doesn't fall back to the standard suite (which would leak
  /// state across tests).
  private func makeManagerForTogglePersistence(userDefaults: UserDefaults) async -> ExportManager {
    let tempDir = TestScratch.directory("ExportManagerHelper")
    let timeline = ExportRecordStore(baseDirectoryURL: tempDir)
    await timeline.configureAndWait(for: "test")
    let collection = CollectionExportRecordStore(baseDirectoryURL: tempDir)
    await collection.configureAndWait(for: "test")
    let photoLib = PhotoLibraryManager()
    let destMgr = ExportDestinationManager(
      skipRestore: true, userDefaults: TestScratch.defaults("DestinationManager"))
    return ExportManager(
      photoLibraryService: photoLib,
      exportDestination: destMgr,
      exportRecordStore: timeline,
      collectionExportRecordStore: collection,
      userDefaults: userDefaults)
  }

  @Test func startExportMonthShortCircuitsWhenTimelineNotReady() async {
    let tempDir = TestScratch.directory("ExportManagerHelper")
    let recordStore = ExportRecordStore(baseDirectoryURL: tempDir)
    // Intentionally skip configure(for:) — store stays `.unconfigured`.
    let collections = CollectionExportRecordStore(baseDirectoryURL: tempDir)
    await collections.configureAndWait(for: "test")
    let photoLib = PhotoLibraryManager()
    let destMgr = ExportDestinationManager(
      skipRestore: true, userDefaults: TestScratch.defaults("DestinationManager"))
    let manager = ExportManager(
      photoLibraryService: photoLib,
      exportDestination: destMgr,
      exportRecordStore: recordStore,
      collectionExportRecordStore: collections,
      userDefaults: TestScratch.defaults("ExportManagerHelper"))

    #expect(manager.canExportTimeline == false)
    manager.startExportMonth(year: 2025, month: 6)
    // The start was rejected: no jobs enqueued, no enqueueing-all flag set.
    #expect(manager.totalJobsEnqueued == 0)
    #expect(manager.queuedCount(year: 2025, month: 6) == 0)
  }
}
