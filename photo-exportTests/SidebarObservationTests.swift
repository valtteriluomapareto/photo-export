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
        let _ = counter.record("queue:\(manager.queueCount)")
        Color.clear.frame(width: 1, height: 1)
      }
    }

    @MainActor
    private struct Host: View {
      let manager: ExportManager
      let service: FakePhotoLibraryService
      let counter: BodyInvalidationCounter
      @State private var timelineSelection: Set<LibrarySelection> = []
      @State private var collectionSelection: Set<LibrarySelection> = []
      var body: some View {
        HStack {
          TimelineSidebarView(
            selectionSet: $timelineSelection, photoLibraryService: service).frame(width: 260)
          CollectionsSidebarView(selectionSet: $collectionSelection).frame(width: 260)
          QueueProbe(manager: manager, counter: counter)
        }
      }
    }

    @MainActor
    private final class Fixture {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let suite = "SidebarObservation-\(UUID().uuidString)"
      let defaults: UserDefaults
      let service = FakePhotoLibraryService()
      let library: PhotoLibraryManager
      let timeline: ExportRecordStore
      let collections: CollectionExportRecordStore
      let manager: ExportManager
      let destination = FakeExportDestination()
      let counter = BodyInvalidationCounter()
      let window: NSWindow

      init() {
        defaults = UserDefaults(suiteName: suite)!
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 15))!
        let assets = ["first", "second"].map {
          TestAssetFactory.makeAsset(id: $0, creationDate: date)
        }
        service.assetsByYearMonth["2026-9"] = assets
        service.favoritesAssets = assets
        service.yearCounts = [(2026, 2)]
        library = PhotoLibraryManager(overrideService: service)
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
        let content = Host(manager: manager, service: service, counter: counter)
          .environmentObject(library).environmentObject(timeline)
          .environmentObject(collections).environmentObject(manager)
          .environment(\.bodyInvalidationCounter, counter).defaultAppStorage(defaults)
        window = NSWindow(
          contentRect: NSRect(x: -10_000, y: -10_000, width: 560, height: 500),
          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        window.orderFront(nil)
      }

      func barrier() async {
        window.contentView?.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(30))
        window.contentView?.layoutSubtreeIfNeeded()
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

    private func observe(_ condition: () -> Bool) async -> Bool {
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: .seconds(10))
      while !condition(), clock.now < deadline, !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(10))
      }
      return condition()
    }

    @Test(.timeLimit(.minutes(1)))
    func queuePublicationsAvoidTimelineWorkAndRealSidebarChangesStillRefresh() async throws {
      let f = Fixture()
      var failure: Error?
      do {
        try #require(await observe {
          f.counter.renderedText["timeline-sidebar-years"] == ["2026:2"]
            && f.counter.renderedText["collection-sidebar:favorites"]
              == [String(describing: CollectionSidebarBadge.State.notStarted(total: 2))]
        })
        await f.barrier()
        let timelineBodies = f.counter.count(for: "timeline-sidebar-body")
        try #require(timelineBodies > 0)
        for index in 1...5 {
          let key = "queue:\(index)"
          let before = f.counter.count(for: key)
          f.manager.queueCoordinator.enqueue([
            .init(
              assetLocalIdentifier: "unrelated-\(index)", placement: .timeline(year: 2026, month: 9),
              selection: .edited)
          ])
          try #require(await observe { f.counter.count(for: key) > before })
          await f.barrier()
          #expect(f.counter.count(for: "timeline-sidebar-body") == timelineBodies)
        }
        f.collections.markVariantExported(
          assetId: "first", placement: .favorites(), variant: .original,
          filename: "FIRST.JPG", exportedAt: Date())
        f.collections.flushPendingNotifications()
        #expect(await observe {
          f.counter.renderedText["collection-sidebar:favorites"]
            == [String(describing: CollectionSidebarBadge.State.partial(exported: 1, total: 2))]
        })
        f.service.yearCounts = [(2027, 3), (2026, 2)]
        f.library.invalidateCache()
        #expect(await observe {
          f.counter.renderedText["timeline-sidebar-years"] == ["2027:3", "2026:2"]
        })
      } catch { failure = error }
      await f.close()
      if let failure { throw failure }
    }
  }
#endif
