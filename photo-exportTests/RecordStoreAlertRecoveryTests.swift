import AppKit
import SwiftUI
import Testing

@testable import Photo_Export

#if DEBUG
  @MainActor
  @Suite(.timeLimit(.minutes(2)), .serialized)
  struct RecordStoreAlertRecoveryTests {
    private final class FaultIO: JSONLRecordLogIO, @unchecked Sendable {
      private let lock = NSLock()
      private var readFault: Error?
      private var writeFault: Error?
      private var reads = 0
      var readCount: Int { lock.withLock { reads } }
      private let real = ProductionJSONLRecordLogIO()
      func failReads(_ error: Error) { lock.withLock { readFault = error } }
      func failWrites(_ error: Error) { lock.withLock { writeFault = error } }
      func readIfPresent(at url: URL) throws -> Data? {
        lock.withLock { reads += 1 }
        if let error = lock.withLock({ readFault }) { throw error }
        return try real.readIfPresent(at: url)
      }
      func openForAppending(at url: URL) throws -> FileHandle { try real.openForAppending(at: url) }
      func write(_ data: Data, to handle: FileHandle) throws {
        if let error = lock.withLock({ writeFault }) { throw error }
        try real.write(data, to: handle)
      }
      func synchronize(_ handle: FileHandle) throws { try real.synchronize(handle) }
    }

    @MainActor
    private final class Tick: ObservableObject {
      @Published var value = 0
    }

    private struct RenderProbe: View {
      @ObservedObject var tick: Tick
      let counter: BodyInvalidationCounter
      var body: some View {
        // swiftlint:disable:next redundant_discardable_let
        let _ = counter.record("alert-render-tick:\(tick.value)")
        Color.clear.frame(width: 1, height: 1)
      }
    }

    @MainActor
    private final class Fixture {
      let root = TestScratch.directory("RecordStoreAlertRecovery")
      let defaultsName = TestScratch.suiteName("AlertRecovery")
      let defaults: UserDefaults
      let timeline: ExportRecordStore
      let collections: CollectionExportRecordStore
      let photos = FakePhotoLibraryService()
      let destination = FakeExportDestination()
      let writer = FakeAssetResourceWriter()
      let manager: ExportManager
      let destinationManager: ExportDestinationManager
      let photoManager: PhotoLibraryManager
      let counter = BodyInvalidationCounter()
      var window: NSWindow?
      let tick = Tick()

      init(
        collection: Bool = false, storageFailure: Bool = false, ready: Bool = false,
        recordLogIO: any JSONLRecordLogIO = ProductionJSONLRecordLogIO()
      ) async throws {
        defaults = TestScratch.defaults(suiteName: defaultsName)
        let directory = root.appendingPathComponent("A")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name =
          collection
          ? CollectionExportRecordStore.Constants.snapshotFileName
          : ExportRecordStore.Constants.snapshotFileName
        if !ready, storageFailure {
          try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(name), withIntermediateDirectories: true)
        } else if !ready {
          try Data("corrupt tracking".utf8).write(to: directory.appendingPathComponent(name))
        }
        timeline = ExportRecordStore(baseDirectoryURL: root, recordLogIO: recordLogIO)
        collections = CollectionExportRecordStore(baseDirectoryURL: root, recordLogIO: recordLogIO)
        await timeline.configureAndWait(for: "A")
        await collections.configureAndWait(for: "A")
        if ready {
          collections.upsertPlacement(.favorites())
          collections.flushPendingNotifications()
          collections.drainSynchronously()
        }
        manager = ExportManager(
          photoLibraryService: photos, exportDestination: destination,
          exportRecordStore: timeline, collectionExportRecordStore: collections,
          assetResourceWriter: writer, fileSystem: FakeFileSystem(), userDefaults: defaults)
        destinationManager = ExportDestinationManager(skipRestore: true, userDefaults: defaults)
        destinationManager.configureForScreenshotMode()
        photoManager = PhotoLibraryManager(overrideService: photos)
      }

      func show() {
        let hosted = NSHostingView(
          rootView: Color.clear.frame(width: 600, height: 400)
            .recordStoreAlertHost()
            .overlay(alignment: .topLeading) { RenderProbe(tick: tick, counter: counter) }
            .environment(timeline).environment(collections).environment(manager)
            .environmentObject(destinationManager).environment(photoManager)
            .environment(\.bodyInvalidationCounter, counter))
        let owned = NSWindow(
          contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 400),
          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        owned.isReleasedWhenClosed = false
        owned.contentView = hosted
        window = owned
        owned.orderFront(nil)
      }

      func barrier() async throws {
        tick.value += 1
        let key = "alert-render-tick:\(tick.value)"
        try #require(await observe(in: window) { counter.count(for: key) > 0 })
        window?.contentView?.layoutSubtreeIfNeeded()
      }

      func state(_ collection: Bool) -> RecordStoreState {
        collection ? collections.state : timeline.state
      }
      func error(_ collection: Bool) -> String? {
        collection ? collections.persistenceError : timeline.persistenceError
      }
      func configure(_ id: String, collection: Bool) async {
        if collection {
          await collections.configureAndWait(for: id)
        } else {
          await timeline.configureAndWait(for: id)
        }
      }
      func write(_ collection: Bool) {
        if collection {
          collections.markVariantInProgress(
            assetId: "new", placement: .favorites(), variant: .original, filename: "NEW.JPG")
        } else {
          timeline.markVariantInProgress(
            assetId: "new", variant: .original, year: 2026, month: 9,
            relPath: "2026/09/", filename: "NEW.JPG")
        }
      }

      func close() {
        manager.cancelImport()
        manager.cancelAndClear()
        window?.contentView = nil
        if let sheet = window?.attachedSheet {
          window?.endSheet(sheet)
          sheet.close()
        }
        window?.close()
        window = nil
        counter.reset()
        timeline.drainSynchronously()
        collections.drainSynchronously()
        destination.cleanup()
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
      }
    }

    private func descendants(_ view: NSView) -> [NSView] {
      [view] + view.subviews.flatMap(descendants)
    }

    private func alertViews(_ f: Fixture) async throws -> [NSView] {
      let presented = await observe { f.window?.attachedSheet != nil }
      try #require(presented, "The owned recovery alert must appear")
      return descendants(try #require(f.window?.attachedSheet?.contentView))
    }

    private func rebuildButton(_ f: Fixture) async throws -> NSButton {
      try #require(
        try await alertViews(f).compactMap { $0 as? NSButton }.first {
          $0.title == "Reset and Rebuild from Folder…"
        })
    }

    @Test func timelineAlertWarnsAndOffersRebuild() async throws {
      let f = try await Fixture()
      defer { f.close() }
      f.show()
      let presented = await observe { f.window?.attachedSheet != nil }
      try #require(presented, "The owned recovery alert must appear")
      let content = try #require(f.window?.attachedSheet?.contentView)
      let views = descendants(content)
      let text = views.compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: " ")
      #expect(text.contains("duplicate"), "Actual recovery alert text: \(text)")
      #expect(text.contains("Import Existing Backup"), "Actual recovery alert text: \(text)")
      let buttons = views.compactMap { $0 as? NSButton }
      #expect(
        buttons.contains { $0.title == "Reset and Rebuild from Folder…" },
        "Actual alert buttons: \(buttons.map(\.title))")
    }
    @Test func rebuildImportsCurrentFolderWithoutReexportingOrResettingCollections() async throws {
      let f = try await Fixture()
      defer { f.close() }
      let date = try #require(
        Calendar.current.date(
          from: DateComponents(
            year: 2026, month: 9, day: 15, hour: 12)))
      let asset = TestAssetFactory.makeAsset(id: "recovered", creationDate: date)
      f.photos.assetsByYearMonth["2026-9"] = [asset]
      f.photos.resourcesByAssetId[asset.id] = [
        TestAssetFactory.makeResource(originalFilename: "RECOVER.JPG")
      ]
      let folder = try f.destination.urlForMonth(year: 2026, month: 9, createIfNeeded: true)
      let file = folder.appendingPathComponent("RECOVER.JPG")
      let bytes = Data("already backed up".utf8)
      try bytes.write(to: file)
      try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
      let favorites = ExportPlacement.favorites()
      f.collections.upsertPlacement(favorites)
      let collectionFolder = try f.destination.urlForRelativeDirectory(
        favorites.relativePath, createIfNeeded: true)
      try bytes.write(to: collectionFolder.appendingPathComponent("KEEP.JPG"))
      f.collections.markVariantExported(
        assetId: "keep", placement: favorites, variant: .original, filename: "KEEP.JPG",
        exportedAt: Date(timeIntervalSince1970: 100))
      let collectionBefore = f.collections.exportInfo(assetId: "keep", placement: favorites)
      f.show()
      let button = try await rebuildButton(f)
      #expect(button.isEnabled)
      button.performClick(nil)
      try #require(await observe { f.timeline.state == .ready })
      #expect(
        f.manager.isImporting, "Reset must claim import in the turn that publishes ready history")
      await f.manager.waitForImportCompletion()
      #expect(f.manager.importResult?.matchedCount == 1)
      #expect(f.timeline.exportInfo(assetId: asset.id)?.variants[.original]?.status == .done)
      #expect(f.collections.exportInfo(assetId: "keep", placement: favorites) == collectionBefore)
      let resultShown = await observe {
        f.counter.renderedText["import-title"] == ["Import Complete"]
      }
      #expect(resultShown, "The existing ImportView must actually present its result")
      f.timeline.drainSynchronously()
      let reopened = ExportRecordStore(baseDirectoryURL: f.root)
      await reopened.configureAndWait(for: "A")
      #expect(reopened.exportInfo(assetId: asset.id)?.variants[.original]?.status == .done)
      reopened.drainSynchronously()
      f.manager.startExportMonth(year: 2026, month: 9)
      await f.manager.waitForQueueDrained()
      #expect(f.writer.writeCalls.isEmpty)
      #expect(try Data(contentsOf: file) == bytes)
      #expect(
        f.destination.openedScopeURLs.map(\.path).sorted()
          == f.destination.closedScopeURLs.map(\.path).sorted())
    }

    @Test func collectionResetWarnsAndLeavesTimelineAlone() async throws {
      let f = try await Fixture(collection: true)
      defer { f.close() }
      f.timeline.markExported(
        assetId: "keep", year: 2026, month: 9, relPath: "2026/09/", filename: "KEEP.JPG",
        exportedAt: Date(timeIntervalSince1970: 100))
      let before = f.timeline.exportInfo(assetId: "keep")
      f.show()
      let views = try await alertViews(f)
      let text = views.compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: " ")
      #expect(text.contains("duplicate"))
      #expect(text.contains("cannot be rebuilt from disk"))
      let buttons = views.compactMap { $0 as? NSButton }
      #expect(!buttons.contains { $0.title.contains("Rebuild") })
      let reset = try #require(buttons.first { $0.title == "Reset Records" })
      reset.performClick(nil)
      try #require(await observe { f.collections.state == .ready })
      #expect(f.timeline.exportInfo(assetId: "keep") == before)
      #expect(!f.manager.isImporting)
    }

    enum Blocker: CaseIterable {
      case unauthorized, unavailable, collectionFailed, activeWork, healthyReplacement
    }

    @Test(arguments: Blocker.allCases)
    func retainedRebuildRechecksEligibility(blocker: Blocker) async throws {
      let f = try await Fixture()
      defer { f.close() }
      f.show()
      let button = try await rebuildButton(f)
      #expect(button.isEnabled)
      switch blocker {
      case .unauthorized: f.photoManager.isAuthorized = false
      case .unavailable: f.destinationManager.clearSelection()
      case .collectionFailed:
        try Data("corrupt collection".utf8).write(
          to: f.root.appendingPathComponent("A")
            .appendingPathComponent(CollectionExportRecordStore.Constants.snapshotFileName))
        await f.collections.configureAndWait(for: "A")
      case .activeWork:
        f.manager.startExportAllAlbums()
        try #require(f.manager.hasActiveExportWork)
      case .healthyReplacement: await f.timeline.configureAndWait(for: "B")
      }
      button.performClick(nil)  // The old enabled control invokes the real, retained action.
      #expect(!f.manager.isImporting)
      #expect(f.manager.importResult == nil)
      #expect(f.timeline.state == (blocker == .healthyReplacement ? .ready : .failed))
      #expect(
        try Data(
          contentsOf: f.root.appendingPathComponent("A")
            .appendingPathComponent(ExportRecordStore.Constants.snapshotFileName))
          == Data("corrupt tracking".utf8))
      if blocker == .activeWork { await f.manager.waitForQueueDrained() }
    }

    @Test func failedResetDoesNotImportOrPresentSheet() async throws {
      let f = try await Fixture()
      defer { f.close() }
      f.show()
      let button = try await rebuildButton(f)
      let directory = f.root.appendingPathComponent("A")
      try FileManager.default.moveItem(at: directory, to: f.root.appendingPathComponent("saved"))
      try Data("blocks record directory".utf8).write(to: directory)
      let completedResets = f.timeline.finishedResetCount
      button.performClick(nil)
      try #require(await observe { f.timeline.finishedResetCount > completedResets })
      #expect(f.timeline.state == .failed)
      #expect(!f.manager.isImporting && f.manager.importTask == nil)
      #expect(f.counter.renderedText["import-title"] == nil)
      #expect(f.destination.openedScopeURLs.isEmpty)
      #expect(
        try Data(
          contentsOf: f.root.appendingPathComponent("saved")
            .appendingPathComponent(ExportRecordStore.Constants.snapshotFileName))
          == Data("corrupt tracking".utf8))
    }

    @Test(arguments: [false, true])
    func storageFailureOffersRetryWithoutReset(collection: Bool) async throws {
      let f = try await Fixture(collection: collection, storageFailure: true)
      defer { f.close() }
      #expect((collection ? f.collections.state : f.timeline.state) == .persistenceFailed)
      f.show()
      let views = try await alertViews(f)
      let text = views.compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: " ")
      #expect(text.contains("Retry"))
      #expect(text.contains("preserve your history"))
      let titles = views.compactMap { ($0 as? NSButton)?.title }
      #expect(titles.contains("Retry"))
      #expect(!titles.contains { $0.contains("Reset") })
      #expect(!f.manager.isImporting)
    }

    /// Passes before: failures after mounting a ready host present the real recovery alert.
    @Test(arguments: [false, true], [false, true])
    func failureAfterMountPresentsRecoveryAlert(collection: Bool, writeFailure: Bool) async throws {
      let io = FaultIO()
      let f = try await Fixture(ready: true, recordLogIO: io)
      defer { f.close() }
      #expect(f.state(collection) == .ready)
      f.show()
      try await f.barrier()
      #expect(f.window?.attachedSheet == nil)
      if writeFailure {
        io.failWrites(CocoaError(.fileWriteOutOfSpace))
        f.write(collection)
        try #require(await observe(in: f.window) { f.state(collection) == .persistenceFailed })
      } else {
        let directory = f.root.appendingPathComponent("Corrupt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name =
          collection
          ? CollectionExportRecordStore.Constants.snapshotFileName
          : ExportRecordStore.Constants.snapshotFileName
        try Data("corrupt tracking".utf8).write(to: directory.appendingPathComponent(name))
        await f.configure("Corrupt", collection: collection)
        #expect(f.state(collection) == .failed)
      }
      let views = try await alertViews(f)
      let titles = views.compactMap { ($0 as? NSButton)?.title }
      #expect(writeFailure ? titles.contains("Retry") : titles.contains("Reset Records"))
    }

    @Test(arguments: [false, true])
    func retryFindingCorruptionPresentsReset(collection: Bool) async throws {
      let f = try await Fixture(collection: collection, storageFailure: true)
      defer { f.close() }
      #expect(f.state(collection) == .persistenceFailed)
      f.show()
      let retry = try #require(
        try await alertViews(f).compactMap { $0 as? NSButton }.first { $0.title == "Retry" })
      let name =
        collection
        ? CollectionExportRecordStore.Constants.snapshotFileName
        : ExportRecordStore.Constants.snapshotFileName
      let snapshot = f.root.appendingPathComponent("A").appendingPathComponent(name)
      try FileManager.default.removeItem(at: snapshot)
      let corrupt = Data("corrupt after storage repair".utf8)
      try corrupt.write(to: snapshot)
      let ended = "retry-corrupt-sheet-ended"
      let token = NotificationCenter.default.addObserver(
        forName: NSWindow.didEndSheetNotification, object: f.window, queue: .main
      ) { _ in MainActor.assumeIsolated { f.counter.record(ended) } }
      defer { NotificationCenter.default.removeObserver(token) }
      retry.performClick(nil)
      try #require(await observe { f.state(collection) == .failed })
      try #require(await observe(in: f.window) { f.counter.count(for: ended) > 0 })
      try await f.barrier()
      let titles = try await alertViews(f).compactMap { $0 as? NSButton }.map(\.title)
      #expect(titles.contains("Reset Records"))
      #expect(!titles.contains("Retry"))
      #expect(try Data(contentsOf: snapshot) == corrupt)
    }

    @Test func dismissedTimelineDoesNotHideCollectionRecovery() async throws {
      let f = try await Fixture(storageFailure: true)
      defer { f.close() }
      f.show()
      let retry = try #require(
        try await alertViews(f).compactMap { $0 as? NSButton }.first { $0.title == "Retry" })
      let before = f.timeline.finishedLoadCount
      retry.performClick(nil)
      try #require(await observe { f.timeline.finishedLoadCount > before })
      try await f.barrier()
      #expect(f.timeline.state == .persistenceFailed)
      let snapshot = f.root.appendingPathComponent("A").appendingPathComponent(
        CollectionExportRecordStore.Constants.snapshotFileName)
      let corrupt = Data("corrupt collections".utf8)
      try corrupt.write(to: snapshot)
      await f.configure("A", collection: true)
      #expect(f.collections.state == .failed)
      let views = try await alertViews(f)
      let titles = views.compactMap { $0 as? NSButton }.map(\.title)
      #expect(titles.contains("Reset Records"))
      #expect(!titles.contains("Retry"))
      let message = views.compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: " ")
      #expect(message.contains("Favorites and album"))
      #expect(try Data(contentsOf: snapshot) == corrupt)
    }

    /// Passes before: after a failed retry and native dismissal, the storage alert remains dismissed.
    @Test(arguments: [false, true], [false, true])
    func failedRetryKeepsTheStorageAlert(collection: Bool, writeFailure: Bool) async throws {
      let io = FaultIO()
      let f = try await Fixture(ready: true, recordLogIO: io)
      defer { f.close() }
      f.show()
      try await f.barrier()
      var retrySnapshot: URL?
      if writeFailure {
        let name =
          collection
          ? CollectionExportRecordStore.Constants.snapshotFileName
          : ExportRecordStore.Constants.snapshotFileName
        let blocked = f.root.appendingPathComponent("A").appendingPathComponent(name)
        let temporary = blocked.appendingPathExtension("tmp")
        retrySnapshot = temporary
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try Data("replacement probe".utf8).write(to: temporary)
        var failure: Error?
        do {
          try FileIOService().replaceItemAtomically(from: temporary, to: blocked)
        } catch { failure = error }
        try FileManager.default.removeItem(at: temporary)
        io.failWrites(try #require(failure))
        f.write(collection)
        try #require(await observe(in: f.window) { f.state(collection) == .persistenceFailed })
      } else {
        io.failReads(CocoaError(.fileReadNoPermission))
        await f.configure("A", collection: collection)
      }
      let originalError = try #require(f.error(collection))
      let views = try await alertViews(f)
      let button = try #require(views.compactMap { $0 as? NSButton }.first { $0.title == "Retry" })
      let ended = "retry-sheet-ended"
      let token = NotificationCenter.default.addObserver(
        forName: NSWindow.didEndSheetNotification, object: f.window, queue: .main
      ) { _ in MainActor.assumeIsolated { f.counter.record(ended) } }
      defer { NotificationCenter.default.removeObserver(token) }
      let readsBeforeRetry = io.readCount
      let loadsBeforeRetry =
        collection ? f.collections.finishedLoadCount : f.timeline.finishedLoadCount
      if let retrySnapshot { #expect(!FileManager.default.fileExists(atPath: retrySnapshot.path)) }
      button.performClick(nil)
      if let retrySnapshot {
        let attemptedSnapshot = await observe {
          FileManager.default.fileExists(atPath: retrySnapshot.path)
        }
        #expect(attemptedSnapshot, "Retry must prepare a new snapshot before replacement fails")
        if attemptedSnapshot {
          let data = try Data(contentsOf: retrySnapshot)
          let decoder = JSONDecoder()
          decoder.dateDecodingStrategy = .iso8601
          if collection {
            let snapshot = try decoder.decode(CollectionExportRecordStore.Snapshot.self, from: data)
            #expect(
              snapshot.records[ExportPlacement.favorites().id]?["new"]?.variants["original"]?.status
                == .inProgress)
          } else {
            let snapshot = try decoder.decode([String: ExportRecord].self, from: data)
            #expect(snapshot["new"]?.variants[.original]?.status == .inProgress)
          }
        }
      } else {
        #expect(
          await observe {
            io.readCount > readsBeforeRetry
              && (collection ? f.collections.finishedLoadCount : f.timeline.finishedLoadCount)
                > loadsBeforeRetry
          },
          "Retry must attempt to read the failed store again")
      }
      try #require(await observe { f.state(collection) == .persistenceFailed })
      #expect(f.error(collection) == originalError)
      try #require(await observe(in: f.window) { f.counter.count(for: ended) > 0 })
      try await f.barrier()
      let attached = f.window?.attachedSheet != nil
      #expect(!attached)
    }

  }

#endif
