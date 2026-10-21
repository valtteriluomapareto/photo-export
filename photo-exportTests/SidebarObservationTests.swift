import AppKit
import SwiftUI
import Testing

@testable import Photo_Export

#if DEBUG
  @MainActor
  @Suite(.serialized)
  struct SidebarObservationTests {
    @MainActor
    private struct QueueProbe: View {
      @ObservedObject var manager: ExportManager
      let counter: BodyInvalidationCounter
      var body: some View {
        // A declaration keeps the probe out of ViewBuilder's view expressions.
        // swiftlint:disable:next redundant_discardable_let
        let _ = counter.record("queue:\(manager.queueCount)")
        Color.clear.frame(width: 1, height: 1)
      }
    }

    /// Rebuilds the collections sidebar on every manager or collection-store publication, as
    /// `LibraryRootView` does in production. Its own key shows a publication has rendered.
    @MainActor
    private struct CollectionsHost: View {
      @ObservedObject var manager: ExportManager
      @ObservedObject var collections: CollectionExportRecordStore
      @Binding var selectionSet: Set<LibrarySelection>
      let counter: BodyInvalidationCounter
      var body: some View {
        // A declaration keeps the probe out of ViewBuilder's view expressions.
        // swiftlint:disable:next redundant_discardable_let
        let _ = counter.record(
          "collections-host:\(manager.queueCount):\(collections.mutationCounter)")
        CollectionsSidebarView(selectionSet: $selectionSet, exportManager: manager)
      }
    }

    @MainActor
    private struct Host: View {
      let manager: ExportManager
      let collections: CollectionExportRecordStore
      let service: FakePhotoLibraryService
      let counter: BodyInvalidationCounter
      @State private var timelineSelection: Set<LibrarySelection> = []
      @State private var collectionSelection: Set<LibrarySelection> = []
      var body: some View {
        HStack {
          TimelineSidebarView(
            selectionSet: $timelineSelection, photoLibraryService: service
          ).frame(width: 260)
          CollectionsHost(
            manager: manager, collections: collections, selectionSet: $collectionSelection,
            counter: counter
          ).frame(width: 260)
          QueueProbe(manager: manager, counter: counter)
        }
      }
    }

    @MainActor
    private final class Fixture {
      let root = TestScratch.directory("SidebarObservation")
      let suite = TestScratch.suiteName("SidebarObservation")
      let defaults: UserDefaults
      let service = FakePhotoLibraryService()
      let library: PhotoLibraryManager
      let timeline: ExportRecordStore
      let collections: CollectionExportRecordStore
      let manager: ExportManager
      let destination = FakeExportDestination()
      let counter = BodyInvalidationCounter()
      let window: NSWindow

      init(includeAlbum: Bool = false) {
        defaults = TestScratch.defaults(suiteName: suite)
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 15))!
        let assets = ["first", "second"].map {
          TestAssetFactory.makeAsset(id: $0, creationDate: date)
        }
        service.assetsByYearMonth["2026-9"] = assets
        service.favoritesAssets = assets
        service.yearCounts = [(2026, 2)]
        if includeAlbum {
          service.collectionTree = [
            PhotoCollectionDescriptor(
              id: "album:family", localIdentifier: "family", title: "Family", kind: .album,
              pathComponents: [], children: [])
          ]
          service.assetsByAlbumLocalId["family"] = assets
        }
        let cache = service.collectionCountCache
        let invalidateCounts: (@Sendable () async -> Void)?
        if includeAlbum {
          invalidateCounts = { await cache.invalidateAll() }
        } else {
          invalidateCounts = nil
        }
        library = PhotoLibraryManager(
          overrideService: service, countInvalidationOverride: invalidateCounts)
        timeline = ExportRecordStore(baseDirectoryURL: root)
        collections = CollectionExportRecordStore(baseDirectoryURL: root)
        timeline.configure(for: "A")
        collections.configure(for: "A")
        collections.upsertPlacement(.favorites())
        collections.flushPendingNotifications()
        manager = ExportManager(
          photoLibraryService: service, exportDestination: destination,
          exportRecordStore: timeline, collectionExportRecordStore: collections,
          assetResourceWriter: FakeAssetResourceWriter(), fileSystem: FakeFileSystem(),
          userDefaults: defaults)
        let content = Host(
          manager: manager, collections: collections, service: service, counter: counter
        )
        .environmentObject(library).environmentObject(timeline)
        .environmentObject(collections).environmentObject(manager)
        .environment(manager.progressState)
        .environment(\.bodyInvalidationCounter, counter).defaultAppStorage(defaults)
        window = NSWindow(
          contentRect: NSRect(x: -10_000, y: -10_000, width: 560, height: 500),
          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        window.orderFront(nil)
      }

      /// Awaits every task the sidebars recorded, including ones recorded meanwhile, then lays
      /// out what they published. Rendered readiness does not cover the timeline's initial count
      /// load, whose completion legitimately re-renders the sidebar after the baseline (#293).
      func quiesce() async {
        var awaited = 0
        while awaited < counter.tasks.count {
          let pending = counter.tasks[awaited...]
          awaited = counter.tasks.count
          for task in pending { _ = await finished(task) }
        }
        window.contentView?.layoutSubtreeIfNeeded()
      }

      func changes(since baseline: [String: Int]) -> [String] {
        counter.snapshot().filter { baseline[$0.key] != $0.value }
          .map { "\($0.key): \(baseline[$0.key] ?? 0)→\($0.value)" }.sorted()
      }

      func close() async {
        manager.cancelAndClear()
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        counter.reset()
        try? await timeline.flush()
        try? await collections.flush()
        destination.cleanup()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
      }
    }

    @Test(.timeLimit(.minutes(1)))
    func timelineSidebarClearsOnRevokeAndReloadsOnGrant() async throws {
      let f = Fixture()
      try await withCleanup {
        try #require(
          await observe(in: f.window) {
            f.counter.renderedText["timeline-sidebar-years"] == ["2026:2"]
          })
        await f.quiesce()
        f.service.authorizationStatus = .denied
        f.service.isAuthorized = false
        f.library.refreshAuthorizationStatus()
        try #require(
          await observe(in: f.window) { f.counter.renderedText["timeline-sidebar-years"] == [] })
        f.service.authorizationStatus = .authorized
        f.service.isAuthorized = true
        f.library.refreshAuthorizationStatus()
        #expect(
          await observe(in: f.window) {
            f.counter.renderedText["timeline-sidebar-years"] == ["2026:2"]
          })
      } cleanup: {
        await f.close()
      }
    }

    @Test(.timeLimit(.minutes(1)))
    func collectionRowCountsReloadAfterALibraryChange() async throws {
      let f = Fixture(includeAlbum: true)
      try await withCleanup {
        try #require(
          await observe(in: f.window) {
            f.counter.renderedText["collection-sidebar:favorites"]
              == [String(describing: CollectionSidebarBadge.State.notStarted(total: 2))]
              && f.counter.renderedText["collection-sidebar:album:family"] == ["count:2"]
          })
        await f.quiesce()
        let extra = TestAssetFactory.makeAsset(id: "extra")
        f.service.favoritesAssets.append(extra)
        f.service.assetsByAlbumLocalId["family", default: []].append(extra)
        f.library.invalidateCache(changedThumbnailAssetIDs: [])
        #expect(
          await observe(in: f.window) {
            f.counter.renderedText["collection-sidebar:favorites"]
              == [String(describing: CollectionSidebarBadge.State.notStarted(total: 3))]
              && f.counter.renderedText["collection-sidebar:album:family"] == ["count:3"]
          })
      } cleanup: {
        await f.close()
      }
    }

    @Test(.timeLimit(.minutes(1)))
    func queuePublicationsAvoidTimelineWorkAndRealSidebarChangesStillRefresh() async throws {
      let f = Fixture()
      var failure: Error?
      do {
        try #require(
          await observe {
            f.counter.renderedText["timeline-sidebar-years"] == ["2026:2"]
              && f.counter.renderedText["collection-sidebar:favorites"]
                == [String(describing: CollectionSidebarBadge.State.notStarted(total: 2))]
          })
        await f.quiesce()
        let timelineBodies = f.counter.count(for: "timeline-sidebar-body")
        let baseline = f.counter.snapshot()
        try #require(timelineBodies > 0)
        for index in 1...5 {
          let key = "queue:\(index)"
          let before = f.counter.count(for: key)
          f.manager.queueCoordinator.enqueue([
            .init(
              assetLocalIdentifier: "unrelated-\(index)",
              placement: .timeline(year: 2026, month: 9),
              selection: .edited)
          ])
          try #require(await observe { f.counter.count(for: key) > before })
          await f.quiesce()
          #expect(
            f.counter.count(for: "timeline-sidebar-body") == timelineBodies,
            "Changes since baseline: \(f.changes(since: baseline))")
        }
        f.collections.markVariantExported(
          assetId: "first", placement: .favorites(), variant: .original,
          filename: "FIRST.JPG", exportedAt: Date())
        f.collections.flushPendingNotifications()
        #expect(
          await observe {
            f.counter.renderedText["collection-sidebar:favorites"]
              == [String(describing: CollectionSidebarBadge.State.partial(exported: 1, total: 2))]
          })
        f.service.yearCounts = [(2027, 3), (2026, 2)]
        f.library.invalidateCache()
        #expect(
          await observe {
            f.counter.renderedText["timeline-sidebar-years"] == ["2027:3", "2026:2"]
          })
      } catch { failure = error }
      await f.close()
      if let failure { throw failure }
    }

    @Test(.timeLimit(.minutes(1)))
    func queueAndRecordPublicationsSkipTheCollectionsSidebarBody() async throws {
      let f = Fixture()
      try await withCleanup {
        try #require(
          await observe {
            f.counter.renderedText["collection-sidebar:favorites"]
              == [String(describing: CollectionSidebarBadge.State.notStarted(total: 2))]
          })
        let album = ExportPlacement(
          kind: .album, id: "unrelated-album", displayName: "Unrelated",
          collectionLocalIdentifier: "unrelated-album", relativePath: "Collections/Unrelated/",
          createdAt: Date(timeIntervalSince1970: 0))
        f.collections.upsertPlacement(album)
        f.collections.flushPendingNotifications()
        let placed = "collections-host:0:\(f.collections.mutationCounter)"
        try #require(await observe { f.counter.count(for: placed) > 0 })
        await f.quiesce()
        let sidebarBodies = f.counter.count(for: "collections-sidebar")
        let baseline = f.counter.snapshot()
        try #require(sidebarBodies > 0)
        f.manager.queueCoordinator.enqueue([
          .init(assetLocalIdentifier: "unrelated", placement: .favorites(), selection: .edited)
        ])
        let queued = "collections-host:1:\(f.collections.mutationCounter)"
        try #require(await observe { f.counter.count(for: queued) > 0 })
        await f.quiesce()
        #expect(
          f.counter.count(for: "collections-sidebar") == sidebarBodies,
          "Changes since baseline: \(f.changes(since: baseline))")
        let revision = f.collections.mutationCounter
        f.collections.markVariantExported(
          assetId: "unrelated", placement: album, variant: .original, filename: "UNRELATED.JPG",
          exportedAt: Date())
        f.collections.flushPendingNotifications()
        try #require(f.collections.mutationCounter > revision)
        let recorded = "collections-host:1:\(f.collections.mutationCounter)"
        try #require(await observe { f.counter.count(for: recorded) > 0 })
        await f.quiesce()
        #expect(
          f.counter.count(for: "collections-sidebar") == sidebarBodies,
          "Changes since baseline: \(f.changes(since: baseline))")
        f.library.invalidateCache()
        #expect(await observe { f.counter.count(for: "collections-sidebar") > sidebarBodies })
      } cleanup: {
        await f.close()
      }
    }
  }
#endif
