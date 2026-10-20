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
      timeline.flushForTesting()
      collection.flushForTesting()
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
    try await runUnclearPick(chooseSame: true)
  }

  /// Control for the gate above: "New Folder" starts no import and Auto Export runs as usual.
  @Test func newFolderForUnclearPickRunsAutoExportWithoutAnImport() async throws {
    try await runUnclearPick(chooseSame: false)
  }

  /// Wires the real destination manager, lifecycle coordinator, snapshot adapter, export manager
  /// and AutoSync manager, then loses the destination and picks it again with an unclear answer.
  private func runUnclearPick(chooseSame: Bool) async throws {
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
        PhotoExportApp.configureRecordStores(
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
    PhotoExportApp.connectAmbiguousSameFolderImport(
      destinationManager: destinationManager, exportManager: exportManager)
    let autoSync = AutoSyncManager()
    defer {
      autoSync.setEnabled(false)
      exportManager.cancelAndClear()
      timelineStore.flushForTesting()
      collectionStore.flushForTesting()
      try? FileManager.default.removeItem(at: storeRoot)
      try? FileManager.default.removeItem(at: pickedDir)
      defaults.removePersistentDomain(forName: suite)
      dest.cleanup()
    }

    // History whose file is in the folder, so the check proceeds to a full import.
    let dir = try dest.urlForRelativeDirectory("2025/03/", createIfNeeded: true)
    try Data("x".utf8).write(to: dir.appendingPathComponent("A.HEIC"))
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
      builder.clock.advance(by: 60)
      for _ in 0..<5 { await Task.yield() }
      #expect(builder.exportRunner.receivedContexts.count == 1)
      #expect(autoSync.state == .waiting(.importActive))
      await gate.releaseAll()
      await exportManager.waitForImportCompletion()
      #expect(!exportManager.previousBackupMissing)
    } else {
      #expect(!exportManager.isImporting)
    }

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
}
