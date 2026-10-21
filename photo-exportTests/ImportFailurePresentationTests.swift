import AppKit
import Combine
import SwiftUI
import Testing

@testable import Photo_Export

#if DEBUG
  @MainActor
  @Suite(.serialized)
  struct ImportFailurePresentationTests {
    enum History: CaseIterable { case timeline, collection }

    private final class FailingLogIO: JSONLRecordLogIO, @unchecked Sendable {
      private let lock = NSLock()
      private var armed = false
      private let production = ProductionJSONLRecordLogIO()
      func arm(_ value: Bool) { lock.withLock { armed = value } }
      func readIfPresent(at url: URL) throws -> Data? { try production.readIfPresent(at: url) }
      func openForAppending(at url: URL) throws -> FileHandle {
        try production.openForAppending(at: url)
      }
      func write(_ data: Data, to handle: FileHandle) throws {
        if lock.withLock({ armed }) { throw CocoaError(.fileWriteOutOfSpace) }
        try production.write(data, to: handle)
      }
      func synchronize(_ handle: FileHandle) throws { try production.synchronize(handle) }
    }

    @MainActor
    private final class Fixture {
      let photos = FakePhotoLibraryService()
      let destination = FakeExportDestination()
      let io = FailingLogIO()
      let checker = GatedReconciliationFileChecker()
      let timeline: ExportRecordStore
      let collections: CollectionExportRecordStore
      let manager: ExportManager
      let destinationManager: ExportDestinationManager
      let counter = BodyInvalidationCounter()
      let root = TestScratch.directory("ImportFailurePresentation")
      let defaultsName = TestScratch.suiteName("ImportFailure")
      let defaults: UserDefaults
      let favorites = ExportPlacement.favorites()
      var window: NSWindow?
      var hosted: NSView?
      static let hostHeight: CGFloat = 600

      init(fault: History? = nil) {
        defaults = TestScratch.defaults(suiteName: defaultsName)
        timeline = ExportRecordStore(
          baseDirectoryURL: root, reconciliationFileChecker: checker,
          recordLogIO: fault == .timeline ? io : ProductionJSONLRecordLogIO())
        collections = CollectionExportRecordStore(
          baseDirectoryURL: root, reconciliationFileChecker: checker,
          recordLogIO: fault == .collection ? io : ProductionJSONLRecordLogIO())
        timeline.configure(for: "A")
        collections.configure(for: "A")
        manager = ExportManager(
          photoLibraryService: photos, exportDestination: destination,
          exportRecordStore: timeline, collectionExportRecordStore: collections,
          assetResourceWriter: FakeAssetResourceWriter(), fileSystem: FakeFileSystem(),
          userDefaults: defaults)
        destinationManager = ExportDestinationManager(skipRestore: true, userDefaults: defaults)
        destinationManager.configureForScreenshotMode()
      }

      func seedHistory() async throws {
        timeline.markExported(
          assetId: "history", year: 2026, month: 9, relPath: "2026/09/",
          filename: "HISTORY.JPG", exportedAt: Date(timeIntervalSince1970: 100))
        collections.upsertPlacement(favorites)
        collections.markVariantExported(
          assetId: "history", placement: favorites, variant: .original,
          filename: "HISTORY.JPG", exportedAt: Date(timeIntervalSince1970: 100))
        try await timeline.flush()
        try await collections.flush()
      }

      func plantMatch() throws {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 15))!
        let asset = TestAssetFactory.makeAsset(id: "matched", creationDate: date)
        photos.assetsByYearMonth["2026-9"] = [asset]
        photos.resourcesByAssetId[asset.id] = [
          TestAssetFactory.makeResource(originalFilename: "FILE.JPG")
        ]
        let folder = try destination.urlForMonth(year: 2026, month: 9, createIfNeeded: true)
        let file = folder.appendingPathComponent("FILE.JPG")
        try Data("photo".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
      }

      func show() {
        let hosted = NSHostingView(
          rootView: ImportView()
            .environmentObject(manager).environmentObject(timeline).environmentObject(collections)
            .environmentObject(destinationManager).environment(\.bodyInvalidationCounter, counter))
        let hostWindow = NSWindow(
          contentRect: NSRect(x: -10000, y: -10000, width: 460, height: Self.hostHeight),
          styleMask: [.borderless], backing: .buffered, defer: false)
        hostWindow.isReleasedWhenClosed = false
        hostWindow.contentView = hosted
        window = hostWindow
        self.hosted = hosted
        hostWindow.orderFront(nil)
      }

      func close() {
        manager.cancelImport()
        window?.orderOut(nil)
        window?.contentView = nil
        window?.close()
        window = nil
        hosted = nil
        counter.reset()
        io.arm(false)
        timeline.flushForTesting()
        collections.flushForTesting()
        destination.cleanup()
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
      }
    }

    private func reached(_ gate: AsyncCheckpoint) async -> Bool {
      await gate.waitForEnter(count: 1)
    }
    private func shows(_ title: String, in f: Fixture) async -> Bool {
      let shown = await observe { f.counter.renderedText["import-title"] == [title] }
      #expect(shown)
      return shown
    }

    /// The result lists album and Favorites files matched and album folders no current album
    /// was matched to, and says when the album history couldn't be rebuilt.
    @Test(.timeLimit(.minutes(2)))
    func resultShowsAlbumAndFavoritesRows() async throws {
      let f = Fixture()
      defer { f.close() }
      f.show()
      f.manager.importResult = ImportReport(
        matchedCount: 1, ambiguousCount: 0, unmatchedCount: 0, totalScanned: 1,
        collectionFilesScanned: 4, collectionMatchedCount: 3,
        unrecognizedCollectionFolders: ["Collections/Albums/Trips/Old/", "Collections/Favorites/"])
      #expect(await observe { f.counter.renderedText["import-collection-matched"] == ["3"] })
      #expect(f.counter.renderedText["import-collection-unrecognized"] == ["2"])
      #expect(
        f.counter.renderedText["import-collection-unrecognized-caption"]?.first?.hasPrefix(
          "\u{201C}Trips/Old\u{201D}, \u{201C}Favorites\u{201D}. These are usually albums renamed")
          == true)
      #expect(f.counter.renderedText["import-collections-skipped"] == nil)

      f.counter.reset()
      f.manager.importResult = ImportReport(
        matchedCount: 1, ambiguousCount: 0, unmatchedCount: 0, totalScanned: 1,
        collectionFilesScanned: 2, collectionsSkipped: true)
      #expect(await observe { f.counter.renderedText["import-collections-skipped"] != nil })
      #expect(f.counter.renderedText["import-collection-unrecognized"] == nil)
    }

    @Test(.timeLimit(.minutes(2)))
    func rootFailureIsTerminalPreservesHistoryAndCanRetry() async throws {
      let f = Fixture()
      defer { f.close() }
      var started = false
      var terminal: (error: String?, stage: BackupScanner.ImportStage?, report: ImportReport?)?
      let subscription = f.manager.$isImporting.sink { active in
        if active {
          started = true
        } else if started {
          terminal = (f.manager.importError, f.manager.importStage, f.manager.importResult)
        }
      }
      defer { subscription.cancel() }
      try await f.seedHistory()
      let timelineBefore = f.timeline.exportInfo(assetId: "history")
      let collectionBefore = f.collections.exportInfo(assetId: "history", placement: f.favorites)
      f.destination.selectedFolderURL = f.destination.rootURL.appendingPathComponent("missing")
      f.show()
      f.manager.startImport()
      await f.manager.waitForImportCompletion()
      #expect(
        !f.manager.isImporting && f.manager.importStage == nil && f.manager.importResult == nil)
      #expect(f.manager.importError?.isEmpty == false)
      #expect(terminal?.error == f.manager.importError && terminal?.error != nil)
      #expect(terminal?.stage == nil && terminal?.report == nil)
      #expect(f.timeline.exportInfo(assetId: "history") == timelineBefore)
      #expect(
        f.collections.exportInfo(assetId: "history", placement: f.favorites) == collectionBefore)
      let reopenedTimeline = ExportRecordStore(baseDirectoryURL: f.root)
      let reopenedCollections = CollectionExportRecordStore(baseDirectoryURL: f.root)
      reopenedTimeline.configure(for: "A")
      reopenedCollections.configure(for: "A")
      #expect(reopenedTimeline.exportInfo(assetId: "history") == timelineBefore)
      #expect(
        reopenedCollections.exportInfo(assetId: "history", placement: f.favorites)
          == collectionBefore)
      reopenedTimeline.flushForTesting()
      reopenedCollections.flushForTesting()
      guard await shows("Import Failed", in: f) else { return }
      #expect(f.counter.renderedText["import-progress"] == ["false"])
      let importError = try #require(f.manager.importError)
      #expect(f.counter.renderedText["import-message"] == [importError])
      #expect(f.counter.renderedActions["import-close"] != nil)
      let failure = f.manager.importError
      f.timeline.configure(for: nil)
      f.manager.startImport()  // Rejected start must preserve the failure.
      #expect(f.manager.importError == failure)
      let blocked = await observe { f.counter.renderedText["import-can-retry"] == ["false"] }
      try #require(blocked)
      let rejectedRetry = try #require(f.counter.renderedActions["import-retry"])
      rejectedRetry()
      #expect(!f.manager.isImporting && f.manager.importError == failure)
      f.timeline.configure(for: "A")
      f.destinationManager.clearSelection()
      let disconnected = await observe { f.counter.renderedText["import-can-retry"] == ["false"] }
      try #require(disconnected)
      f.destinationManager.configureForScreenshotMode()
      f.destination.selectedFolderURL = f.destination.rootURL
      let eligible = await observe { f.counter.renderedText["import-can-retry"] == ["true"] }
      try #require(eligible)
      let retry = try #require(f.counter.renderedActions["import-retry"])
      retry()
      #expect(f.manager.isImporting)
      #expect(f.manager.importError == nil, "An accepted retry clears failure synchronously")
      await f.manager.waitForImportCompletion()
      #expect(f.manager.importError == nil && f.manager.importResult != nil)
      #expect(terminal?.error == nil && terminal?.stage == .done)
      #expect(terminal?.report == f.manager.importResult)
      _ = await shows("Import Complete", in: f)
      #expect(
        f.destination.openedScopeURLs.map(\.path).sorted()
          == f.destination.closedScopeURLs.map(\.path).sorted())
    }

    /// A failure already showing at the first layout must render whole.
    @Test(.timeLimit(.minutes(1)))
    func failureViewRendersWhenItIsTheFirstLayout() async throws {
      let f = Fixture()
      defer { f.close() }
      f.destination.selectedFolderURL = f.destination.rootURL.appendingPathComponent("missing")
      f.manager.startImport()
      await f.manager.waitForImportCompletion()
      let importError = try #require(f.manager.importError)
      f.show()
      guard await shows("Import Failed", in: f) else { return }
      let window = try #require(f.window)
      let hosted = try #require(f.hosted)
      // Wait for the display cycle that fits the window to the view, so teardown can't pre-empt
      // the layout pass this test is about.
      let fitted = await observe { window.frame.height < Fixture.hostHeight }
      try #require(fitted)
      #expect(window.contentLayoutRect.height >= hosted.fittingSize.height)
      #expect(f.counter.renderedText["import-message"] == [importError])
      #expect(f.counter.renderedText["import-recovery"]?.first?.isEmpty == false)
      #expect(f.counter.renderedText["import-progress"] == ["false"])
      #expect(f.counter.renderedActions["import-close"] != nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func deniedScopeStopsProgressWithoutClosingAnUnopenedScope() async throws {
      let f = Fixture()
      defer { f.close() }
      f.destination.scopedAccessAvailable = false
      f.show()
      f.manager.startImport()
      await f.manager.waitForImportCompletion()
      #expect(!f.manager.isImporting && f.manager.importStage == nil)
      #expect(f.manager.importError?.isEmpty == false)
      #expect(f.destination.beginScopedAccessCount == 1)
      #expect(f.destination.endScopedAccessCount == 0 && f.destination.openedScopeURLs.isEmpty)
      guard await shows("Import Failed", in: f) else { return }
      #expect(f.counter.renderedText["import-progress"] == ["false"])
      #expect(f.counter.renderedText["import-recovery"]?.first?.isEmpty == false)
    }

    @Test(.timeLimit(.minutes(2)), arguments: History.allCases)
    func failedHistoryWriteRequiresRecoveryBeforeRetry(history: History) async throws {
      let f = Fixture(fault: history)
      defer { f.close() }
      try await f.seedHistory()
      try f.plantMatch()
      f.io.arm(true)
      f.show()
      f.manager.startImport()
      await f.manager.waitForImportCompletion()
      #expect(!f.manager.isImporting && f.manager.importResult == nil)
      #expect(f.manager.importError?.isEmpty == false)
      #expect((history == .timeline ? f.timeline.state : f.collections.state) == .persistenceFailed)
      guard await shows("Import Failed", in: f) else { return }
      let blocked = await observe { f.counter.renderedText["import-can-retry"] == ["false"] }
      try #require(blocked)
      #expect(f.counter.renderedText["import-recovery"]?.first?.contains("history") == true)
      let failure = f.manager.importError
      let blockedRetry = try #require(f.counter.renderedActions["import-retry"])
      blockedRetry()
      #expect(!f.manager.isImporting && f.manager.importError == failure)
      f.io.arm(false)
      if history == .timeline {
        f.timeline.retryPersistence()
      } else {
        f.collections.retryPersistence()
      }
      let eligible = await observe { f.counter.renderedText["import-can-retry"] == ["true"] }
      try #require(eligible)
      let retry = try #require(f.counter.renderedActions["import-retry"])
      retry()
      #expect(f.manager.isImporting && f.manager.importError == nil)
      await f.manager.waitForImportCompletion()
      #expect(f.manager.importResult?.matchedCount == 1)
      #expect(f.manager.importError == nil)
      _ = await shows("Import Complete", in: f)
      #expect(
        f.destination.openedScopeURLs.map(\.path).sorted()
          == f.destination.closedScopeURLs.map(\.path).sorted())
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func generationInvalidationBeforeTaskEntrySettlesActivity(unavailable: Bool) async throws {
      let f = Fixture()
      defer { f.close() }
      f.manager.startImport()
      let old = try #require(f.manager.importTask)
      if unavailable {
        f.manager.interruptForDestinationUnavailable()
      } else {
        f.manager.cancelAndClear()
      }
      #expect(!old.isCancelled)
      await old.value
      #expect(!f.manager.isImporting)
      #expect(f.manager.importStage == nil)
      #expect(f.manager.importError == nil && f.manager.importResult == nil)
      #expect(f.destination.beginScopedAccessCount == 0)
    }

    @Test(.timeLimit(.minutes(2)))
    func oldMatchingTaskCannotReplaceNewFailure() async throws {
      let f = Fixture()
      let gate = AsyncCheckpoint()
      var imports: [Task<Void, Never>] = []
      try await withCleanup {
        try f.plantMatch()
        f.photos.fetchAssetsCheckpointByYear[2026] = gate
        f.manager.startImport()
        let old = try #require(f.manager.importTask)
        imports.append(old)
        let matching = await reached(gate)
        try #require(matching)
        f.manager.cancelImport()
        f.photos.fetchAssetsCheckpointByYear[2026] = nil
        f.destination.selectedFolderURL = f.destination.rootURL.appendingPathComponent("missing")
        f.manager.startImport()
        let current = try #require(f.manager.importTask)
        imports.append(current)
        await current.value
        #expect(f.manager.importError?.isEmpty == false)
        let failure = f.manager.importError
        await gate.releaseAll()
        await old.value
        #expect(old.isCancelled)
        #expect(f.manager.importError == failure)
        #expect(
          !f.manager.isImporting && f.manager.importStage == nil && f.manager.importResult == nil)
        #expect(
          f.destination.openedScopeURLs.map(\.path).sorted()
            == f.destination.closedScopeURLs.map(\.path).sorted())
      } cleanup: {
        await gate.releaseAll()
        if let current = f.manager.importTask { imports.append(current) }
        for task in imports { _ = await finished(task) }
        f.close()
      }
    }

    @Test(.timeLimit(.minutes(2)), arguments: [false, true])
    func generationOnlyInterruptionDuringMatchingSettlesWithoutFailure(unavailable: Bool)
      async throws
    {
      let f = Fixture()
      let gate = AsyncCheckpoint()
      var imports: [Task<Void, Never>] = []
      try await withCleanup {
        try f.plantMatch()
        f.photos.fetchAssetsCheckpointByYear[2026] = gate
        f.show()
        f.manager.startImport()
        let old = try #require(f.manager.importTask)
        imports.append(old)
        let matching = await reached(gate)
        try #require(matching)
        if unavailable {
          f.manager.interruptForDestinationUnavailable()
        } else {
          f.manager.cancelAndClear()
        }
        #expect(!old.isCancelled)
        var lateStages: [BackupScanner.ImportStage?] = []
        let subscription = f.manager.$importStage.dropFirst().sink { lateStages.append($0) }
        defer { subscription.cancel() }
        await gate.releaseAll()
        await old.value
        #expect(
          lateStages.allSatisfy { $0 == nil },
          "Invalidated matching must publish no transient stale progress")
        #expect(!f.manager.isImporting && f.manager.importStage == nil)
        #expect(f.manager.importError == nil && f.manager.importResult == nil)
        _ = await shows("Import Stopped", in: f)
        #expect(
          f.destination.openedScopeURLs.map(\.path).sorted()
            == f.destination.closedScopeURLs.map(\.path).sorted())
      } cleanup: {
        await gate.releaseAll()
        if let current = f.manager.importTask { imports.append(current) }
        for task in imports { _ = await finished(task) }
        f.close()
      }
    }

    @Test(.timeLimit(.minutes(2)))
    func idleRejectedStartAndCancelStayCloseableWithoutFailure() async throws {
      let f = Fixture()
      let gate = AsyncCheckpoint()
      var imports: [Task<Void, Never>] = []
      try await withCleanup {
        f.timeline.configure(for: nil)
        f.show()
        f.manager.startImport()
        #expect(!f.manager.isImporting && f.manager.importError == nil)
        guard await shows("Import Stopped", in: f) else { return }
        #expect(f.counter.renderedText["import-progress"] == ["false"])
        #expect(f.counter.renderedActions["import-close"] != nil)
        f.timeline.configure(for: "A")
        try f.plantMatch()
        f.photos.fetchAssetsCheckpointByYear[2026] = gate
        f.manager.startImport()
        let old = try #require(f.manager.importTask)
        imports.append(old)
        let matching = await reached(gate)
        try #require(matching)
        let shown = await shows("Importing Existing Backup", in: f)
        try #require(shown)
        let cancel = try #require(f.counter.renderedActions["import-cancel"])
        cancel()
        #expect(
          !f.manager.isImporting && f.manager.importError == nil && f.manager.importResult == nil)
        await gate.releaseAll()
        await old.value
        #expect(old.isCancelled)
        _ = await shows("Import Stopped", in: f)
      } cleanup: {
        await gate.releaseAll()
        if let current = f.manager.importTask { imports.append(current) }
        for task in imports { _ = await finished(task) }
        f.close()
      }
    }

  }
#endif
