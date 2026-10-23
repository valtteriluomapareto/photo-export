import AppKit
import Photos
import SwiftUI
import Observation
import Testing

@testable import Photo_Export

#if DEBUG
  /// Root inputs admit history readiness while unrelated record and destination publications
  /// leave action-only references and the current readiness value unchanged.
  @MainActor
  @Suite(.timeLimit(.minutes(2)), .serialized)
  struct RootViewObservationTests {
    enum Surface { case library, content, mainWindow }
    enum ExistingState: CaseIterable { case destination, records, neither }
    enum LibraryReadSurface: CaseIterable { case content, timeline, album }

    private struct LibraryProbe: View {
      let library: PhotoLibraryManager
      let counter: BodyInvalidationCounter
      var body: some View {
        // swiftlint:disable:next redundant_discardable_let
        let _ = counter.record(
          "library-probe:\(library.libraryRevision):\(library.authorizationStatus.rawValue)")
        Color.clear.frame(width: 1, height: 1)
      }
    }

    /// Renders each timeline revision independently before a root-body silence check.
    @MainActor
    private struct RecordsProbe: View {
      let store: ExportRecordStore
      let counter: BodyInvalidationCounter
      var body: some View {
        // A declaration keeps the probe out of ViewBuilder's view expressions.
        // swiftlint:disable:next redundant_discardable_let
        let _ = counter.record("timeline-records:\(store.mutationCounter)")
        Color.clear.frame(width: 1, height: 1)
      }
    }

    @Observable
    final class RenderTick { var value = 0 }

    private struct TickProbe: View {
      let tick: RenderTick
      let counter: BodyInvalidationCounter
      var body: some View {
        // swiftlint:disable:next redundant_discardable_let
        let _ = counter.record("root-barrier:\(tick.value)")
        Color.clear.frame(width: 1, height: 1)
      }
    }

    private struct CollectionRecordsProbe: View {
      let store: CollectionExportRecordStore
      let counter: BodyInvalidationCounter
      var body: some View {
        // swiftlint:disable:next redundant_discardable_let
        let _ = counter.record("collection-records:\(store.mutationCounter)")
        Color.clear.frame(width: 1, height: 1)
      }
    }

    /// Rebuilds the window root for queue, destination and record changes to stress the
    /// equatable router independently of its own dependencies.
    @MainActor
    private struct ContentHost: View {
      let manager: ExportManager
      @ObservedObject var destination: ExportDestinationManager
      let timeline: ExportRecordStore
      let counter: BodyInvalidationCounter
      var body: some View {
        // A declaration keeps the probe out of ViewBuilder's view expressions.
        // swiftlint:disable:next redundant_discardable_let
        let _ = counter.record("content-host")
        // swiftlint:disable:next redundant_discardable_let
        let _ = timeline.mutationCounter
        // swiftlint:disable:next redundant_discardable_let
        let _ = manager.queueCount
        MainWindowRoot(destinationManager: destination, recordStore: timeline)
      }
    }

    @MainActor
    private final class Fixture {
      let io = HeldReadIO()
      let root = TestScratch.directory("RootViewObservation")
      let suite = TestScratch.suiteName("RootViewObservation")
      let defaults: UserDefaults
      let destination: ExportDestinationManager
      let service = FakePhotoLibraryService()
      let library: PhotoLibraryManager
      let timeline: ExportRecordStore
      let collections: CollectionExportRecordStore
      let fakeDestination = FakeExportDestination()
      let writer = FakeAssetResourceWriter()
      let manager: ExportManager
      let autoSync = AutoSyncManager()
      let whatsNew: WhatsNewState
      let counter = BodyInvalidationCounter()
      let tick = RenderTick()
      var window: NSWindow?
      var folder: URL { root.appendingPathComponent("Backup") }
      var windowRootBodyKey: String { "main-window-root" }

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
        timeline = ExportRecordStore(
          baseDirectoryURL: root.appendingPathComponent("Records"), recordLogIO: io,
          notificationClock: TestClock())
        collections = CollectionExportRecordStore(
          baseDirectoryURL: root.appendingPathComponent("Records"), recordLogIO: io,
          notificationClock: TestClock())
        timeline.configure(for: "A")
        collections.configure(for: "A")
        manager = ExportManager(
          photoLibraryService: service, exportDestination: fakeDestination,
          exportRecordStore: timeline, collectionExportRecordStore: collections,
          assetResourceWriter: writer, fileSystem: FakeFileSystem(),
          userDefaults: defaults)
        whatsNew = WhatsNewState(userDefaults: defaults, currentVersion: "test", catalog: [])
        if whatsNewSeen { whatsNew.markAsSeen() }
        if selectFolder {
          try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
          destination.setSelectedFolderForTesting(folder)
          destination.revalidateForTesting()
        }
      }

      @ViewBuilder private func pane(_ surface: Surface, screenshotSurfaceKey: String?) -> some View
      {
        switch surface {
        case .library:
          LibraryRootView(screenshotSurfaceKey: screenshotSurfaceKey, timelineHistoryState: .ready)
        case .content:
          ContentHost(
            manager: manager, destination: destination, timeline: timeline, counter: counter)
        case .mainWindow:
          MainWindowRoot(destinationManager: destination, recordStore: timeline)
        }
      }

      func show(_ surface: Surface, screenshotSurfaceKey: String? = nil) {
        let hosted = NSHostingView(
          rootView: pane(surface, screenshotSurfaceKey: screenshotSurfaceKey).frame(
            width: 1200, height: 800
          )
          .overlay(alignment: .bottomTrailing) {
            ExportManagerRenderProbe(manager: manager, counter: counter)
          }
          .overlay(alignment: .topLeading) { RecordsProbe(store: timeline, counter: counter) }
          .overlay(alignment: .topTrailing) { LibraryProbe(library: library, counter: counter) }
          .overlay(alignment: .bottomLeading) {
            CollectionRecordsProbe(store: collections, counter: counter)
          }
          .overlay { TickProbe(tick: tick, counter: counter) }
          .environment(library).environment(timeline).environment(collections)
          .environment(manager).environment(manager.progressState)
          .environmentObject(destination).environmentObject(autoSync).environment(whatsNew)
          .environment(\.bodyInvalidationCounter, counter)
          .environment(\.screenshotSurfaceKey, screenshotSurfaceKey).defaultAppStorage(defaults))
        let owned = HostedViewHarness.makeWindow(
          contentRect: NSRect(x: -10000, y: -10000, width: 1200, height: 800),
          styleMask: [.titled, .closable])
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

      func barrier() async throws {
        tick.value += 1
        let key = "root-barrier:\(tick.value)"
        try #require(await observe(in: window) { counter.count(for: key) > 0 })
        await quiesce()
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
        io.releaseAll()
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

    private func settle(_ f: Fixture, key: String) async throws {
      try #require(
        await observe {
          f.counter.count(for: key) > 0
            && f.counter.renderedText["timeline-sidebar-years"] == ["2026:2"]
        })
      await f.quiesce()
    }

    private func beginHistoryLoad(_ f: Fixture, section: LibrarySection) -> URL {
      let snapshotName =
        section == .timeline
        ? ExportRecordStore.Constants.snapshotFileName
        : CollectionExportRecordStore.Constants.snapshotFileName
      let snapshot = f.root.appendingPathComponent("Records/Loading")
        .appendingPathComponent(snapshotName)
      f.io.hold(snapshot)
      if section == .timeline {
        f.timeline.beginConfigure(for: "Loading")
      } else {
        f.collections.beginConfigure(for: "Loading")
      }
      return snapshot
    }

    /// Readiness passes before; unrelated-record silence fails on the observing app-style base.
    @Test func mainWindowRootFollowsTimelineReadinessOnly() async throws {
      let f = try Fixture()
      try await withCleanup {
        f.show(.mainWindow)
        let control = "toolbar-export-control"
        try #require(
          await observe(in: f.window) {
            f.counter.count(for: f.windowRootBodyKey) > 0
              && f.counter.renderedText[control]?.first == "true"
          })
        await f.quiesce()
        let readyBodies = f.counter.count(for: f.windowRootBodyKey)
        let snapshot = beginHistoryLoad(f, section: .timeline)
        let loadingKey = "timeline-records:\(f.timeline.mutationCounter)"
        try #require(await observe(in: f.window) { f.counter.count(for: loadingKey) > 0 })
        await f.quiesce()
        #expect(f.counter.count(for: f.windowRootBodyKey) > readyBodies)
        #expect(f.counter.renderedText[control]?.first == "false")
        #expect(f.counter.renderedText[control]?[1].contains("Loading export history") == true)
        let loadingBodies = f.counter.count(for: f.windowRootBodyKey)
        f.io.release(snapshot)
        await f.timeline.waitUntilSettled()
        let settledKey = "timeline-records:\(f.timeline.mutationCounter)"
        try #require(await observe(in: f.window) { f.counter.count(for: settledKey) > 0 })
        await f.quiesce()
        #expect(f.counter.count(for: f.windowRootBodyKey) > loadingBodies)
        #expect(f.counter.renderedText[control]?.first == "true")
        #expect(f.counter.renderedText[control]?[1].contains("Loading export history") == false)
        let bodies = f.counter.count(for: f.windowRootBodyKey)
        try await f.changeUnrelatedRecord()
        let delta = f.counter.count(for: f.windowRootBodyKey) - bodies
        #expect(delta == 0)
      } cleanup: {
        await f.close()
      }
    }

    @Test func contentRouteRendersForHistoryReadinessOnly() async throws {
      let f = try Fixture(selectFolder: false, onboardingComplete: false)
      try await withCleanup {
        f.show(.content)
        try #require(await observe { f.counter.count(for: "onboarding-auto-skip-checked") > 0 })
        try FileManager.default.createDirectory(at: f.folder, withIntermediateDirectories: true)
        f.destination.setSelectedFolderForTesting(f.folder)
        f.destination.revalidateForTesting()
        try #require(
          await observe { f.counter.renderedText["onboarding-export-control"]?.first == "true" })
        await f.quiesce()
        let rootBodies = f.counter.count(for: "content-root")
        let hostBodies = f.counter.count(for: "content-host")
        try #require(f.timeline.state == .ready)
        let readyRoute = ContentView(
          destinationManager: f.destination, recordStore: f.timeline,
          timelineHistoryState: f.timeline.state)
        let sameReadyRoute = ContentView(
          destinationManager: f.destination, recordStore: f.timeline,
          timelineHistoryState: f.timeline.state)
        #expect(readyRoute == sameReadyRoute)
        let snapshot = beginHistoryLoad(f, section: .timeline)
        try #require(f.timeline.state == .loading)
        let loadingRoute = ContentView(
          destinationManager: f.destination, recordStore: f.timeline,
          timelineHistoryState: f.timeline.state)
        #expect(readyRoute != loadingRoute)
        try #require(await observe { f.counter.count(for: "content-host") > hostBodies })
        await f.quiesce()
        #expect(f.counter.count(for: "content-root") > rootBodies)
        #expect(f.counter.renderedText["onboarding-export-control"]?.first == "false")
        f.io.release(snapshot)
        await f.timeline.waitUntilSettled()
      } cleanup: {
        await f.close()
      }
    }

    @Test(arguments: [LibrarySection.timeline, .collections])
    func appRouteUpdatesToolbarForHistoryReadiness(section: LibrarySection) async throws {
      let f = try Fixture()
      try await withCleanup {
        f.show(.content, screenshotSurfaceKey: section == .timeline ? nil : "collections-favorites")
        let key = "toolbar-export-control"
        try #require(await observe { f.counter.renderedText[key] != nil })
        try #require(f.counter.renderedText[key]?.first == "true")
        let snapshot = beginHistoryLoad(f, section: section)
        try #require(await observe { f.counter.renderedText[key]?.first == "false" })
        #expect(f.counter.renderedText[key]?[1].contains("Loading export history") == true)
        f.io.release(snapshot)
        if section == .timeline {
          await f.timeline.waitUntilSettled()
        } else {
          await f.collections.waitUntilSettled()
        }
        #expect(await observe { f.counter.renderedText[key]?.first == "true" })
        #expect(f.counter.renderedText[key]?[1].contains("Loading export history") == false)
      } cleanup: {
        await f.close()
      }
    }

    @Test func appRouteUpdatesOnboardingAndRetainsOptionsDuringHistoryLoad() async throws {
      let f = try Fixture(selectFolder: false, onboardingComplete: false)
      try await withCleanup {
        f.show(.content)
        let key = "onboarding-export-control"
        try #require(await observe { f.counter.count(for: "onboarding-auto-skip-checked") > 0 })
        let toggle = try #require(
          f.counter.renderedActions["onboarding-export-control-toggle-originals"])
        toggle()
        try #require(await observe { f.counter.renderedText[key]?.last == "true" })
        try FileManager.default.createDirectory(at: f.folder, withIntermediateDirectories: true)
        f.destination.setSelectedFolderForTesting(f.folder)
        f.destination.revalidateForTesting()
        try #require(await observe { f.counter.renderedText[key]?.first == "true" })
        let bodies = f.counter.count(for: "content-root")
        let snapshot = beginHistoryLoad(f, section: .timeline)
        try #require(await observe { f.counter.renderedText[key]?.first == "false" })
        #expect(f.counter.renderedText[key]?[1].contains("Loading export history") == true)
        #expect(f.counter.count(for: "content-root") > bodies)
        f.io.release(snapshot)
        await f.timeline.waitUntilSettled()
        #expect(await observe { f.counter.renderedText[key]?.first == "true" })
        #expect(f.counter.renderedText[key]?[1].contains("Loading export history") != true)
        #expect(f.counter.renderedText[key]?.last == "true")
        #expect(f.defaults.bool(forKey: "hasCompletedOnboarding") == false)
      } cleanup: {
        await f.close()
      }
    }

    /// Fails before collection dependency tracking is limited to the visible section.
    @Test func libraryRootSkipsCollectionRecordChangesInTimeline() async throws {
      let f = try Fixture()
      try await withCleanup {
        f.show(.library)
        try await settle(f, key: "library-root")
        let bodies = f.counter.count(for: "library-root")
        let placement = ExportPlacement.favorites()
        f.collections.upsertPlacement(placement)
        f.collections.markVariantExported(
          assetId: "unrelated-collection", placement: placement, variant: .original,
          filename: "UNRELATED.JPG", exportedAt: Date())
        f.collections.flushPendingNotifications()
        let key = "collection-records:\(f.collections.mutationCounter)"
        try #require(await observe(in: f.window) { f.counter.count(for: key) > 0 })
        await f.quiesce()
        #expect(f.counter.count(for: "library-root") == bodies)
      } cleanup: {
        await f.close()
      }
    }

    @Test func libraryRootSkipsCollectionRecordsWhileAlbumIsSelected() async throws {
      let f = try Fixture()
      try await withCleanup {
        f.service.collectionTree = [
          PhotoCollectionDescriptor(
            id: "album:family", localIdentifier: "family", title: "Family", kind: .album,
            pathComponents: [], children: [])
        ]
        f.show(.library, screenshotSurfaceKey: "collections-album-family")
        try #require(
          await observe(in: f.window) {
            f.counter.count(for: "title:Family") > 0
              && f.counter.renderedText["collection-summary"] != nil
          })
        try await f.barrier()
        let bodies = f.counter.count(for: "library-root")
        let placement = ExportPlacement.favorites()
        f.collections.upsertPlacement(placement)
        f.collections.markVariantExported(
          assetId: "unrelated", placement: placement, variant: .original,
          filename: "OTHER.JPG", exportedAt: Date())
        f.collections.flushPendingNotifications()
        let key = "collection-records:\(f.collections.mutationCounter)"
        try #require(await observe(in: f.window) { f.counter.count(for: key) > 0 })
        try await f.barrier()
        withKnownIssue("The album detail placement lookup currently observes global records") {
          #expect(f.counter.count(for: "library-root") == bodies)
        }
      } cleanup: {
        await f.close()
      }
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
        f.service.authorizationStatus = .denied
        f.service.isAuthorized = false
        f.library.refreshAuthorizationStatus()
        #expect(await observe { f.counter.count(for: "content-root") > bodies })
      } cleanup: {
        await f.close()
      }
    }

    /// Already passes: access changes route through denied, restricted and library panes.
    @Test func contentViewRoutesFollowAuthorization() async throws {
      let f = try Fixture()
      try await withCleanup {
        f.show(.content)
        try await settle(f, key: "content-root")
        let initialLibraryBodies = f.counter.count(for: "library-root")
        for status in [PHAuthorizationStatus.denied, .restricted] {
          f.service.authorizationStatus = status
          f.service.isAuthorized = false
          f.library.refreshAuthorizationStatus()
          try #require(
            await observe(in: f.window) {
              f.counter.count(for: "authorization-pane:\(status.rawValue)") > 0
            })
        }
        f.service.authorizationStatus = .authorized
        f.service.isAuthorized = true
        f.library.refreshAuthorizationStatus()
        #expect(
          await observe(in: f.window) {
            f.counter.count(for: "library-root") > initialLibraryBodies
          })
      } cleanup: {
        await f.close()
      }
    }

    private func familyAlbum(_ title: String) -> PhotoCollectionDescriptor {
      PhotoCollectionDescriptor(
        id: "album:family", localIdentifier: "family", title: title, kind: .album,
        pathComponents: [], children: [])
    }

    /// Already passes: the selected album title follows the current collection tree.
    @Test func libraryRootTitleFollowsAnAlbumRename() async throws {
      let f = try Fixture()
      try await withCleanup {
        f.service.collectionTree = [familyAlbum("Family")]
        f.show(.library, screenshotSurfaceKey: "collections-album-family")
        try #require(await observe(in: f.window) { f.counter.count(for: "title:Family") > 0 })
        await f.quiesce()
        f.service.collectionTree = [familyAlbum("Renamed Family")]
        f.library.invalidateCache(changedThumbnailAssetIDs: [])
        f.library.libraryRefresh.flush()
        #expect(await observe(in: f.window) { f.counter.count(for: "title:Renamed Family") > 0 })
      } cleanup: {
        await f.close()
      }
    }

    /// A collection query registers the revision and may render once for its publication;
    /// roots that do not read library content remain unchanged after the render barrier.
    @Test(arguments: LibraryReadSurface.allCases)
    func rootsSkipLibraryChangesTheyDoNotRead(surface: LibraryReadSurface) async throws {
      let f = try Fixture()
      try await withCleanup {
        f.service.collectionTree = [familyAlbum("Family")]
        let key = surface == .content ? "content-root" : "library-root"
        let landing = surface == .album ? "collections-album-family" : "timeline"
        f.show(surface == .content ? .content : .library, screenshotSurfaceKey: landing)
        try #require(
          await observe(in: f.window) {
            f.counter.count(for: key) > 0 && f.counter.count(for: "library-probe:0:3") > 0
          })
        if surface == .album {
          try #require(await observe(in: f.window) { f.counter.count(for: "title:Family") > 0 })
        } else {
          try #require(
            await observe(in: f.window) {
              f.counter.renderedText["timeline-sidebar-years"] == ["2026:2"]
            })
        }
        await f.quiesce()
        let before = f.counter.count(for: key)
        f.library.invalidateCache()
        f.library.libraryRefresh.flush()
        try #require(await observe(in: f.window) { f.counter.count(for: "library-probe:1:3") > 0 })
        await f.quiesce()
        let delta = f.counter.count(for: key) - before
        #expect(delta <= 1, "Root body delta: \(delta)")
        if surface != .album {
          #expect(delta == 0)
        }
      } cleanup: {
        await f.close()
      }
    }

    /// Already passes: the sheet reads the same manager as its library window. A missing
    /// manager injection traps the process; the behavioral mutant injects a different manager.
    @Test func importSheetFollowsTheLibraryManager() async throws {
      let f = try Fixture()
      try await withCleanup {
        f.show(.library)
        try await settle(f, key: "library-root")
        #expect(f.counter.renderedText["import-title"] == nil)
        f.manager.importResult = ImportReport(
          matchedCount: 1, ambiguousCount: 0, unmatchedCount: 0, totalScanned: 1)
        f.manager.requestImportSheet()
        try #require(await observe(in: f.window) { f.window?.attachedSheet != nil })
        try #require(
          await observe(in: f.window?.attachedSheet) {
            f.counter.renderedText["import-title"] != nil
          })
        try #require(f.counter.renderedText["import-title"] == ["Import Complete"])
        f.manager.importResult = nil
        #expect(
          await observe(in: f.window?.attachedSheet) {
            f.counter.renderedText["import-title"] == ["Import Stopped"]
          })
      } cleanup: {
        await f.close()
      }
    }

    @Test func exportControlProbeKeepsActionsSeparate() async throws {
      let counter = BodyInvalidationCounter()
      var fired: [String] = []
      let window = HostedViewHarness.makeWindow(
        contentRect: NSRect(x: -10000, y: -10000, width: 100, height: 100), styleMask: [.borderless]
      )
      defer {
        window.contentView = nil
        window.close()
      }
      window.contentView = NSHostingView(
        rootView: VStack {
          ExportControlProbe(key: "first", help: "", toggleOriginals: { fired.append("first") })
          ExportControlProbe(key: "second", help: "", toggleOriginals: { fired.append("second") })
        }.environment(\.bodyInvalidationCounter, counter))
      window.orderFront(nil)
      try #require(await observe(in: window) { counter.renderedText["second"] != nil })
      let first = try #require(counter.renderedActions["first-toggle-originals"])
      let second = try #require(counter.renderedActions["second-toggle-originals"])
      first()
      second()
      #expect(fired == ["first", "second"])
    }

    @Test(arguments: [LibrarySection.timeline, .collections])
    func toolbarSkipsRecordMutationsDuringExport(section: LibrarySection) async throws {
      let f = try Fixture()
      let gate = AsyncCheckpoint()
      try await withCleanup {
        f.show(
          .mainWindow, screenshotSurfaceKey: section == .timeline ? nil : "collections-favorites")
        try #require(
          await observe(in: f.window) {
            f.counter.count(for: "main-window-root") > 0
              && f.counter.renderedText["toolbar-export-control"]?.first == "true"
          })
        await f.quiesce()
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 15))!
        f.service.assetsByYearMonth["2026-9"] = [
          TestAssetFactory.makeAsset(id: "held", creationDate: date)
        ]
        f.service.resourcesByAssetId["held"] = [
          ResourceDescriptor(type: .photo, originalFilename: "HELD.JPG")
        ]
        f.writer.checkpoint = gate
        f.manager.queueCoordinator.enqueue([
          .init(
            assetLocalIdentifier: "held", placement: .timeline(year: 2026, month: 9),
            selection: .edited)
        ])
        f.manager.queueCoordinator.processQueueIfNeeded()
        try #require(await gate.waitForEnter(count: 1))
        try #require(
          await observe(in: f.window) { f.counter.renderedText["toolbar-pause-label"] == ["Pause"] }
        )
        f.timeline.flushPendingNotifications()
        f.collections.flushPendingNotifications()
        let tick = "timeline-records:\(f.timeline.mutationCounter)"
        try #require(await observe(in: f.window) { f.counter.count(for: tick) > 0 })
        await f.quiesce()
        let before = f.counter.count(for: "export-toolbar-actions")
        try #require(before > 0)
        try await f.changeUnrelatedRecord()
        #expect(f.counter.count(for: "export-toolbar-actions") - before == 0)
        let placement = ExportPlacement.favorites()
        f.collections.upsertPlacement(placement)
        f.collections.markVariantExported(
          assetId: "unrelated", placement: placement, variant: .original,
          filename: "OTHER.JPG", exportedAt: Date())
        f.collections.flushPendingNotifications()
        let collectionTick = "collection-records:\(f.collections.mutationCounter)"
        try #require(await observe(in: f.window) { f.counter.count(for: collectionTick) > 0 })
        await f.quiesce()
        #expect(f.counter.count(for: "export-toolbar-actions") - before == 0)
      } cleanup: {
        let task = f.manager.currentTask
        f.manager.cancelAndClear()
        await gate.releaseAll()
        if let task { _ = await finished(task) }
        await f.close()
      }
    }

    /// The toolbar tracks admission and pause labels without rebuilding the unrelated root.
    @Test func toolbarExportControlFollowsManualQueueWork() async throws {
      let f = try Fixture()
      try await withCleanup {
        f.show(.library)
        try await settle(f, key: "library-root")
        let control = "toolbar-export-control"
        try #require(
          await observe(in: f.window) { f.counter.renderedText[control]?.first == "true" })
        try await ExportManagerRenderProbe.change(
          manager: f.manager, counter: f.counter, in: f.window
        ) {
          f.manager.queueCoordinator.enqueue([
            .init(
              assetLocalIdentifier: "queued", placement: .timeline(year: 2026, month: 9),
              selection: .edited)
          ])
        }
        #expect(
          await observe(in: f.window) { f.counter.renderedText[control]?.first == "false" })
        try #require(
          await observe(in: f.window) { f.counter.renderedText["toolbar-pause-label"] == ["Pause"] }
        )
        let before = f.counter.count(for: "library-root")
        try await ExportManagerRenderProbe.change(
          manager: f.manager, counter: f.counter, in: f.window
        ) {
          f.manager.pause()
        }
        #expect(
          await observe(in: f.window) {
            f.counter.renderedText["toolbar-pause-label"] == ["Resume"]
          })
        let delta = f.counter.count(for: "library-root") - before
        #expect(delta == 0)
        try await ExportManagerRenderProbe.change(
          manager: f.manager, counter: f.counter, in: f.window
        ) {
          f.manager.cancelAndClear()
        }
        #expect(
          await observe(in: f.window) { f.counter.renderedText[control]?.first == "true" })
      } cleanup: {
        await f.close()
      }
    }

    /// Photos access and held export work both close and reopen the rendered admission state.
    @Test func canImportFollowsActiveExportWork() async throws {
      let f = try Fixture()
      let gate = AsyncCheckpoint()
      try await withCleanup {
        f.show(.library)
        try await settle(f, key: "library-root")
        let key = "library-can-import"
        try #require(f.counter.renderedText[key] == ["true"])
        f.service.authorizationStatus = .denied
        f.service.isAuthorized = false
        f.library.refreshAuthorizationStatus()
        let deniedKey =
          "library-probe:\(f.library.libraryRevision):\(f.library.authorizationStatus.rawValue)"
        try #require(await observe(in: f.window) { f.counter.count(for: deniedKey) > 0 })
        await f.quiesce()
        #expect(f.counter.renderedText[key] == ["false"])
        f.service.authorizationStatus = .authorized
        f.service.isAuthorized = true
        f.library.refreshAuthorizationStatus()
        let grantedKey =
          "library-probe:\(f.library.libraryRevision):\(f.library.authorizationStatus.rawValue)"
        try #require(await observe(in: f.window) { f.counter.count(for: grantedKey) > 0 })
        await f.quiesce()
        #expect(f.counter.renderedText[key] == ["true"])
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 15))!
        f.service.assetsByYearMonth["2026-9"] = [
          TestAssetFactory.makeAsset(id: "held", creationDate: date)
        ]
        f.service.resourcesByAssetId["held"] = [
          ResourceDescriptor(type: .photo, originalFilename: "HELD.JPG")
        ]
        f.writer.checkpoint = gate
        f.manager.queueCoordinator.enqueue([
          .init(
            assetLocalIdentifier: "held", placement: .timeline(year: 2026, month: 9),
            selection: .edited)
        ])
        f.manager.queueCoordinator.processQueueIfNeeded()
        try #require(await gate.waitForEnter(count: 1))
        try #require(f.manager.isRunning)
        #expect(await observe(in: f.window) { f.counter.renderedText[key] == ["false"] })
        let task = f.manager.currentTask
        f.manager.cancelAndClear()
        await gate.releaseAll()
        if let task { _ = await finished(task) }
        #expect(await observe(in: f.window) { f.counter.renderedText[key] == ["true"] })
      } cleanup: {
        let task = f.manager.currentTask
        f.manager.cancelAndClear()
        await gate.releaseAll()
        if let task { _ = await finished(task) }
        await f.close()
      }
    }

    /// Fails before property-specific manager observation: neither write changes root content.
    @Test func libraryRootSkipsPauseAndVideoLayout() async throws {
      let f = try Fixture()
      try await withCleanup {
        f.show(.library)
        try await settle(f, key: "library-root")
        try await ExportManagerRenderProbe.change(
          manager: f.manager, counter: f.counter, in: f.window
        ) {
          f.manager.queueCoordinator.enqueue([
            .init(
              assetLocalIdentifier: "queued", placement: .timeline(year: 2026, month: 9),
              selection: .edited)
          ])
        }
        let before = f.counter.count(for: "library-root")
        try await ExportManagerRenderProbe.change(
          manager: f.manager, counter: f.counter, in: f.window
        ) {
          f.manager.pause()
        }
        let pause = f.counter.count(for: "library-root") - before
        #expect(pause == 0)
        let paused = f.counter.count(for: "library-root")
        try await ExportManagerRenderProbe.change(
          manager: f.manager, counter: f.counter, in: f.window
        ) {
          f.manager.videoLayout = .subfolder
        }
        let layout = f.counter.count(for: "library-root") - paused
        #expect(layout == 0)
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
