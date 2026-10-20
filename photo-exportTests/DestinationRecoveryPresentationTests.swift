import AppKit
import SwiftUI
import Testing

@testable import Photo_Export

#if DEBUG
  @MainActor
  @Suite(.timeLimit(.minutes(2)), .serialized)
  struct DestinationRecoveryPresentationTests {
    enum Surface: CaseIterable { case root, month, year, collection, folder }
    enum Problem: CaseIterable { case unreachable, permission }

    @MainActor
    private final class Scope {
      var allowed = true
      var saveAllowed = true
    }

    @MainActor
    private final class Fixture {
      let root = TestScratch.directory("DestinationRecoveryPresentation")
      let suite = TestScratch.suiteName("DestinationRecovery")
      let defaults: UserDefaults
      let scope: Scope
      let destination: ExportDestinationManager
      let service = FakePhotoLibraryService()
      let library: PhotoLibraryManager
      let timeline: ExportRecordStore
      let collections: CollectionExportRecordStore
      let fakeDestination = FakeExportDestination()
      let manager: ExportManager
      let autoSync = AutoSyncManager()
      let whatsNew: WhatsNewState
      let counter = BodyInvalidationCounter()
      var window: NSWindow?
      var folder: URL { root.appendingPathComponent("Backup") }

      init(restoreFailure: Bool = false) throws {
        defaults = TestScratch.defaults(suiteName: suite)
        if restoreFailure {
          defaults.set(Data("bad bookmark".utf8), forKey: "ExportDestinationBookmark")
        }
        let scope = Scope()
        self.scope = scope
        destination = ExportDestinationManager(
          skipRestore: !restoreFailure, userDefaults: defaults,
          sameFolderEvidenceProvider: { _ in .differentFromStored },
          bookmarkSaver: { _ in scope.saveAllowed },
          volumeNotificationCenter: NotificationCenter(),
          validationScopeAcquirer: { _ in scope.allowed }, validationScopeReleaser: { _ in })
        library = PhotoLibraryManager(overrideService: service)
        timeline = ExportRecordStore(baseDirectoryURL: root.appendingPathComponent("Records"))
        collections = CollectionExportRecordStore(
          baseDirectoryURL: root.appendingPathComponent("Records"))
        timeline.configure(for: "A")
        collections.configure(for: "A")
        manager = ExportManager(
          photoLibraryService: service, exportDestination: fakeDestination,
          exportRecordStore: timeline, collectionExportRecordStore: collections,
          assetResourceWriter: FakeAssetResourceWriter(), fileSystem: FakeFileSystem(),
          userDefaults: defaults)
        whatsNew = WhatsNewState(userDefaults: defaults, currentVersion: "test", catalog: [])
        whatsNew.markAsSeen()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if !restoreFailure {
          destination.setSelectedFolderForTesting(folder)
          destination.revalidateForTesting()
        }
        service.collectionTree = [
          PhotoCollectionDescriptor(
            id: "folder:folder", localIdentifier: "folder", title: "Folder", kind: .folder,
            pathComponents: [],
            children: [
              PhotoCollectionDescriptor(
                id: "album:album", localIdentifier: "album", title: "Album", kind: .album,
                pathComponents: ["Folder"], children: [])
            ])
        ]
      }

      func setProblem(_ problem: Problem) throws {
        if problem == .permission {
          scope.allowed = false
        } else {
          try FileManager.default.removeItem(at: folder)
        }
        if problem == .unreachable {
          destination.setSelectedFolderForTesting(URL(fileURLWithPath: folder.path))
        }
        destination.revalidateForTesting()
      }

      @ViewBuilder private func pane(_ surface: Surface) -> some View {
        switch surface {
        case .root: LibraryRootView()
        case .month:
          MonthContentView(
            year: 2026, month: 9, versionSelection: .edited, livePhotosPaired: false,
            onExportMonth: {}, selectedAsset: .constant(nil), photoLibraryService: service)
        case .year:
          YearContentView(
            year: 2026, selection: .constant(nil), selectedAsset: .constant(nil),
            photoLibraryService: service)
        case .collection:
          CollectionContentView(
            selection: .favorites, title: "Favorites", versionSelection: .edited,
            livePhotosPaired: false, onExportCollection: {}, selectedAsset: .constant(nil),
            photoLibraryService: service)
        case .folder:
          FolderContentView(
            folderId: "folder", title: "Folder", selection: .constant(nil),
            selectedAsset: .constant(nil), photoLibraryService: service)
        }
      }

      func show(_ surface: Surface = .root) {
        let hosted = NSHostingView(
          rootView: pane(surface).frame(width: 1200, height: 800)
            .environmentObject(library).environmentObject(timeline).environmentObject(collections)
            .environmentObject(manager).environmentObject(manager.progressState)
            .environmentObject(destination).environmentObject(autoSync).environment(whatsNew)
            .environment(\.bodyInvalidationCounter, counter))
        let owned = NSWindow(
          contentRect: NSRect(x: -10000, y: -10000, width: 1200, height: 800),
          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        owned.isReleasedWhenClosed = false
        owned.contentView = hosted
        window = owned
        hosted.layoutSubtreeIfNeeded()
        owned.orderFront(nil)
        hosted.layoutSubtreeIfNeeded()
      }

      func close() {
        autoSync.setEnabled(false)
        manager.cancelAndClear()
        window?.contentView = nil
        window?.close()
        window = nil
        counter.reset()
        timeline.flushForTesting()
        collections.flushForTesting()
        fakeDestination.cleanup()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
      }
    }

    private let reconnect =
      "Export folder is unavailable. Reconnect the drive or network share to export."
    private let permission =
      "Export folder access needs restoring. Reconnect the drive, then choose the same folder if needed."

    private func observe(
      _ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
      await eventually("observed condition", sourceLocation: sourceLocation) { condition() }
    }

    @Test func missingFolderIsUnreachableRatherThanNotDirectoryAndCanRecoverIdentity() throws {
      let f = try Fixture()
      defer { f.close() }
      let id = try #require(f.destination.destinationId)
      try f.setProblem(.unreachable)
      #expect(f.destination.statusMessage == "Export folder is not reachable (drive unplugged?)")
      #expect(!f.destination.canExportNow && !f.destination.canImportNow)
      #expect(f.destination.destinationId == nil)
      try FileManager.default.createDirectory(at: f.folder, withIntermediateDirectories: true)
      f.destination.revalidateForTesting()
      #expect(f.destination.canExportNow && f.destination.canImportNow)
      #expect(f.destination.destinationId == id)
      let file = f.root.appendingPathComponent("regular-file")
      try Data("file".utf8).write(to: file)
      f.destination.setSelectedFolderForTesting(file)
      f.destination.revalidateForTesting()
      #expect(f.destination.statusMessage == "Selected path is not a folder")
    }

    @Test(arguments: Surface.allCases)
    func disabledExportHelpNamesTheUnavailableFolder(surface: Surface) async throws {
      let f = try Fixture()
      defer { f.close() }
      try f.setProblem(.unreachable)
      f.show(surface)
      let key = surface == .root ? "toolbar-export-help" : "\(surface)-export-help"
      let rendered = await observe { f.counter.renderedText[key] != nil }
      try #require(
        rendered,
        "Actual help consumer must render: \(key); values: \(f.counter.renderedText), bodies: \(f.counter.snapshot())"
      )
      #expect(f.counter.renderedText[key] == [reconnect])
      if surface == .root {
        #expect(f.counter.renderedText["destination-help"]?.first?.contains(reconnect) == true)
        #expect(
          f.counter.renderedText["destination-help"]?.first?.contains("click to change") == false)
      }
    }

    @Test(arguments: Problem.allCases, [false, true])
    func rootBannerSurvivesOldProgressRegardlessOfAutoExport(problem: Problem, enabled: Bool)
      async throws
    {
      let f = try Fixture()
      defer { f.close() }
      f.autoSync.setEnabled(enabled)
      f.manager.progressState.totalJobsEnqueued = 3
      f.manager.progressState.totalJobsCompleted = 3
      try f.setProblem(problem)
      f.show()
      let expected = problem == .unreachable ? reconnect : permission
      let rendered = await observe { f.counter.renderedText["destination-warning"] != nil }
      try #require(rendered, "The actual main-window warning must render")
      #expect(f.counter.renderedText["destination-warning"] == [expected])
      #expect(
        f.counter.renderedText["destination-recovery-action"]
          == (problem == .permission ? ["Choose Folder…"] : []))
      #expect(f.autoSync.isEnabled == enabled)
      if problem == .unreachable {
        try FileManager.default.createDirectory(at: f.folder, withIntermediateDirectories: true)
      } else {
        f.scope.allowed = true
      }
      f.destination.revalidateForTesting()
      let cleared = await observe { f.counter.renderedText["destination-warning"] == [] }
      #expect(cleared)
      f.destination.clearSelection()
      let noSelection = await observe { f.counter.renderedText["destination-warning"] == [] }
      #expect(noSelection)
    }
    @Test func failedBookmarkRestoreShowsRecoveryEvenWithoutResolvedURL() async throws {
      let f = try Fixture(restoreFailure: true)
      defer { f.close() }
      #expect(f.destination.selectedFolderURL == nil)
      #expect(!f.destination.canExportNow && !f.destination.canImportNow)
      f.show()
      let rendered = await observe { f.counter.renderedText["destination-warning"] == [permission] }
      #expect(rendered)
      #expect(f.counter.renderedText["destination-recovery-action"] == ["Choose Folder…"])
      #expect(f.counter.renderedText["destination-help"] == [permission])
      f.destination.clearSelection()
      let cleared = await observe { f.counter.renderedText["destination-warning"] == [] }
      #expect(cleared)
    }

    @Test func failedBookmarkSaveDoesNotBlockUsablePriorFolder() async throws {
      let f = try Fixture()
      defer { f.close() }
      let id = try #require(f.destination.destinationId)
      let second = f.root.appendingPathComponent("Other")
      try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
      f.scope.saveAllowed = false
      f.destination.selectFolderForTesting(second)
      #expect(f.destination.selectedFolderURL == f.folder)
      #expect(f.destination.destinationId == id)
      #expect(f.destination.canExportNow && f.destination.canImportNow)
      #expect(f.destination.statusMessage == "Failed to save access to selected folder")
      f.show()
      let rendered = await observe { f.counter.renderedText["destination-warning"] != nil }
      #expect(rendered)
      #expect(f.counter.renderedText["destination-warning"] == [])
      #expect(f.counter.renderedText["destination-recovery-action"] == [])
    }

  }
#endif
