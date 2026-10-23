import AppKit
import SwiftUI
import Testing

@testable import Photo_Export

#if DEBUG
  @MainActor
  @Suite(.serialized, .timeLimit(.minutes(2)))
  struct RecordStoreViewObservationTests {
    private enum Surface { case month, year, sidebars }

    @MainActor
    private final class Tick: ObservableObject {
      @Published var value = 0
    }

    private struct RenderProbe: View {
      @ObservedObject var tick: Tick
      let counter: BodyInvalidationCounter
      var body: some View {
        // swiftlint:disable:next redundant_discardable_let
        let _ = counter.record("render-tick:\(tick.value)")
        Color.clear.frame(width: 1, height: 1)
      }
    }

    private struct Host: View {
      let surface: Surface
      let service: FakePhotoLibraryService
      let manager: ExportManager
      @State private var selectedAsset: AssetDescriptor?
      @State private var selection: LibrarySelection?
      @State private var collectionSelection: Set<LibrarySelection> = []

      var body: some View {
        switch surface {
        case .month:
          MonthContentView(
            year: 2026, month: 9, versionSelection: .edited, livePhotosPaired: false,
            onExportMonth: {}, selectedAsset: $selectedAsset, photoLibraryService: service)
        case .year:
          YearContentView(
            year: 2026, selection: $selection, selectedAsset: $selectedAsset,
            photoLibraryService: service)
        case .sidebars:
          HStack {
            VStack {
              YearRow(
                year: 2026, totalAssets: 2, totalCountsByMonth: [9: 2],
                adjustedCountsByMonth: [9: 0])
              MonthRow(year: 2026, month: 9, total: 2, adjusted: 0)
              Spacer()
            }.frame(width: 260)
            CollectionsSidebarView(selectionSet: $collectionSelection, exportManager: manager)
              .frame(width: 300)
          }
        }
      }
    }

    @MainActor
    private final class Fixture {
      let root = TestScratch.directory("RecordStoreViewObservation")
      let suite = TestScratch.suiteName("RecordStoreViewObservation")
      let defaults: UserDefaults
      let service = FakePhotoLibraryService()
      let library: PhotoLibraryManager
      let clock = TestClock()
      let timeline: ExportRecordStore
      let collections: CollectionExportRecordStore
      let manager: ExportManager
      let destination = FakeExportDestination()
      let destinationManager: ExportDestinationManager
      let autoSync = AutoSyncManager()
      let counter = BodyInvalidationCounter()
      let tick = Tick()
      let window: NSWindow
      let album: ExportPlacement

      init(_ surface: Surface) {
        defaults = TestScratch.defaults(suiteName: suite)
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 15))!
        let assets = ["first", "second"].map {
          TestAssetFactory.makeAsset(id: $0, creationDate: date)
        }
        let context = CGContext(
          data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.blue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let cover = NSImage(cgImage: context.makeImage()!, size: NSSize(width: 16, height: 16))
        for asset in assets { service.hqThumbnailsByAssetId[asset.id] = cover }
        service.assetsByYearMonth["2026-9"] = assets
        service.favoritesAssets = assets
        service.yearCounts = [(2026, 2)]
        let child = PhotoCollectionDescriptor(
          id: "album:trip", localIdentifier: "trip", title: "Trip", kind: .album,
          pathComponents: ["Trips"], children: [])
        service.collectionTree = [
          PhotoCollectionDescriptor(
            id: "folder:trips", localIdentifier: "trips", title: "Trips", kind: .folder,
            pathComponents: [], children: [child])
        ]
        service.assetsByAlbumLocalId["trip"] = assets
        library = PhotoLibraryManager(overrideService: service)
        timeline = ExportRecordStore(baseDirectoryURL: root, notificationClock: clock)
        collections = CollectionExportRecordStore(baseDirectoryURL: root, notificationClock: clock)
        timeline.configure(for: "A")
        collections.configure(for: "A")
        album = try! ExportPlacementResolver().placement(
          for: .album(collectionId: "trip"), collections: service.collectionTree,
          existingPlacements: [])
        collections.upsertPlacement(.favorites())
        collections.upsertPlacement(album)
        collections.flushPendingNotifications()
        manager = ExportManager(
          photoLibraryService: service, exportDestination: destination,
          exportRecordStore: timeline, collectionExportRecordStore: collections,
          assetResourceWriter: FakeAssetResourceWriter(), fileSystem: FakeFileSystem(),
          userDefaults: defaults)
        destinationManager = ExportDestinationManager(skipRestore: true, userDefaults: defaults)
        destinationManager.configureForScreenshotMode()
        window = HostedViewHarness.makeWindow(
          contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 700),
          styleMask: [.borderless])
        // The deterministic stores need their own clock; the shared window factory still applies.
        let content = Host(surface: surface, service: service, manager: manager)
          .overlay(alignment: .topLeading) { RenderProbe(tick: tick, counter: counter) }
          .environment(library).environment(timeline).environment(collections)
          .environment(manager).environment(manager.progressState)
          .environmentObject(destinationManager).environmentObject(autoSync)
          .environment(\.bodyInvalidationCounter, counter).defaultAppStorage(defaults)
        window.contentView = NSHostingView(rootView: content)
        window.orderFront(nil)
      }

      func quiesce() async {
        var awaited = 0
        while awaited < counter.tasks.count {
          let pending = counter.tasks[awaited...]
          awaited = counter.tasks.count
          for task in pending { _ = await finished(task) }
        }
        window.contentView?.layoutSubtreeIfNeeded()
      }

      func barrier() async throws {
        tick.value += 1
        let key = "render-tick:\(tick.value)"
        try #require(await observe(in: window) { counter.count(for: key) > 0 })
        await quiesce()
      }

      func write(_ id: String, collection: Bool = false) {
        if collection {
          for placement in [ExportPlacement.favorites(), album] {
            collections.markVariantExported(
              assetId: id, placement: placement, variant: .original, filename: "\(id).JPG",
              exportedAt: clock.now())
          }
        } else {
          timeline.markVariantExported(
            assetId: id, variant: .original, year: 2026, month: 9, relPath: "2026/09/",
            filename: "\(id).JPG", exportedAt: clock.now())
        }
      }

      func count(_ key: String) -> Int {
        if key == "MonthContentView" {
          // Selection changes the suffix; every body records exactly one of these local keys.
          return counter.snapshot().filter { $0.key.hasPrefix("selected:") }.values.reduce(0, +)
        }
        return counter.count(for: key)
      }

      func measure(_ keys: [String]) -> [String: Int] {
        let values = Dictionary(uniqueKeysWithValues: keys.map { ($0, count($0)) })
        for (key, value) in values { #expect(value > 0, "Mounted body must be counted: \(key)") }
        return values
      }

      func expectBodies(_ before: [String: Int], atMost limit: Int) {
        for (key, value) in before { #expect(count(key) - value <= limit, "\(key)") }
      }

      func bitmap() -> NSBitmapImageRep? {
        guard let view = window.contentView,
          let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
      }

      /// The only blue pixels are the two controlled covers in the mounted month tile.
      func coverRegion() -> CGRect? {
        guard let bitmap = bitmap() else { return nil }
        var xs: [Int] = [], ys: [Int] = []
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
          for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            if color.blueComponent > 0.7 && color.redComponent < 0.2 && color.greenComponent < 0.2 {
              xs.append(x)
              ys.append(y)
            }
          }
        }
        guard xs.count > 200, let left = xs.min(), let right = xs.max(),
          let top = ys.min(), let bottom = ys.max()
        else { return nil }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
      }

      func greenPixels(in region: CGRect) -> Int {
        guard let bitmap = bitmap() else { return 0 }
        var count = 0
        for y in Int(region.minY)...Int(region.maxY) {
          for x in Int(region.minX)...Int(region.maxX) {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            if color.greenComponent > 0.35
              && color.greenComponent > color.redComponent + 0.15
              && color.greenComponent > color.blueComponent + 0.15
            {
              count += 1
            }
          }
        }
        return count
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

    /// Passes before: badges change only when the coalesced record publication reaches the grid.
    @Test func monthPaneRendersOncePerRecordPublication() async throws {
      let f = Fixture(.month)
      try await withCleanup {
        try #require(
          await observe(in: f.window) {
            f.counter.renderedText["month-summary"] == ["0/2 exported"]
              && ["first", "second"].allSatisfy {
                f.counter.renderedText["thumbnail-exported:\($0)"] == ["false"]
              }
          })
        await f.quiesce()
        let before = f.measure(["MonthContentView"])
        for id in ["first", "second"] {
          f.write(id)
          try await f.barrier()
          f.expectBodies(before, atMost: 0)
        }
        f.clock.advance(by: 0.201)
        try #require(
          await observe(in: f.window) {
            f.counter.renderedText["month-summary"] == ["2/2 exported"]
              && ["first", "second"].allSatisfy {
                f.counter.renderedText["thumbnail-exported:\($0)"] == ["true"]
              }
          })
        try await f.barrier()
        f.expectBodies(before, atMost: 1)
      } cleanup: {
        await f.close()
      }
    }

    /// Passes before: the lazy month tile updates without extra parent-body evaluations.
    @Test func yearPaneTilesFollowRecordsOncePerPublication() async throws {
      let f = Fixture(.year)
      try await withCleanup {
        try #require(
          await observe(in: f.window) {
            f.counter.renderedText["year-summary"] == ["2 photos"] && f.coverRegion() != nil
          })
        let cover = try #require(f.coverRegion())
        #expect(f.greenPixels(in: cover) == 0)
        await f.quiesce()
        let before = f.measure(["year-content-body:2026"])
        for id in ["first", "second"] {
          f.write(id)
          try await f.barrier()
          f.expectBodies(before, atMost: 0)
        }
        f.clock.advance(by: 0.201)
        try #require(await observe(in: f.window) { f.greenPixels(in: cover) > 5 })
        try await f.barrier()
        f.expectBodies(before, atMost: 1)
      } cleanup: {
        await f.close()
      }
    }

    /// Passes before: each store refreshes its own rows and leaves the other sidebar quiet.
    @Test func sidebarRowsRenderOncePerOwnRecordPublication() async throws {
      let f = Fixture(.sidebars)
      try await withCleanup {
        try #require(
          await observe(in: f.window) {
            f.counter.renderedText["timeline-month:2026-9"] == ["2"]
              && f.counter.renderedText["collection-sidebar:favorites"] == ["notStarted(total: 2)"]
              && f.counter.renderedText["folder-sidebar:folder:trips"] == ["notStarted(total: 2)"]
          })
        await f.quiesce()
        let timelineKeys = ["timeline-month-body:2026-9", "timeline-year-body:2026"]
        let collectionKeys = ["collection-row-body:favorites", "folder-row-body:folder:trips"]
        for collection in [false, true] {
          let own = f.measure(collection ? collectionKeys : timelineKeys)
          let sibling = f.measure(collection ? timelineKeys : collectionKeys)
          for id in ["first", "second"] {
            f.write(id, collection: collection)
            try await f.barrier()
            f.expectBodies(own, atMost: 0)
            f.expectBodies(sibling, atMost: 0)
          }
          f.clock.advance(by: 0.201)
          try #require(
            await observe(in: f.window) {
              collection
                ? f.counter.renderedText["collection-sidebar:favorites"] == ["complete"]
                  && f.counter.renderedText["folder-sidebar:folder:trips"] == ["complete"]
                : f.counter.renderedText["timeline-month:2026-9"] == ["complete"]
                  && f.counter.renderedText["timeline-year:2026"] == ["complete"]
            })
          try await f.barrier()
          f.expectBodies(own, atMost: 1)
          f.expectBodies(sibling, atMost: 0)
        }
      } cleanup: {
        await f.close()
      }
    }
  }
#endif
