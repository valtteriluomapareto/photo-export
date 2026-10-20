import AppKit
import SwiftUI
import Testing

@testable import Photo_Export

#if DEBUG
  /// The app's root views hold the record store and destination manager only for actions,
  /// so publications from those objects must not re-run their bodies.
  @MainActor
  @Suite(.timeLimit(.minutes(2)), .serialized)
  struct RootViewObservationTests {
    enum Surface { case library, content }
    enum ExistingState: CaseIterable { case destination, records, neither }

    /// Renders once per timeline-store publication, so a test can wait for a record change
    /// to reach SwiftUI before checking that a root body did not run for it.
    @MainActor
    private struct RecordsProbe: View {
      @ObservedObject var store: ExportRecordStore
      let counter: BodyInvalidationCounter
      var body: some View {
        let _ = counter.record("timeline-records:\(store.mutationCounter)")
        Color.clear.frame(width: 1, height: 1)
      }
    }

    /// Rebuilds `ContentView` whenever the manager, destination or record store publishes,
    /// as `App.body` does in production.
    @MainActor
    private struct ContentHost: View {
      @ObservedObject var manager: ExportManager
      @ObservedObject var destination: ExportDestinationManager
      @ObservedObject var timeline: ExportRecordStore
      let counter: BodyInvalidationCounter
      var body: some View {
        let _ = counter.record("content-host")
        ContentView(destinationManager: destination, recordStore: timeline).equatable()
      }
    }

    @MainActor
    private final class Fixture {
      let root = TestScratch.directory("RootViewObservation")
      let suite = TestScratch.suiteName("RootViewObservation")
      let defaults: UserDefaults
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

      init(
        selectFolder: Bool = true, onboardingComplete: Bool = true, whatsNewSeen: Bool = true
      ) throws {
        defaults = TestScratch.defaults(suiteName: suite)
        defaults.set(onboardingComplete, forKey: "hasCompletedOnboarding")
        destination = ExportDestinationManager(
          skipRestore: true, userDefaults: defaults,
          sameFolderEvidenceProvider: { _ in .differentFromStored },
          bookmarkSaver: { _ in true }, volumeNotificationCenter: NotificationCenter(),
          validationScopeAcquirer: { _ in true }, validationScopeReleaser: { _ in })
        service.yearCounts = [(2026, 2)]
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
        if whatsNewSeen { whatsNew.markAsSeen() }
        if selectFolder {
          try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
          destination.setSelectedFolderForTesting(folder)
          destination.revalidateForTesting()
        }
      }

      @ViewBuilder private func pane(_ surface: Surface) -> some View {
        switch surface {
        case .library: LibraryRootView()
        case .content:
          ContentHost(
            manager: manager, destination: destination, timeline: timeline, counter: counter)
        }
      }

      func show(_ surface: Surface) {
        let hosted = NSHostingView(
          rootView: pane(surface).frame(width: 1200, height: 800)
            .overlay(alignment: .topLeading) { RecordsProbe(store: timeline, counter: counter) }
            .environmentObject(library).environmentObject(timeline).environmentObject(collections)
            .environmentObject(manager).environment(manager.progressState)
            .environmentObject(destination).environmentObject(autoSync).environment(whatsNew)
            .environment(\.bodyInvalidationCounter, counter).defaultAppStorage(defaults))
        let owned = NSWindow(
          contentRect: NSRect(x: -10000, y: -10000, width: 1200, height: 800),
          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        owned.isReleasedWhenClosed = false
        owned.contentView = hosted
        window = owned
        owned.orderFront(nil)
      }

      /// Awaits every task the views recorded, including ones recorded meanwhile, then lays
      /// out what they published.
      func quiesce() async {
        var awaited = 0
        while awaited < counter.tasks.count {
          let pending = counter.tasks[awaited...]
          awaited = counter.tasks.count
          for task in pending { _ = await finished(task) }
        }
        window?.contentView?.layoutSubtreeIfNeeded()
      }

      /// Records an export for a month the library view does not show, then waits until the
      /// publication has rendered.
      func changeUnrelatedRecord() async throws {
        let revision = timeline.mutationCounter
        timeline.markVariantExported(
          assetId: "unrelated", variant: .original, year: 2001, month: 1,
          relPath: "2001/01/", filename: "UNRELATED.JPG", exportedAt: Date())
        timeline.flushPendingNotifications()
        try #require(timeline.mutationCounter > revision)
        let key = "timeline-records:\(timeline.mutationCounter)"
        try #require(await eventually("record change rendered") { counter.count(for: key) > 0 })
        await quiesce()
      }

      func changes(since baseline: [String: Int]) -> [String] {
        counter.snapshot().filter { baseline[$0.key] != $0.value }
          .map { "\($0.key): \(baseline[$0.key] ?? 0)→\($0.value)" }.sorted()
      }

      func close() async {
        autoSync.setEnabled(false)
        manager.cancelAndClear()
        if let sheet = window?.attachedSheet {
          window?.endSheet(sheet)
          sheet.close()
        }
        window?.orderOut(nil)
        window?.contentView = nil
        window?.close()
        window = nil
        await quiesce()
        counter.reset()
        try? await timeline.flush()
        try? await collections.flush()
        fakeDestination.cleanup()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
      }
    }

    private func observe(
      _ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
      await eventually("observed condition", sourceLocation: sourceLocation) { condition() }
    }

    private func settle(_ f: Fixture, key: String) async throws {
      try #require(
        await observe {
          f.counter.count(for: key) > 0
            && f.counter.renderedText["timeline-sidebar-years"] == ["2026:2"]
        })
      await f.quiesce()
    }

    @Test func libraryRootSkipsUnrelatedTimelineRecordChanges() async throws {
      let f = try Fixture()
      try await withCleanup {
        f.show(.library)
        try await settle(f, key: "library-root")
        let bodies = f.counter.count(for: "library-root")
        let baseline = f.counter.snapshot()
        try await f.changeUnrelatedRecord()
        #expect(
          f.counter.count(for: "library-root") == bodies,
          "Changes since baseline: \(f.changes(since: baseline))")
        f.destination.revalidateForTesting()
        #expect(await observe { f.counter.count(for: "library-root") > bodies })
      } cleanup: {
        await f.close()
      }
    }

    @Test func contentViewSkipsRecordDestinationAndQueuePublicationsWhenRebuilt() async throws {
      let f = try Fixture()
      try await withCleanup {
        f.show(.content)
        try await settle(f, key: "content-root")
        try #require(f.counter.count(for: "library-root") > 0)
        // The first rebuild after the initial render can re-run the body once while SwiftUI
        // settles the view's stored inputs, so the baseline follows one rebuild.
        var hostBodies = f.counter.count(for: "content-host")
        f.destination.revalidateForTesting()
        try #require(await observe { f.counter.count(for: "content-host") > hostBodies })
        await f.quiesce()
        let bodies = f.counter.count(for: "content-root")
        let baseline = f.counter.snapshot()
        hostBodies = f.counter.count(for: "content-host")
        try await f.changeUnrelatedRecord()
        #expect(await observe { f.counter.count(for: "content-host") > hostBodies })
        #expect(
          f.counter.count(for: "content-root") == bodies,
          "Changes since baseline: \(f.changes(since: baseline))")
        hostBodies = f.counter.count(for: "content-host")
        f.destination.revalidateForTesting()
        try #require(await observe { f.counter.count(for: "content-host") > hostBodies })
        await f.quiesce()
        #expect(
          f.counter.count(for: "content-root") == bodies,
          "Changes since baseline: \(f.changes(since: baseline))")
        hostBodies = f.counter.count(for: "content-host")
        f.manager.queueCoordinator.enqueue([
          .init(
            assetLocalIdentifier: "unrelated", placement: .timeline(year: 2001, month: 1),
            selection: .edited)
        ])
        try #require(await observe { f.counter.count(for: "content-host") > hostBodies })
        await f.quiesce()
        #expect(
          f.counter.count(for: "content-root") == bodies,
          "Changes since baseline: \(f.changes(since: baseline))")
        f.library.invalidateCache()
        #expect(await observe { f.counter.count(for: "content-root") > bodies })
      } cleanup: {
        await f.close()
      }
    }

    /// The library root presents What's New from `shouldShow`, so dismissing it elsewhere (the
    /// state shared with another window) must re-run the root and close the sheet.
    @Test func whatsNewSheetFollowsShouldShow() async throws {
      let f = try Fixture(whatsNewSeen: false)
      try await withCleanup {
        f.show(.library)
        try await settle(f, key: "library-root")
        try #require(await observe { f.window?.attachedSheet != nil })
        let bodies = f.counter.count(for: "library-root")
        f.whatsNew.markAsSeen()
        #expect(await observe { f.counter.count(for: "library-root") > bodies })
        #expect(await observe { f.window?.attachedSheet == nil })
      } cleanup: {
        await f.close()
      }
    }

    @Test(arguments: ExistingState.allCases)
    func onboardingIsSkippedForExistingDestinationOrRecords(state: ExistingState) async throws {
      let f = try Fixture(selectFolder: state == .destination, onboardingComplete: false)
      try await withCleanup {
        if state == .records {
          f.timeline.markVariantExported(
            assetId: "existing", variant: .original, year: 2026, month: 9, relPath: "2026/09/",
            filename: "EXISTING.JPG", exportedAt: Date())
          f.timeline.flushPendingNotifications()
        }
        #expect(f.defaults.bool(forKey: "hasCompletedOnboarding") == false)
        f.show(.content)
        try #require(await observe { f.counter.count(for: "onboarding-auto-skip-checked") > 0 })
        if state == .neither {
          await f.quiesce()
          #expect(f.defaults.bool(forKey: "hasCompletedOnboarding") == false)
          #expect(f.counter.count(for: "library-root") == 0)
        } else {
          #expect(await observe { f.defaults.bool(forKey: "hasCompletedOnboarding") })
          #expect(await observe { f.counter.count(for: "library-root") > 0 })
        }
      } cleanup: {
        await f.close()
      }
    }
  }
#endif
