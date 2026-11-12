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
      ) async throws {
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
        await timeline.configureAndWait(for: "A")
        await collections.configureAndWait(for: "A")
        manager = ExportManager(
          photoLibraryService: service, exportDestination: fakeDestination,
          exportRecordStore: timeline, collectionExportRecordStore: collections,
          assetResourceWriter: writer, fileSystem: FakeFileSystem(),
          userDefaults: defaults)
        whatsNew = WhatsNewState(userDefaults: defaults, currentVersion: "test", catalog: [])
        if whatsNewSeen { whatsNew.markAsSeen() }
        if selectFolder {
          try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
          await destination.persistSelectionAndWait(folder)
          await destination.revalidateAndWait()
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
          .environment(\.accessibilityEnabled, true)
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

      /// The fixed 1200×800 host puts the real first-run action row in this region.
      /// Crop the buttons alone so count labels or unrelated root pixels cannot satisfy changes.
      func onboardingActionPixels() throws -> Data {
        let view = try #require(window?.contentView)
        view.layoutSubtreeIfNeeded()
        let top = NSRect(x: view.bounds.midX - 50, y: 615, width: 160, height: 70)
        let region =
          view.isFlipped
          ? top
          : NSRect(
            x: top.minX, y: view.bounds.height - top.maxY, width: top.width, height: top.height)
        let image = try #require(view.bitmapImageRepForCachingDisplay(in: region))
        view.cacheDisplay(in: region, to: image)
        var tones: Set<Int> = []
        for y in stride(from: 0, to: image.pixelsHigh, by: 2) {
          for x in stride(from: 0, to: image.pixelsWide, by: 2) {
            if let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
              tones.insert(Int(color.redComponent * 255))
            }
          }
        }
        try #require(tones.count > 3, "The crop must contain real button/text pixels")
        return try #require(image.representation(using: .png, properties: [:]))
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

    private func exportControl(_ f: Fixture) -> AnyObject? {
      guard let window = f.window else { return nil }
      return NativeViewAccess.element("manual-export-primary", in: window)
    }

    private func settle(_ f: Fixture, key: String) async throws {
      try #require(
        await observe {
          f.counter.count(for: key) > 0
            && f.window.map { NativeViewAccess.element("timeline-year:2026", in: $0) != nil }
              == true
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
      let f = try await Fixture()
      try await withCleanup {
        f.show(.mainWindow)
        try #require(
          await observe(in: f.window) {
            f.counter.count(for: f.windowRootBodyKey) > 0
              && exportControl(f)?.isAccessibilityEnabled?() == true
          })
        await f.quiesce()
        let readyBodies = f.counter.count(for: f.windowRootBodyKey)
        let snapshot = beginHistoryLoad(f, section: .timeline)
        let loadingKey = "timeline-records:\(f.timeline.mutationCounter)"
        try #require(await observe(in: f.window) { f.counter.count(for: loadingKey) > 0 })
        await f.quiesce()
        #expect(f.counter.count(for: f.windowRootBodyKey) > readyBodies)
        #expect(exportControl(f)?.isAccessibilityEnabled?() == false)
        let loadingBodies = f.counter.count(for: f.windowRootBodyKey)
        f.io.release(snapshot)
        await f.timeline.waitUntilSettled()
        let settledKey = "timeline-records:\(f.timeline.mutationCounter)"
        try #require(await observe(in: f.window) { f.counter.count(for: settledKey) > 0 })
        await f.quiesce()
        #expect(f.counter.count(for: f.windowRootBodyKey) > loadingBodies)
        #expect(exportControl(f)?.isAccessibilityEnabled?() == true)
        let bodies = f.counter.count(for: f.windowRootBodyKey)
        try await f.changeUnrelatedRecord()
        let delta = f.counter.count(for: f.windowRootBodyKey) - bodies
        #expect(delta == 0)
      } cleanup: {
        await f.close()
      }
    }

    @Test func contentRouteRendersForHistoryReadinessOnly() async throws {
      let f = try await Fixture(selectFolder: false, onboardingComplete: false)
      try await withCleanup {
        f.show(.content)
        try #require(await observe(in: f.window) { f.counter.count(for: "content-root") > 0 })
        try await f.barrier()
        try FileManager.default.createDirectory(at: f.folder, withIntermediateDirectories: true)
        await f.destination.persistSelectionAndWait(f.folder)
        await f.destination.revalidateAndWait()
        try await f.barrier()
        let readyPixels = try f.onboardingActionPixels()
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
        try await f.barrier()
        #expect(f.counter.count(for: "content-root") > rootBodies)
        #expect(
          try f.onboardingActionPixels() != readyPixels,
          "The actual mounted action row must reflect loading history")
        f.io.release(snapshot)
        await f.timeline.waitUntilSettled()
        try await f.barrier()
        #expect(try f.onboardingActionPixels() == readyPixels)
        #expect(!f.defaults.bool(forKey: "hasCompletedOnboarding"))
      } cleanup: {
        await f.close()
      }
    }

    @Test(arguments: [LibrarySection.timeline, .collections])
    func appRouteUpdatesToolbarForHistoryReadiness(section: LibrarySection) async throws {
      let f = try await Fixture()
      try await withCleanup {
        f.show(.content, screenshotSurfaceKey: section == .timeline ? nil : "collections-favorites")
        try #require(await observe { exportControl(f) != nil })
        try #require(exportControl(f)?.isAccessibilityEnabled?() == true)
        let snapshot = beginHistoryLoad(f, section: section)
        try #require(await observe { exportControl(f)?.isAccessibilityEnabled?() == false })
        f.io.release(snapshot)
        if section == .timeline {
          await f.timeline.waitUntilSettled()
        } else {
          await f.collections.waitUntilSettled()
        }
        #expect(await observe { exportControl(f)?.isAccessibilityEnabled?() == true })
      } cleanup: {
        await f.close()
      }
    }

    /// Fails before collection dependency tracking is limited to the visible section.
    @Test func libraryRootSkipsCollectionRecordChangesInTimeline() async throws {
      let f = try await Fixture()
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
      let f = try await Fixture()
      try await withCleanup {
        f.service.collectionTree = [
          PhotoCollectionDescriptor(
            id: "album:family", localIdentifier: "family", title: "Family", kind: .album,
            pathComponents: [], children: [])
        ]
        f.show(.library, screenshotSurfaceKey: "collections-album-family")
        try #require(
          await observe(in: f.window) {
            f.window.map { NativeViewAccess.containsText("Family", in: $0) } == true
              && f.window.map { NativeViewAccess.containsText("0/0 exported", in: $0) } == true
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
        #expect(f.counter.count(for: "library-root") == bodies)
      } cleanup: {
        await f.close()
      }
    }

    @Test func libraryRootSkipsUnrelatedTimelineRecordChanges() async throws {
      let f = try await Fixture()
      try await withCleanup {
        f.show(.library)
        try await settle(f, key: "library-root")
        let bodies = f.counter.count(for: "library-root")
        let baseline = f.counter.snapshot()
        try await f.changeUnrelatedRecord()
        #expect(
          f.counter.count(for: "library-root") == bodies,
          "Changes since baseline: \(f.changes(since: baseline))")
        await f.destination.revalidateAndWait()
        #expect(await observe { f.counter.count(for: "library-root") > bodies })
      } cleanup: {
        await f.close()
      }
    }

    @Test func contentViewSkipsRecordDestinationAndQueuePublicationsWhenRebuilt() async throws {
      let f = try await Fixture()
      try await withCleanup {
        f.show(.content)
        try await settle(f, key: "content-root")
        try #require(f.counter.count(for: "library-root") > 0)
        // The first rebuild after the initial render can re-run the body once while SwiftUI
        // settles the view's stored inputs, so the baseline follows one rebuild.
        var hostBodies = f.counter.count(for: "content-host")
        await f.destination.revalidateAndWait()
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
        await f.destination.revalidateAndWait()
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
      let f = try await Fixture()
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
              f.library.authorizationStatus == status
                && f.window.map {
                  NativeViewAccess.containsText("Photo Library Access Required", in: $0)
                } == true
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
      let f = try await Fixture()
      try await withCleanup {
        f.service.collectionTree = [familyAlbum("Family")]
        f.show(.library, screenshotSurfaceKey: "collections-album-family")
        try #require(
          await observe(in: f.window) {
            f.window.map { NativeViewAccess.containsText("Family", in: $0) } == true
          })
        await f.quiesce()
        f.service.collectionTree = [familyAlbum("Renamed Family")]
        f.library.invalidateCache(changedThumbnailAssetIDs: [])
        f.library.libraryRefresh.flush()
        #expect(
          await observe(in: f.window) {
            f.window.map { NativeViewAccess.containsText("Renamed Family", in: $0) } == true
          })
      } cleanup: {
        await f.close()
      }
    }

    /// A collection query registers the revision and may render once for its publication;
    /// roots that do not read library content remain unchanged after the render barrier.
    @Test(arguments: LibraryReadSurface.allCases)
    func rootsSkipLibraryChangesTheyDoNotRead(surface: LibraryReadSurface) async throws {
      let f = try await Fixture()
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
          try #require(
            await observe(in: f.window) {
              f.window.map { NativeViewAccess.containsText("Family", in: $0) } == true
            })
        } else {
          try #require(
            await observe(in: f.window) {
              f.window.map { NativeViewAccess.element("timeline-year:2026", in: $0) != nil } == true
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
      let f = try await Fixture()
      try await withCleanup {
        f.show(.library)
        try await settle(f, key: "library-root")
        #expect(f.window?.attachedSheet == nil)
        f.manager.importResult = ImportReport(
          matchedCount: 1, ambiguousCount: 0, unmatchedCount: 0, totalScanned: 1)
        f.manager.requestImportSheet()
        try #require(await observe(in: f.window) { f.window?.attachedSheet != nil })
        let sheet = try #require(f.window?.attachedSheet)
        try #require(
          await observe(in: sheet) {
            NativeViewAccess.containsText("Import Complete", in: sheet)
          })
        f.manager.importResult = nil
        #expect(
          await observe(in: sheet) {
            NativeViewAccess.containsText("Import Stopped", in: sheet)
          })
      } cleanup: {
        await f.close()
      }
    }

    @Test(arguments: [LibrarySection.timeline, .collections])
    func toolbarSkipsRecordMutationsDuringExport(section: LibrarySection) async throws {
      let f = try await Fixture()
      let gate = AsyncCheckpoint()
      try await withCleanup {
        f.show(
          .mainWindow, screenshotSurfaceKey: section == .timeline ? nil : "collections-favorites")
        try #require(
          await observe(in: f.window) {
            f.counter.count(for: "main-window-root") > 0
              && exportControl(f)?.isAccessibilityEnabled?() == true
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
          await observe(in: f.window) {
            f.window.map { NativeViewAccess.button("Pause export", in: $0) != nil } == true
          }
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
      let f = try await Fixture()
      try await withCleanup {
        f.show(.library)
        try await settle(f, key: "library-root")
        try #require(
          await observe(in: f.window) { exportControl(f)?.isAccessibilityEnabled?() == true })
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
          await observe(in: f.window) { exportControl(f)?.isAccessibilityEnabled?() == false })
        try #require(
          await observe(in: f.window) {
            f.window.map { NativeViewAccess.button("Pause export", in: $0) != nil } == true
          }
        )
        let before = f.counter.count(for: "library-root")
        try await ExportManagerRenderProbe.change(
          manager: f.manager, counter: f.counter, in: f.window
        ) {
          f.manager.pause()
        }
        #expect(
          await observe(in: f.window) {
            f.window.map { NativeViewAccess.button("Resume export", in: $0) != nil } == true
          })
        let delta = f.counter.count(for: "library-root") - before
        #expect(delta == 0)
        try await ExportManagerRenderProbe.change(
          manager: f.manager, counter: f.counter, in: f.window
        ) {
          f.manager.cancelAndClear()
        }
        #expect(
          await observe(in: f.window) { exportControl(f)?.isAccessibilityEnabled?() == true })
      } cleanup: {
        await f.close()
      }
    }

    /// Fails before property-specific manager observation: neither write changes root content.
    @Test func libraryRootSkipsPauseAndVideoLayout() async throws {
      let f = try await Fixture()
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
      let f = try await Fixture(whatsNewSeen: false)
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
      let f = try await Fixture(selectFolder: state == .destination, onboardingComplete: false)
      try await withCleanup {
        if state == .records {
          f.timeline.markVariantExported(
            assetId: "existing", variant: .original, year: 2026, month: 9, relPath: "2026/09/",
            filename: "EXISTING.JPG", exportedAt: Date())
          f.timeline.flushPendingNotifications()
        }
        #expect(f.defaults.bool(forKey: "hasCompletedOnboarding") == false)
        f.show(.content)
        if state == .neither {
          try #require(await observe(in: f.window) { f.counter.count(for: "content-root") > 0 })
          try await f.barrier()
          _ = try f.onboardingActionPixels()
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
