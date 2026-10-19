import AppKit
import SwiftUI
import Testing

@testable import Photo_Export

#if DEBUG
  @MainActor
  @Suite(.timeLimit(.minutes(2)), .serialized)
  struct RecordStoreAlertRecoveryTests {
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

      init(collection: Bool = false, storageFailure: Bool = false) throws {
        defaults = TestScratch.defaults(suiteName: defaultsName)
        let directory = root.appendingPathComponent("A")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name =
          collection
          ? CollectionExportRecordStore.Constants.snapshotFileName
          : ExportRecordStore.Constants.snapshotFileName
        if storageFailure {
          try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(name), withIntermediateDirectories: true)
        } else {
          try Data("corrupt tracking".utf8).write(to: directory.appendingPathComponent(name))
        }
        timeline = ExportRecordStore(baseDirectoryURL: root)
        collections = CollectionExportRecordStore(baseDirectoryURL: root)
        timeline.configure(for: "A")
        collections.configure(for: "A")
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
            .environmentObject(timeline).environmentObject(collections).environmentObject(manager)
            .environmentObject(destinationManager).environmentObject(photoManager)
            .environment(\.bodyInvalidationCounter, counter))
        let owned = NSWindow(
          contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 400),
          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        owned.isReleasedWhenClosed = false
        owned.contentView = hosted
        window = owned
        owned.orderFront(nil)
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
        timeline.flushForTesting()
        collections.flushForTesting()
        destination.cleanup()
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
      }
    }

    private func observe(
      _ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
      await eventually("observed condition", sourceLocation: sourceLocation) { condition() }
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
      let f = try Fixture()
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
      let f = try Fixture()
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
      #expect(f.timeline.state == .ready)
      #expect(f.manager.isImporting, "Reset must claim import before returning to the run loop")
      await f.manager.waitForImportCompletion()
      #expect(f.manager.importResult?.matchedCount == 1)
      #expect(f.timeline.exportInfo(assetId: asset.id)?.variants[.original]?.status == .done)
      #expect(f.collections.exportInfo(assetId: "keep", placement: favorites) == collectionBefore)
      let resultShown = await observe {
        f.counter.renderedText["import-title"] == ["Import Complete"]
      }
      #expect(resultShown, "The existing ImportView must actually present its result")
      f.timeline.flushForTesting()
      let reopened = ExportRecordStore(baseDirectoryURL: f.root)
      reopened.configure(for: "A")
      #expect(reopened.exportInfo(assetId: asset.id)?.variants[.original]?.status == .done)
      reopened.flushForTesting()
      f.manager.startExportMonth(year: 2026, month: 9)
      await f.manager.waitForQueueDrained()
      #expect(f.writer.writeCalls.isEmpty)
      #expect(try Data(contentsOf: file) == bytes)
      #expect(
        f.destination.openedScopeURLs.map(\.path).sorted()
          == f.destination.closedScopeURLs.map(\.path).sorted())
    }

    @Test func collectionResetWarnsAndLeavesTimelineAlone() async throws {
      let f = try Fixture(collection: true)
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
      #expect(f.collections.state == .ready)
      #expect(f.timeline.exportInfo(assetId: "keep") == before)
      #expect(!f.manager.isImporting)
    }

    enum Blocker: CaseIterable {
      case unauthorized, unavailable, collectionFailed, activeWork, healthyReplacement
    }

    @Test(arguments: Blocker.allCases)
    func retainedRebuildRechecksEligibility(blocker: Blocker) async throws {
      let f = try Fixture()
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
        f.collections.configure(for: "A")
      case .activeWork:
        f.manager.startExportAllAlbums()
        try #require(f.manager.hasActiveExportWork)
      case .healthyReplacement: f.timeline.configure(for: "B")
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
      let f = try Fixture()
      defer { f.close() }
      f.show()
      let button = try await rebuildButton(f)
      let directory = f.root.appendingPathComponent("A")
      try FileManager.default.moveItem(at: directory, to: f.root.appendingPathComponent("saved"))
      try Data("blocks record directory".utf8).write(to: directory)
      button.performClick(nil)
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
      let f = try Fixture(collection: collection, storageFailure: true)
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

  }

#endif
