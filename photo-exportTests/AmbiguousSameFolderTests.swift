import Combine
import Foundation
import Testing

@testable import Photo_Export

/// Choosing "Same Folder" for a pick the app couldn't compare with the previous destination runs
/// Import Existing Backup, so the export history is checked against the folder before anything is
/// exported (#334). A folder that holds none of the history's files keeps the history untouched.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct AmbiguousSameFolderTests {

  private static func lowConfidence(_ path: String) -> DestinationFingerprint {
    .makeLow(volumeRootPath: nil, relativePathFromVolumeRoot: path, standardizedPath: path)
  }

  // MARK: - Selection

  enum Pick: String, CaseIterable, Sendable {
    case unclearSame, unclearNew, sameAsStored, differentFromStored, firstSelection
    case unclearSameBookmarkFails, unclearSameFolderUnavailable
  }

  /// Only an unclear pick answered "Same Folder", saved and available, asks for the history check.
  @Test(arguments: Pick.allCases)
  func onlyAnUnclearSameFolderPickAsksForTheHistoryCheck(pick: Pick) throws {
    let dir = TestScratch.directory("UnclearPick")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let suite = TestScratch.suiteName("UnclearPick")
    let defaults = TestScratch.defaults(suiteName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }

    let evidence: ExportDestinationManager.SameFolderEvidence =
      switch pick {
      case .unclearSame, .unclearNew, .unclearSameBookmarkFails, .unclearSameFolderUnavailable:
        .ambiguous
      case .sameAsStored: .sameAsStored
      case .differentFromStored: .differentFromStored
      case .firstSelection: .noStoredBookmark
      }
    var saves = true
    var fingerprint: DestinationFingerprint? = Self.lowConfidence("/Volumes/A/backup")
    let manager = ExportDestinationManager(
      skipRestore: true, userDefaults: defaults,
      bookmarkDefaultsKey: "Bookmark-\(UUID().uuidString)",
      stableIdDefaultsKey: "StableId-\(UUID().uuidString)",
      fingerprintProvider: { _ in fingerprint },
      sameFolderEvidenceProvider: { _ in evidence },
      ambiguityResolver: { _ in pick == .unclearNew ? .newDestination : .sameDestination },
      bookmarkSaver: { _ in saves },
      validationScopeAcquirer: { _ in true }, validationScopeReleaser: { _ in })
    manager.persistSelectedFolderForTesting(dir)
    let seeded = try #require(manager.destinationId)

    var requests: [(id: String?, available: Bool)] = []
    manager.onAmbiguousSameFolderChosen = {
      requests.append((manager.destinationId, manager.isAvailable))
    }
    if pick == .unclearSameBookmarkFails { saves = false }
    if pick == .unclearSameFolderUnavailable { fingerprint = nil }
    manager.selectFolderForTesting(dir)

    if pick == .unclearSame {
      // Called once, after the selection applied: same stable id, folder available.
      #expect(requests.count == 1)
      #expect(requests.first?.id == seeded)
      #expect(requests.first?.available == true)
    } else {
      #expect(requests.isEmpty)
    }
  }

  @Test func promptExplainsWhyItAsksAndDefaultsToSameFolder() {
    let prompt = AmbiguousFolderPrompt(folderName: "Backup 2025")
    #expect(prompt.title == "Is this your previous backup folder?")
    #expect(prompt.message.contains("\u{201C}Backup 2025\u{201D}"))
    #expect(prompt.message.contains("can't reach the folder you used before"))
    #expect(prompt.buttons == ["Same Folder", "New Folder"])
    #expect(prompt.decision(forButtonAt: 0) == .sameDestination)
    #expect(prompt.decision(forButtonAt: 1) == .newDestination)
  }

  // MARK: - History check

  @MainActor
  private struct Harness {
    let manager: ExportManager
    let dest: FakeExportDestination
    let timeline: ExportRecordStore
    let collection: CollectionExportRecordStore
    let storeRoot: URL

    func plant(_ relPath: String, _ filename: String) throws {
      let dir = try dest.urlForRelativeDirectory(relPath, createIfNeeded: true)
      try Data("x".utf8).write(to: dir.appendingPathComponent(filename))
    }

    func cleanup() {
      manager.cancelAndClear()
      timeline.drainSynchronously()
      collection.drainSynchronously()
      try? FileManager.default.removeItem(at: storeRoot)
      dest.cleanup()
    }
  }

  private static let italy = ExportPlacement(
    kind: .album, id: "collections:album:abc:def", displayName: "Italy",
    collectionLocalIdentifier: "album-1", relativePath: "Collections/Albums/Italy/",
    createdAt: Date(timeIntervalSince1970: 1_700_000_000))

  private func makeHarness(configureTimeline: Bool = true) -> Harness {
    let dest = FakeExportDestination()
    let storeRoot = TestScratch.directory("UnclearPickImport")
    let timeline = ExportRecordStore(baseDirectoryURL: storeRoot)
    if configureTimeline { timeline.configure(for: "test") }
    let collection = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    collection.configure(for: "test")
    let manager = ExportManager(
      photoLibraryService: FakePhotoLibraryService(), exportDestination: dest,
      exportRecordStore: timeline, collectionExportRecordStore: collection,
      assetResourceWriter: FakeAssetResourceWriter(), fileSystem: FakeFileSystem(),
      userDefaults: TestScratch.defaults("UnclearPickImport"))
    return Harness(
      manager: manager, dest: dest, timeline: timeline, collection: collection,
      storeRoot: storeRoot)
  }

  private func seedHistory(_ h: Harness) {
    h.timeline.markVariantExported(
      assetId: "asset-A", variant: .original, year: 2025, month: 3,
      relPath: "2025/03/", filename: "A.HEIC", exportedAt: Date())
    h.timeline.markVariantExported(
      assetId: "asset-B", variant: .original, year: 2025, month: 3,
      relPath: "2025/03/", filename: "B.HEIC", exportedAt: Date())
    h.collection.upsertPlacement(Self.italy)
    h.collection.markVariantExported(
      assetId: "asset-C", placement: Self.italy, variant: .original,
      filename: "C.HEIC", exportedAt: Date())
  }

  /// A folder that holds none of the history's files is not the previous backup: nothing is
  /// pruned, and the import says so instead of reporting a completed import.
  @Test func folderWithoutAnyOfTheHistoryKeepsItUntouched() async throws {
    let h = makeHarness()
    defer { h.cleanup() }
    seedHistory(h)

    h.manager.startImportForConfirmedSameFolder()
    await h.manager.waitForImportCompletion()

    #expect(h.manager.previousBackupMissing)
    #expect(h.manager.importResult == nil)
    #expect(h.manager.importError == nil)
    #expect(Set(h.timeline.recordsById.keys) == ["asset-A", "asset-B"])
    #expect(
      h.collection.recordBodies[Self.italy.id]?["asset-C"]?.variants["original"]?.status == .done)
  }

  /// When some of the history is there, the import runs as usual and prunes only what's missing,
  /// in both stores.
  @Test func folderWithPartOfTheHistoryPrunesOnlyWhatIsMissing() async throws {
    let h = makeHarness()
    defer { h.cleanup() }
    seedHistory(h)
    try h.plant("2025/03/", "A.HEIC")

    h.manager.startImportForConfirmedSameFolder()
    await h.manager.waitForImportCompletion()

    #expect(!h.manager.previousBackupMissing)
    #expect(Set(h.timeline.recordsById.keys) == ["asset-A"])
    #expect(h.collection.recordBodies[Self.italy.id]?["asset-C"] == nil)
    #expect(h.manager.importResult?.prunedVariants == 2)
  }

  /// Album history alone is evidence: a collections-only user's folder is recognized.
  @Test func albumHistoryAloneIsEnoughEvidence() async throws {
    let h = makeHarness()
    defer { h.cleanup() }
    h.collection.upsertPlacement(Self.italy)
    h.collection.markVariantExported(
      assetId: "asset-C", placement: Self.italy, variant: .original,
      filename: "C.HEIC", exportedAt: Date())
    h.collection.markVariantExported(
      assetId: "asset-D", placement: Self.italy, variant: .original,
      filename: "D.HEIC", exportedAt: Date())
    try h.plant(Self.italy.relativePath, "C.HEIC")

    h.manager.startImportForConfirmedSameFolder()
    await h.manager.waitForImportCompletion()

    #expect(!h.manager.previousBackupMissing)
    #expect(h.collection.recordBodies[Self.italy.id]?["asset-C"] != nil)
    #expect(h.collection.recordBodies[Self.italy.id]?["asset-D"] == nil)
  }

  /// With no history there is nothing to protect, so the import runs normally.
  @Test func emptyHistoryImportsNormally() async throws {
    let h = makeHarness()
    defer { h.cleanup() }

    h.manager.startImportForConfirmedSameFolder()
    await h.manager.waitForImportCompletion()

    #expect(!h.manager.previousBackupMissing)
    #expect(h.manager.importResult?.totalScanned == 0)
  }

  /// A check that can't start says why, instead of silently doing nothing; a plain import keeps
  /// its quiet refusal.
  @Test func refusedCheckExplainsWhyAndKeepsHistory() async throws {
    let h = makeHarness(configureTimeline: false)
    defer { h.cleanup() }

    h.manager.startImport()
    #expect(h.manager.importError == nil)

    let requestsBefore = h.manager.importSheetRequest
    h.manager.startImportForConfirmedSameFolder()
    #expect(!h.manager.isImporting)
    #expect(h.manager.importError?.contains("Your export history was kept") == true)
    #expect(h.manager.importSheetRequest != requestsBefore)
  }

  // MARK: - Auto Export waits for the check

  /// Choosing "Same Folder" for an unclear pick makes the destination available and starts the
  /// history check in the same turn: Auto Export must wait while the check runs, then run once.
  @Test func sameFolderForUnclearPickHoldsAutoExportUntilHistoryCheckEnds() async throws {
    try await runUnclearPick(.sameFolder)
  }

  /// Control for the gate above: "New Folder" starts no import and Auto Export runs as usual.
  @Test func newFolderForUnclearPickRunsAutoExportWithoutAnImport() async throws {
    try await runUnclearPick(.newFolder)
  }

  /// "Same Folder" on a folder without any of the history's files: nothing runs while the user
  /// decides. Choosing another folder keeps the history (the stored bookmark now points at the
  /// rejected folder, so a plain pick would read as a different folder and start an empty one),
  /// checks it again, and then Auto Export runs once.
  @Test func missingPreviousBackupHoldsAutoExportAndRepickKeepsHistory() async throws {
    try await runUnclearPick(.sameFolderOnWrongFolder)
  }

  enum UnclearPickScenario { case sameFolder, newFolder, sameFolderOnWrongFolder }

  /// Wires the real destination manager, lifecycle coordinator, snapshot adapter, export manager
  /// and AutoSync manager, then loses the destination and picks it again with an unclear answer.
  /// The export manager reads and writes a `FakeExportDestination`; the destination manager only
  /// drives the identity, as the picked folder's contents don't matter to the ordering.
  private func runUnclearPick(_ scenario: UnclearPickScenario) async throws {
    let chooseSame = scenario != .newFolder
    let pickedDir = TestScratch.directory("UnclearPickWired")
    try FileManager.default.createDirectory(at: pickedDir, withIntermediateDirectories: true)
    let storeRoot = TestScratch.directory("UnclearPickWiredRecords")
    let suite = TestScratch.suiteName("UnclearPickWired")
    let defaults = TestScratch.defaults(suiteName: suite)
    let dest = FakeExportDestination()

    var fingerprint: DestinationFingerprint? = Self.lowConfidence("/Volumes/A/backup")
    let destinationManager = ExportDestinationManager(
      skipRestore: true, userDefaults: defaults,
      bookmarkDefaultsKey: "Bookmark-\(UUID().uuidString)",
      stableIdDefaultsKey: "StableId-\(UUID().uuidString)",
      fingerprintProvider: { _ in fingerprint },
      sameFolderEvidenceProvider: { _ in .ambiguous },
      ambiguityResolver: { _ in chooseSame ? .sameDestination : .newDestination },
      bookmarkSaver: { _ in true },
      validationScopeAcquirer: { _ in true }, validationScopeReleaser: { _ in })
    destinationManager.persistSelectedFolderForTesting(pickedDir)
    let stableId = try #require(destinationManager.destinationId)

    let checker = GatedReconciliationFileChecker()
    let timelineStore = ExportRecordStore(
      baseDirectoryURL: storeRoot, reconciliationFileChecker: checker)
    let collectionStore = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    let lifecycle = AppLifecycleCoordinator(
      cancelActiveWork: {}, interruptForDestinationUnavailable: {},
      configureRecordStores: { newId in
        AppCore.configureRecordStores(
          for: newId, destinationManager: destinationManager,
          timelineStore: timelineStore, collectionStore: collectionStore)
      })
    let confirmations = InMemoryDestinationSafetyConfirmationStore()
    try confirmations.confirm(destinationId: stableId)
    let safetyMonitor = DestinationSafetyMonitor(
      identityPublisher: destinationManager.$identity.eraseToAnyPublisher(),
      exportRecordStore: timelineStore, collectionExportRecordStore: collectionStore,
      confirmationStore: confirmations, scanDirectory: { @MainActor in false })
    let adapter = DestinationSnapshotAdapter(
      destinationManager: destinationManager, lifecycleCoordinator: lifecycle,
      safetyMonitor: safetyMonitor)
    lifecycle.attach(
      initial: DestinationIdentitySnapshot(identity: destinationManager.identity),
      identityPublisher: destinationManager.$identity.eraseToAnyPublisher())
    safetyMonitor.attach()

    let builder = FakeAutoSyncEnvironmentBuilder()
    let exportManager = ExportManager(
      photoLibraryService: FakePhotoLibraryService(), exportDestination: dest,
      exportRecordStore: timelineStore, collectionExportRecordStore: collectionStore,
      assetResourceWriter: FakeAssetResourceWriter(), fileSystem: FakeFileSystem(),
      userDefaults: builder.userDefaults)
    AppCore.connectAmbiguousSameFolderImport(
      destinationManager: destinationManager, exportManager: exportManager,
      hasMigrationConflict: { lifecycle.migrationConflict != nil })
    let autoSync = AutoSyncManager()
    defer {
      autoSync.setEnabled(false)
      exportManager.cancelAndClear()
      timelineStore.drainSynchronously()
      collectionStore.drainSynchronously()
      try? FileManager.default.removeItem(at: storeRoot)
      try? FileManager.default.removeItem(at: pickedDir)
      defaults.removePersistentDomain(forName: suite)
      dest.cleanup()
    }

    // The lifecycle coordinator starts reading the destination's history off the main actor,
    // and a store still loading takes no writes, so the history is seeded once it has loaded.
    await timelineStore.waitUntilSettled()
    await collectionStore.waitUntilSettled()
    try #require(timelineStore.state == .ready)

    // History whose file is in the folder, so the check proceeds to a full import. On the
    // wrong folder the file only appears once the user has chosen the right one.
    let dir = try dest.urlForRelativeDirectory("2025/03/", createIfNeeded: true)
    let backupFile = dir.appendingPathComponent("A.HEIC")
    if scenario != .sameFolderOnWrongFolder { try Data("x".utf8).write(to: backupFile) }
    timelineStore.markVariantExported(
      assetId: "asset-A", variant: .original, year: 2025, month: 3,
      relPath: "2025/03/", filename: "A.HEIC", exportedAt: Date())

    builder.userDefaults.set(true, forKey: AutoSyncManager.enabledDefaultsKey)
    builder.scopes.subject.send(AutoExportScopeSelection(timeline: true))
    autoSync.attach(
      to: AutoSyncEnvironment(
        exportRunner: builder.exportRunner, destination: adapter, scopes: builder.scopes,
        photos: builder.photos, importing: exportManager, dirtyStateStore: builder.dirtyStore,
        retryStateStore: builder.retryStore, runSummaryStore: builder.runSummaryStore,
        perDestinationTokenStore: builder.perDestinationTokenStore,
        currentRunStore: builder.currentRunStore, clock: builder.clock,
        photosAuthorization: builder.photosAuthorization,
        userDefaults: builder.userDefaults))
    let runner = builder.exportRunner
    func runFinished(_ count: Int) -> Bool {
      guard runner.receivedContexts.count == count else { return false }
      if case .running = autoSync.state { return false }
      return true
    }

    // Let the launch run finish, then lose the destination (a disconnected drive).
    builder.clock.advance(by: AutoSyncReducer.debounceDelay(for: .appLaunch))
    #expect(await eventually("launch run") { runFinished(1) })
    fingerprint = nil
    destinationManager.revalidateForTesting()
    #expect(destinationManager.identity == .unavailable)
    #expect(
      await eventually("AutoSync sees no destination") {
        switch autoSync.state {
        case .blocked, .waiting: return true
        default: return false
        }
      })

    // Hold the history check at its first file probe, then pick the folder again.
    let gate = AsyncCheckpoint()
    await checker.suspendNextProbe(at: gate)
    fingerprint = Self.lowConfidence("/Volumes/B/backup")
    destinationManager.selectFolderForTesting(pickedDir)

    if chooseSame {
      #expect(exportManager.isImporting)
      #expect(autoSync.state == .waiting(.importActive))
      await gate.waitForEnter(count: 1)
      #expect(builder.clock.pendingCount == 0)  // nothing scheduled while the check runs
      builder.clock.advance(by: 60)
      #expect(runner.receivedContexts.count == 1)
      #expect(autoSync.state == .waiting(.importActive))
      await gate.releaseAll()
      await exportManager.waitForImportCompletion()
    } else {
      #expect(!exportManager.isImporting)
    }

    if scenario == .sameFolderOnWrongFolder {
      // Nothing was pruned, and nothing runs while the user decides.
      #expect(exportManager.previousBackupMissing)
      #expect(timelineStore.recordsById["asset-A"] != nil)
      #expect(autoSync.state == .waiting(.importActive))
      #expect(builder.clock.pendingCount == 0)
      builder.clock.advance(by: 60)
      #expect(runner.receivedContexts.count == 1)

      // The user chooses the folder that has the backup. The hold has no gap while the check
      // starts over.
      try Data("x".utf8).write(to: backupFile)
      var held: [Bool] = []
      let heldSink = exportManager.isImportingPublisher.sink { held.append($0) }
      defer { heldSink.cancel() }
      #expect(destinationManager.selectFolderKeepingHistoryForTesting(pickedDir))
      #expect(destinationManager.destinationId == stableId)
      #expect(exportManager.isImporting)
      #expect(held == [true])
      #expect(builder.clock.pendingCount == 0)
      await exportManager.waitForImportCompletion()
      #expect(held == [true, false])
    }
    #expect(!exportManager.previousBackupMissing)

    // Once nothing is in the way, exactly one run follows.
    #expect(
      await eventually("run scheduled after the pick") {
        if case .scheduled = autoSync.state { return true }
        return false
      })
    builder.clock.advance(by: 60)
    #expect(await eventually("run after the pick") { runFinished(2) })
    let reasons = runner.receivedContexts.map(\.reason)
    #expect(reasons.count == 2)
    #expect([.destinationSelected, .destinationBecameAvailable].contains(reasons.last))
  }

  // MARK: - Deciding after "previous backup missing"

  private func makeSelectionManager(
    fingerprint: @escaping () -> DestinationFingerprint?, saves: @escaping () -> Bool
  ) throws -> (manager: ExportDestinationManager, dir: URL, cleanup: () -> Void) {
    let dir = TestScratch.directory("UseAsNew")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let suite = TestScratch.suiteName("UseAsNew")
    let defaults = TestScratch.defaults(suiteName: suite)
    let manager = ExportDestinationManager(
      skipRestore: true, userDefaults: defaults,
      bookmarkDefaultsKey: "Bookmark-\(UUID().uuidString)",
      stableIdDefaultsKey: "StableId-\(UUID().uuidString)",
      fingerprintProvider: { _ in fingerprint() }, bookmarkSaver: { _ in saves() },
      validationScopeAcquirer: { _ in true }, validationScopeReleaser: { _ in })
    return (
      manager, dir,
      {
        try? FileManager.default.removeItem(at: dir)
        defaults.removePersistentDomain(forName: suite)
      }
    )
  }

  enum NewFolderCase: CaseIterable, Sendable { case differentIdentity, sameIdentity, notSaved }

  /// "Use as New Folder" reports what happened: a fresh history, a folder whose identity is the
  /// history's own (so no new history can start), or an unsaved bookmark that changed nothing.
  @Test(arguments: NewFolderCase.allCases)
  func useAsNewFolderReportsWhetherAFreshHistoryStarted(_ newFolder: NewFolderCase) throws {
    var fingerprint = Self.lowConfidence("/Volumes/A/backup")
    var saves = true
    let (manager, dir, cleanup) = try makeSelectionManager(
      fingerprint: { fingerprint }, saves: { saves })
    defer { cleanup() }
    manager.persistSelectedFolderForTesting(dir)
    let seeded = try #require(manager.destinationId)

    switch newFolder {
    case .differentIdentity: fingerprint = Self.lowConfidence("/Volumes/B/backup")
    case .sameIdentity: break
    case .notSaved: saves = false
    }
    let outcome = manager.useSelectedFolderAsNewDestination()

    switch newFolder {
    case .differentIdentity:
      #expect(outcome == .newHistory)
      #expect(manager.destinationId != seeded)
    case .sameIdentity:
      #expect(outcome == .sameIdentity)
      #expect(manager.destinationId == seeded)
    case .notSaved:
      #expect(outcome == .notSaved)
      #expect(manager.destinationId == seeded)
    }
  }

  /// While the user decides, AutoSync sees an import in progress and manual exports are refused;
  /// a destination change ends the wait.
  @Test func missingPreviousBackupHoldsExportsUntilTheDestinationChanges() async throws {
    let h = makeHarness()
    defer { h.cleanup() }
    seedHistory(h)
    var held: [Bool] = []
    let cancellable = h.manager.isImportingPublisher.sink { held.append($0) }
    defer { cancellable.cancel() }

    h.manager.startImportForConfirmedSameFolder()
    await h.manager.waitForImportCompletion()
    #expect(h.manager.previousBackupMissing)
    #expect(!h.manager.isImporting)
    #expect(held == [false, true])

    #expect(h.manager.startExportAll() == nil)  // refused while the user decides

    h.manager.cancelAndClear()
    #expect(!h.manager.previousBackupMissing)
    #expect(held == [false, true, false])
  }

  /// Cancelling while the check is still looking leaves the history and the flag untouched.
  @Test func cancellingDuringTheCheckKeepsHistory() async throws {
    let checker = GatedReconciliationFileChecker()
    let dest = FakeExportDestination()
    let storeRoot = TestScratch.directory("UnclearPickCancel")
    let timeline = ExportRecordStore(
      baseDirectoryURL: storeRoot, reconciliationFileChecker: checker)
    timeline.configure(for: "test")
    let collection = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    collection.configure(for: "test")
    let manager = ExportManager(
      photoLibraryService: FakePhotoLibraryService(), exportDestination: dest,
      exportRecordStore: timeline, collectionExportRecordStore: collection,
      assetResourceWriter: FakeAssetResourceWriter(), fileSystem: FakeFileSystem(),
      userDefaults: TestScratch.defaults("UnclearPickCancel"))
    let h = Harness(
      manager: manager, dest: dest, timeline: timeline, collection: collection,
      storeRoot: storeRoot)
    defer { h.cleanup() }
    seedHistory(h)
    let gate = AsyncCheckpoint()
    await checker.suspendNextProbe(at: gate)

    manager.startImportForConfirmedSameFolder()
    await gate.waitForEnter(count: 1)
    manager.cancelImport()
    await gate.releaseAll()
    await manager.waitForImportCompletion()

    #expect(!manager.isImporting)
    #expect(!manager.previousBackupMissing)
    #expect(manager.importResult == nil)
    #expect(Set(timeline.recordsById.keys) == ["asset-A", "asset-B"])
    #expect(collection.recordBodies[Self.italy.id]?["asset-C"] != nil)
  }

  /// Album history that can't be read doesn't count as evidence either way: missing timeline
  /// history still keeps everything untouched.
  @Test func unreadableAlbumHistoryDoesNotMaskAMissingBackup() async throws {
    let h = makeHarness()
    defer { h.cleanup() }
    h.timeline.markVariantExported(
      assetId: "asset-A", variant: .original, year: 2025, month: 3,
      relPath: "2025/03/", filename: "A.HEIC", exportedAt: Date())
    h.collection.configure(for: nil)

    h.manager.startImportForConfirmedSameFolder()
    await h.manager.waitForImportCompletion()

    #expect(h.manager.previousBackupMissing)
    #expect(h.timeline.recordsById["asset-A"] != nil)
  }

  /// While a migration conflict is open its recovery owns the records, so no check starts.
  @Test func noCheckWhileAMigrationConflictIsOpen() {
    let h = makeHarness()
    defer { h.cleanup() }
    let suite = TestScratch.suiteName("UnclearPickConflict")
    let defaults = TestScratch.defaults(suiteName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let destinationManager = ExportDestinationManager(skipRestore: true, userDefaults: defaults)
    var conflict = true
    AppCore.connectAmbiguousSameFolderImport(
      destinationManager: destinationManager, exportManager: h.manager,
      hasMigrationConflict: { conflict })

    destinationManager.onAmbiguousSameFolderChosen?()
    #expect(!h.manager.isImporting)
    #expect(h.manager.importSheetRequest == nil)

    conflict = false
    destinationManager.onAmbiguousSameFolderChosen?()
    #expect(h.manager.importSheetRequest != nil)
  }

  /// After "Use as New Folder", the export manager ends the wait only when something changed;
  /// on the history's own folder it makes the history match the folder without a gap in the hold.
  @Test(arguments: NewFolderCase.allCases)
  func continuingAfterUseAsNewFolderEndsTheWaitOnlyWhenSomethingChanged(
    _ newFolder: NewFolderCase
  ) async throws {
    let h = makeHarness()
    defer { h.cleanup() }
    seedHistory(h)
    h.manager.startImportForConfirmedSameFolder()
    await h.manager.waitForImportCompletion()
    #expect(h.manager.previousBackupMissing)
    var held: [Bool] = []
    let cancellable = h.manager.isImportingPublisher.sink { held.append($0) }
    defer { cancellable.cancel() }

    let outcome: ExportDestinationManager.NewDestinationOutcome =
      switch newFolder {
      case .differentIdentity: .newHistory
      case .sameIdentity: .sameIdentity
      case .notSaved: .notSaved
      }
    let message = h.manager.continueAfterUsingFolderAsNew(outcome)

    switch newFolder {
    case .differentIdentity:
      #expect(message == nil)
      #expect(!h.manager.previousBackupMissing)
      #expect(held == [true, false])
    case .sameIdentity:
      #expect(message == nil)
      #expect(h.manager.isImporting)
      #expect(!h.manager.previousBackupMissing)
      #expect(held == [true])
      await h.manager.waitForImportCompletion()
      #expect(h.timeline.recordsById.isEmpty)  // the folder holds none of them
      #expect(held == [true, false])
    case .notSaved:
      #expect(message?.contains("couldn\u{2019}t save access") == true)
      #expect(h.manager.previousBackupMissing)
      #expect(held == [true])
    }
  }

  /// A check refused because an export is running says so.
  @Test func checkRefusedDuringAnExportSaysWhy() async throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let year = Calendar.current.component(.year, from: date)
    let month = Calendar.current.component(.month, from: date)
    let asset = TestAssetFactory.makeAsset(id: "asset-busy", creationDate: date)
    let library = FakePhotoLibraryService()
    library.yearCounts = [(year: year, count: 1)]
    library.assetsByYearMonth["\(year)-\(month)"] = [asset]
    library.resourcesByAssetId[asset.id] = [
      TestAssetFactory.makeResource(originalFilename: "busy.jpg")
    ]
    let writer = FakeAssetResourceWriter()
    let gate = AsyncCheckpoint()
    writer.checkpoint = gate
    let dest = FakeExportDestination()
    let storeRoot = TestScratch.directory("UnclearPickBusy")
    let timeline = ExportRecordStore(baseDirectoryURL: storeRoot)
    timeline.configure(for: "test")
    let collection = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    collection.configure(for: "test")
    let manager = ExportManager(
      photoLibraryService: library, exportDestination: dest,
      exportRecordStore: timeline, collectionExportRecordStore: collection,
      assetResourceWriter: writer, fileSystem: FakeFileSystem(),
      userDefaults: TestScratch.defaults("UnclearPickBusy"))
    defer {
      manager.cancelAndClear()
      timeline.drainSynchronously()
      collection.drainSynchronously()
      try? FileManager.default.removeItem(at: storeRoot)
      dest.cleanup()
    }

    manager.startExportAll()
    await gate.waitForEnter(count: 1)
    manager.startImportForConfirmedSameFolder()

    #expect(!manager.isImporting)
    #expect(manager.importError?.contains("while an export is running") == true)
    await gate.releaseAll()
  }
}
