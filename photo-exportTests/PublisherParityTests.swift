import Combine
import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Characterizes every named publisher accessor on the current `ObservableObject` types with
/// `assertPublishedParity`. These pass against `@Published` storage today and must keep passing
/// unchanged when a type's storage moves to Observation, so subscribers (AutoSync, the
/// destination adapter, the lifecycle and safety monitors) see the same deliveries.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct PublisherParityTests {
  private static func fingerprint(_ tag: String) -> DestinationFingerprint {
    .makeHigh(
      volumeUUIDString: "uuid-\(tag)", volumeRootPath: nil,
      relativePathFromVolumeRoot: "/\(tag)", standardizedPath: "/Volumes/\(tag)")
  }

  private static func snapshot(_ tag: String) -> DestinationIdentitySnapshot {
    DestinationIdentitySnapshot(fingerprint: fingerprint(tag))
  }

  private static func identity(_ tag: String) -> DestinationIdentity {
    let fingerprint = fingerprint(tag)
    return DestinationIdentity(stableId: fingerprint.id, fingerprint: fingerprint)
  }

  // MARK: - ExportDestinationManager

  private static func destinationManager() -> ExportDestinationManager {
    ExportDestinationManager(
      skipRestore: true, userDefaults: TestScratch.defaults("ParityDestination"),
      sameFolderEvidenceProvider: { _ in .differentFromStored },
      bookmarkSaver: { _ in true }, volumeNotificationCenter: NotificationCenter(),
      validationScopeAcquirer: { _ in true }, validationScopeReleaser: { _ in })
  }

  private static func folder(_ label: String) throws -> URL {
    let folder = TestScratch.directory(label)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  @Test func destinationIdentity() async throws {
    let folder = try Self.folder("ParityIdentity")
    defer { try? FileManager.default.removeItem(at: folder) }
    let manager = Self.destinationManager()
    manager.setSelectedFolderForTesting(folder)
    try #require(manager.identity == .unavailable)
    await assertPublishedParity(
      manager, \.identity, { $0.identityPublisher },
      change: { manager.revalidateForTesting() },
      // Revalidating the unchanged folder computes an equal identity, which
      // `identity != next` skips.
      unchangedWrite: .after { manager.revalidateForTesting() },
      unchangedWriteDelivery: .isDropped)
    #expect(manager.identity.stableId != nil)
  }

  @Test func destinationIsAvailable() async throws {
    let folder = try Self.folder("ParityAvailable")
    defer { try? FileManager.default.removeItem(at: folder) }
    let manager = Self.destinationManager()
    manager.setSelectedFolderForTesting(folder)
    await assertPublishedParity(
      manager, \.isAvailable, { $0.isAvailablePublisher },
      change: {
        try? FileManager.default.removeItem(at: folder)
        manager.revalidateForTesting()
      },
      unchangedWrite: .before { manager.revalidateForTesting() })
    #expect(!manager.isAvailable)
  }

  // MARK: - AppLifecycleCoordinator

  @Test func lifecycleCurrentDestination() async {
    let coordinator = AppLifecycleCoordinator(
      cancelActiveWork: {}, interruptForDestinationUnavailable: {},
      configureRecordStores: { _ in .success })
    await assertPublishedParity(
      coordinator, \.currentDestination, { $0.currentDestinationPublisher },
      change: { coordinator.apply(destination: Self.snapshot("A")) },
      // `apply` skips a snapshot equal to the current one.
      unchangedWrite: .after { coordinator.apply(destination: Self.snapshot("A")) },
      unchangedWriteDelivery: .isDropped)
  }

  @Test func lifecycleMigrationConflict() async {
    var result = ConfigureRecordStoresResult.success
    let coordinator = AppLifecycleCoordinator(
      cancelActiveWork: {}, interruptForDestinationUnavailable: {},
      configureRecordStores: { _ in result })
    coordinator.apply(destination: Self.snapshot("A"))
    await assertPublishedParity(
      coordinator, \.migrationConflict, { $0.migrationConflictPublisher },
      change: {
        result = .migrationConflict(newId: "new", legacyId: "legacy")
        coordinator.apply(destination: Self.snapshot("C"))
      },
      // A successful configure for a new destination clears the conflict unconditionally.
      unchangedWrite: .before { coordinator.apply(destination: Self.snapshot("B")) })
    #expect(
      coordinator.migrationConflict == MigrationConflictState(newId: "new", legacyId: "legacy"))
  }

  // MARK: - DestinationSafetyMonitor

  @Test func safetyNeedsConfirmation() async throws {
    let root = TestScratch.directory("ParitySafety")
    defer { try? FileManager.default.removeItem(at: root) }
    let timeline = ExportRecordStore(baseDirectoryURL: root)
    let collections = CollectionExportRecordStore(baseDirectoryURL: root)
    timeline.configure(for: "A")
    collections.configure(for: "A")
    let identity = CurrentValueSubject<DestinationIdentity, Never>(Self.identity("A"))
    let monitor = DestinationSafetyMonitor(
      identityPublisher: identity.eraseToAnyPublisher(),
      exportRecordStore: timeline, collectionExportRecordStore: collections,
      confirmationStore: InMemoryDestinationSafetyConfirmationStore(), scanDirectory: { true })
    monitor.attach()
    try #require(await eventually("scan flags the destination") { monitor.needsSafetyConfirmation })
    await assertPublishedParity(
      monitor, \.needsSafetyConfirmation, { $0.needsSafetyConfirmationPublisher },
      change: { monitor.confirmCurrentDestination() },
      // Confirming again stores `false` again.
      unchangedWrite: .after { monitor.confirmCurrentDestination() })
    timeline.drainSynchronously()
    collections.drainSynchronously()
  }

  // MARK: - PhotoLibraryManager

  @Test func libraryAuthorizationStatus() async {
    let library = PhotoLibraryManager(overrideService: FakePhotoLibraryService())
    await assertPublishedParity(
      library, \.authorizationStatus, { $0.authorizationStatusPublisher },
      change: { library.authorizationStatus = .denied },
      unchangedWrite: .before { library.authorizationStatus = library.authorizationStatus })
  }

  @Test func libraryIsAuthorized() async {
    let library = PhotoLibraryManager(overrideService: FakePhotoLibraryService())
    await assertPublishedParity(
      library, \.isAuthorized, { $0.isAuthorizedPublisher },
      change: { library.isAuthorized = false },
      unchangedWrite: .before { library.isAuthorized = library.isAuthorized })
  }

  // MARK: - ExportManager

  @MainActor
  private final class ManagerFixture {
    let root = TestScratch.directory("ParityExportManager")
    let destination = FakeExportDestination()
    let timeline: ExportRecordStore
    let collections: CollectionExportRecordStore
    let manager: ExportManager

    init() {
      timeline = ExportRecordStore(baseDirectoryURL: root)
      collections = CollectionExportRecordStore(baseDirectoryURL: root)
      timeline.configure(for: "A")
      collections.configure(for: "A")
      manager = ExportManager(
        photoLibraryService: FakePhotoLibraryService(), exportDestination: destination,
        exportRecordStore: timeline, collectionExportRecordStore: collections,
        assetResourceWriter: FakeAssetResourceWriter(), fileSystem: FakeFileSystem(),
        userDefaults: TestScratch.defaults("ParityExportManager"))
    }

    /// A refused check of a confirmed same folder, which stores `nil` in `importStage` again.
    func refuseConfirmedSameFolderCheck() {
      let folder = destination.selectedFolderURL
      destination.selectedFolderURL = nil
      manager.startImportForConfirmedSameFolder()
      destination.selectedFolderURL = folder
    }

    func close() async {
      manager.cancelImport()
      manager.cancelAndClear()
      try? await timeline.flush()
      try? await collections.flush()
      destination.cleanup()
      try? FileManager.default.removeItem(at: root)
    }
  }

  @Test func managerVersionSelection() async {
    let f = ManagerFixture()
    await withCleanup {
      await assertPublishedParity(
        f.manager, \.versionSelection, { $0.versionSelectionPublisher },
        change: {
          f.manager.versionSelection =
            f.manager.versionSelection == .edited ? .editedWithOriginals : .edited
        },
        unchangedWrite: .before { f.manager.versionSelection = f.manager.versionSelection })
    } cleanup: {
      await f.close()
    }
  }

  @Test func managerConvertHEICToJPEG() async {
    let f = ManagerFixture()
    await withCleanup {
      await assertPublishedParity(
        f.manager, \.convertHEICToJPEG, { $0.convertHEICToJPEGPublisher },
        change: { f.manager.convertHEICToJPEG.toggle() },
        unchangedWrite: .before { f.manager.convertHEICToJPEG = f.manager.convertHEICToJPEG })
    } cleanup: {
      await f.close()
    }
  }

  @Test func managerLivePhotosPairedExport() async {
    let f = ManagerFixture()
    await withCleanup {
      await assertPublishedParity(
        f.manager, \.livePhotosPairedExport, { $0.livePhotosPairedExportPublisher },
        change: { f.manager.livePhotosPairedExport.toggle() },
        unchangedWrite: .before {
          f.manager.livePhotosPairedExport = f.manager.livePhotosPairedExport
        })
    } cleanup: {
      await f.close()
    }
  }

  @Test func managerImportStage() async {
    let f = ManagerFixture()
    await withCleanup {
      await assertPublishedParity(
        f.manager, \.importStage, { $0.importStagePublisher },
        change: { f.manager.startImport() },
        unchangedWrite: .before { f.refuseConfirmedSameFolderCheck() })
      #expect(f.manager.importStage == .scanningBackupFolder)
    } cleanup: {
      await f.close()
    }
  }

  @Test func managerIsImportingFlag() async {
    let f = ManagerFixture()
    await withCleanup {
      await assertPublishedParity(
        f.manager, \.isImporting, { $0.isImportingFlagOnlyPublisher },
        change: { f.manager.startImport() },
        unchangedWrite: .notDrivable(
          "set when an import starts and cleared once by the import that owns it"))
      #expect(f.manager.isImporting)
    } cleanup: {
      await f.close()
    }
  }

  /// AutoSync's import hold: `isImporting || previousBackupMissing`, without repeats.
  @Test func managerIsImportingHold() async {
    let f = ManagerFixture()
    await withCleanup {
      await assertPublishedParity(
        { f.manager.isImportingPublisher },
        value: { f.manager.isImporting || f.manager.previousBackupMissing },
        change: { f.manager.startImport() },
        // Stores `false` in `previousBackupMissing` again while the import keeps the hold.
        unchangedWrite: .after { f.manager.clearPreviousBackupMissing() },
        unchangedWriteDelivery: .isDropped)
    } cleanup: {
      await f.close()
    }
  }

  @Test func managerActiveRunContext() async {
    let f = ManagerFixture()
    await withCleanup {
      let context = ExportRunContext(
        source: .manual, visibility: .userVisible, scope: .timelineFullLibrary,
        selection: .edited)
      await assertPublishedParity(
        f.manager, \.activeRunContext, { $0.activeRunContextPublisher },
        change: { _ = await f.manager.runExport(context: context) },
        unchangedWrite: .notDrivable("set once when a run starts and cleared once when it ends"))
    } cleanup: {
      await f.close()
    }
  }

  @Test func managerIsEnqueueingAll() async {
    let f = ManagerFixture()
    await withCleanup {
      await assertPublishedParity(
        f.manager, \.isEnqueueingAll, { $0.isEnqueueingAllPublisher },
        change: { await f.manager.startExportAll()?.value },
        // Tearing down active work stores `false` unconditionally.
        unchangedWrite: .before { f.manager.cancelAndClear() })
    } cleanup: {
      await f.close()
    }
  }

  /// AutoSync's run-state contract: `CombineLatest4` over the run context, the running flag,
  /// the queue depth and the bulk-enqueue flag, without repeats.
  @Test func managerExportRunState() async {
    let f = ManagerFixture()
    await withCleanup {
      let manager = f.manager
      await assertPublishedParity(
        { manager.exportRunStatePublisher },
        value: {
          let context = manager.activeRunContext
          let manualFireAndForget =
            context == nil
            && (manager.isRunning || manager.queueCount > 0 || manager.isEnqueueingAll)
          return ExportRunState(
            activeContext: context,
            isManualActive: context?.source == .manual || manualFireAndForget,
            isAutoSyncActive: context?.source == .autoSync)
        },
        change: {
          manager.queueCoordinator.enqueue([
            .init(
              assetLocalIdentifier: "parity", placement: .timeline(year: 2001, month: 1),
              selection: .edited)
          ])
        },
        // Tearing down an idle queue rewrites every input with its current value.
        unchangedWrite: .before { manager.cancelAndClear() },
        unchangedWriteDelivery: .isDropped)
      #expect(manager.queueCount > 0 || manager.isRunning)
    } cleanup: {
      await f.close()
    }
  }

  // MARK: - ExportProgressState

  @Test func progressEmptyRunMessage() async {
    let progress = ExportProgressState()
    await assertPublishedParity(
      progress, \.emptyRunMessage, { $0.emptyRunMessagePublisher },
      change: { progress.emptyRunMessage = "Everything is already exported." },
      unchangedWrite: .before { progress.emptyRunMessage = progress.emptyRunMessage })
  }

  // MARK: - UserDefaultsAutoExportScopeStore

  @Test func scopeSelection() async {
    let store = UserDefaultsAutoExportScopeStore(
      userDefaults: TestScratch.defaults("ParityScopeSelection"))
    await assertPublishedParity(
      store, \.selection, { $0.scopeSelectionPublisher },
      change: { store.setSelection(AutoExportScopeSelection(timeline: true)) },
      unchangedWrite: .before { store.setSelection(store.selection) })
  }

  // MARK: - MonthViewModel

  @Test func monthSelectedAssetId() async {
    let model = MonthViewModel(photoLibraryService: FakePhotoLibraryService())
    await assertPublishedParity(
      model, \.selectedAssetId, { $0.selectedAssetIdPublisher },
      change: { model.selectedAssetId = "asset" },
      unchangedWrite: .before { model.selectedAssetId = model.selectedAssetId })
  }

  // MARK: - TimelineSidebarCounts

  @Test func sidebarCountsByYearMonth() async {
    let service = FakePhotoLibraryService()
    service.cachedCountOverride = { _, adjusted in adjusted ? 0 : 1 }
    let counts = TimelineSidebarCounts(service: service)
    await assertPublishedParity(
      counts, \.countsByYearMonth, { $0.countsByYearMonthPublisher },
      change: { await counts.loadCounts(forYears: [2025]) },
      // An identical refresh: month updates skip equal counts.
      unchangedWrite: .after { await counts.loadCounts(forYears: [2025]) },
      unchangedWriteDelivery: .isDropped)
    #expect(counts.assetCountsByYearMonth["2025-1"] == 1)
  }

  // MARK: - AutoSyncManager

  @Test func autoSyncLastRunSummary() async throws {
    let manager = AutoSyncManager()
    let builder = FakeAutoSyncEnvironmentBuilder()
    let destination = DestinationSnapshot(
      fingerprint: Self.fingerprint("A"), isAvailable: true, safety: .safe)
    let other = DestinationSnapshot(
      fingerprint: Self.fingerprint("B"), isAvailable: true, safety: .safe)
    let summary = ExportRunSummary(
      context: ExportRunContext(
        source: .autoSync, visibility: .background, reason: .appLaunch,
        scope: .autoExport(AutoExportScopeSelection(timeline: true)), selection: .edited),
      endedAt: Date(), enqueuedCount: 1, completedCount: 1, failedCount: 0, skippedCount: 0,
      cancelReason: nil, result: .completed)
    try builder.runSummaryStore.save(summary, destinationId: try #require(destination.id))
    try builder.runSummaryStore.save(summary, destinationId: try #require(other.id))
    manager.attach(to: builder.environment)
    await assertPublishedParity(
      manager, \.lastRunSummary, { $0.lastRunSummaryPublisher },
      change: { builder.destination.subject.send(destination) },
      // Switching to a destination whose stored summary is equal: `lastRunSummary != summary`
      // skips the write.
      unchangedWrite: .after { builder.destination.subject.send(other) },
      unchangedWriteDelivery: .isDropped)
    #expect(manager.lastRunSummary == summary)
  }

  // MARK: - Record stores

  @Test func timelineMutationCounter() async {
    let root = TestScratch.directory("ParityTimelineCounter")
    let store = ExportRecordStore(baseDirectoryURL: root, notificationClock: TestClock())
    store.configure(for: "A")
    await withCleanup {
      await assertPublishedParity(
        store, \.mutationCounter, { $0.mutationCounterPublisher },
        change: {
          store.markVariantExported(
            assetId: "parity", variant: .original, year: 2026, month: 1, relPath: "2026/01/",
            filename: "PARITY.JPG", exportedAt: Date())
          store.flushPendingNotifications()
        },
        // A counter, so no write stores an equal value. This pins the guard against an empty
        // flush (nothing pending publishes nothing), not delivery of an equal write.
        unchangedWrite: .after { store.flushPendingNotifications() },
        unchangedWriteDelivery: .isDropped)
    } cleanup: {
      try? await store.flush()
      try? FileManager.default.removeItem(at: root)
    }
  }

  @Test func collectionMutationCounter() async {
    let root = TestScratch.directory("ParityCollectionCounter")
    let store = CollectionExportRecordStore(baseDirectoryURL: root, notificationClock: TestClock())
    store.configure(for: "A")
    let placement = ExportPlacement.favorites()
    store.upsertPlacement(placement)
    store.flushPendingNotifications()
    await withCleanup {
      await assertPublishedParity(
        store, \.mutationCounter, { $0.mutationCounterPublisher },
        change: {
          store.markVariantInProgress(
            assetId: "parity", placement: placement, variant: .original, filename: "PARITY.JPG")
          store.flushPendingNotifications()
        },
        // A counter, so no write stores an equal value. This pins the guard against an empty
        // flush (nothing pending publishes nothing), not delivery of an equal write.
        unchangedWrite: .after { store.flushPendingNotifications() },
        unchangedWriteDelivery: .isDropped)
    } cleanup: {
      try? await store.flush()
      try? FileManager.default.removeItem(at: root)
    }
  }

  // MARK: - DestinationSnapshotAdapter

  /// AutoSync's destination contract: `CombineLatest4` over identity, availability, migration
  /// conflict and safety confirmation, without repeats.
  @Test func adapterDestinationSnapshot() async throws {
    let folder = try Self.folder("ParitySnapshot")
    let root = TestScratch.directory("ParitySnapshotRecords")
    let timeline = ExportRecordStore(baseDirectoryURL: root)
    let collections = CollectionExportRecordStore(baseDirectoryURL: root)
    timeline.configure(for: "A")
    collections.configure(for: "A")
    let manager = Self.destinationManager()
    manager.setSelectedFolderForTesting(folder)
    manager.revalidateForTesting()
    var result = ConfigureRecordStoresResult.success
    let lifecycle = AppLifecycleCoordinator(
      cancelActiveWork: {}, interruptForDestinationUnavailable: {},
      configureRecordStores: { _ in result })
    let confirmations = InMemoryDestinationSafetyConfirmationStore()
    let monitor = DestinationSafetyMonitor(
      identityPublisher: manager.identityPublisher,
      exportRecordStore: timeline, collectionExportRecordStore: collections,
      confirmationStore: confirmations, scanDirectory: { false })
    let adapter = DestinationSnapshotAdapter(
      destinationManager: manager, lifecycleCoordinator: lifecycle, safetyMonitor: monitor)
    await withCleanup {
      await assertPublishedParity(
        { adapter.destinationSnapshotPublisher },
        value: {
          let safety: DestinationSafetyState =
            lifecycle.migrationConflict != nil
            ? .unsafeMigrationConflict
            : monitor.needsSafetyConfirmation ? .unsafeNeedsConfirmation : .safe
          return DestinationSnapshot(
            stableId: manager.identity.stableId, fingerprint: manager.identity.fingerprint,
            isAvailable: manager.isAvailable, safety: safety)
        },
        change: {
          result = .migrationConflict(newId: "new", legacyId: "legacy")
          lifecycle.apply(destination: Self.snapshot("C"))
        },
        // Revalidating an unchanged folder stores the same availability again.
        unchangedWrite: .before { manager.revalidateForTesting() },
        unchangedWriteDelivery: .isDropped)
    } cleanup: {
      timeline.drainSynchronously()
      collections.drainSynchronously()
      try? FileManager.default.removeItem(at: folder)
      try? FileManager.default.removeItem(at: root)
    }
  }
}
