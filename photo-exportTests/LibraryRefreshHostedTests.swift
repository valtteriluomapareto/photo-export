import AppKit
import Observation
import SwiftUI
import Testing

@testable import Photo_Export

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct LibraryRefreshHostedTests {
  @Observable @MainActor final class Phase { var value = 0 }

  private struct Probe: View {
    let phase: Phase
    let counter: BodyInvalidationCounter
    var body: some View {
      // swiftlint:disable:next redundant_discardable_let
      let _ = counter.record("refresh-barrier:\(phase.value)")
      Color.clear.frame(width: 1, height: 1)
    }
  }

  private struct Host: View {
    let service: FakePhotoLibraryService
    let manager: ExportManager
    let phase: Phase
    let counter: BodyInvalidationCounter
    let collections: Bool
    @State private var selection: Set<LibrarySelection> = []
    @State private var asset: AssetDescriptor?
    var body: some View {
      HStack {
        if collections {
          CollectionsSidebarView(selectionSet: $selection, exportManager: manager)
        } else {
          TimelineSidebarView(selectionSet: $selection, photoLibraryService: service)
          MonthContentView(
            year: 2026, month: 9, versionSelection: .edited, livePhotosPaired: false,
            onExportMonth: {}, selectedAsset: $asset, photoLibraryService: service)
        }
        Probe(phase: phase, counter: counter)
      }
    }
  }

  @MainActor private final class Fixture {
    let service = FakePhotoLibraryService()
    let clock = TestClock()
    let library: PhotoLibraryManager
    let export: ExportManagerHarness
    let counter = BodyInvalidationCounter()
    let phase = Phase()
    let window: NSWindow

    init(collections: Bool = false) async {
      let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 15))!
      let assets = [TestAssetFactory.makeAsset(id: "A", creationDate: date)]
      service.assetsByYearMonth["2026-9"] = assets
      service.yearCounts = [(2026, 1)]
      service.favoritesAssets = assets
      service.collectionTree = [
        PhotoCollectionDescriptor(
          id: "album:family", localIdentifier: "family", title: "Family", kind: .album,
          pathComponents: [], children: [])
      ]
      service.assetsByAlbumLocalId["family"] = assets
      library = PhotoLibraryManager(overrideService: service, refreshClock: clock)
      export = await ExportManagerHarness(label: "LibraryRefreshHosted", photoLib: service)
      let destination = ExportDestinationManager(skipRestore: true, userDefaults: export.defaults)
      let harness = HostedViewHarness(
        library: library, export: export, destination: destination, autoSync: AutoSyncManager(),
        whatsNew: WhatsNewState(userDefaults: export.defaults, currentVersion: "test", catalog: []))
      window = HostedViewHarness.makeWindow(
        contentRect: NSRect(x: -10000, y: -10000, width: 900, height: 700), styleMask: [.borderless]
      )
      window.contentView = NSHostingView(
        rootView: harness.environment(
          Host(
            service: service, manager: export.manager, phase: phase, counter: counter,
            collections: collections)
        )
        .environment(\.bodyInvalidationCounter, counter).defaultAppStorage(export.defaults))
    }

    func show() { window.orderFront(nil) }

    func barrier() async throws {
      phase.value += 1
      let key = "refresh-barrier:\(phase.value)"
      try #require(await observe(in: window) { counter.count(for: key) > 0 })
    }

    func close() async {
      window.orderOut(nil)
      window.contentView = nil
      window.close()
      library.libraryRefresh.flush()
      export.manager.cancelAndClear()
      export.store.drainSynchronously()
      export.collectionStore.drainSynchronously()
      export.dest.cleanup()
    }
  }

  @Test func fiveInvalidationsProduceOneGridRefreshAndInventoryLoad() async throws {
    let f = await Fixture()
    try await withCleanup {
      f.show()
      try #require(
        await observe(in: f.window) {
          f.counter.renderedText["timeline-sidebar-years"] == ["2026:1"]
            && f.counter.renderedText["month-summary"] != nil
            && f.service.scopeFetchCalls.count == 1
        })
      let inventory = f.service.inventoryThreads.value["years"]?.count ?? 0
      let fetches = f.service.scopeFetchCalls.count
      for _ in 0..<5 {
        f.library.invalidateCache(changedThumbnailAssetIDs: [])
        try await f.barrier()
      }
      #expect(f.library.libraryRevision == 5)
      #expect(f.service.scopeFetchCalls.count == fetches)
      #expect(f.service.inventoryThreads.value["years"]?.count == inventory)
      f.clock.advance(by: 0.5)
      try #require(
        await observe(in: f.window) {
          f.counter.count(for: "grid-refresh-finished") >= 1
            && (f.service.inventoryThreads.value["years"]?.count ?? 0) >= inventory + 1
        })
      try await f.barrier()
      #expect(f.service.scopeFetchCalls.count == fetches + 1)
      #expect(f.counter.count(for: "grid-refresh-finished") == 1)
      #expect(f.service.inventoryThreads.value["years"]?.count == inventory + 1)
      let query = PhotoLibraryQuery(scope: .timeline(year: 2026, month: 9))
      f.library.invalidateCache(changedThumbnailAssetIDs: [], queryChanges: [query: false])
      f.clock.advance(by: 0.5)
      try #require(
        await observe(in: f.window) {
          (f.service.inventoryThreads.value["years"]?.count ?? 0) >= inventory + 2
        })
      try await f.barrier()
      #expect(f.service.scopeFetchCalls.count == fetches + 1)
    } cleanup: {
      await f.close()
    }
  }

  @Test func countBatchRendersOnceAndNeverPublishesPartialCounts() async throws {
    let f = await Fixture(collections: true)
    let favorite = AsyncCheckpoint()
    let album = AsyncCheckpoint()
    try await withCleanup {
      f.show()
      try #require(
        await observe(in: f.window) {
          f.counter.renderedText["collection-sidebar:album:family"] == ["count:1"]
        })
      f.service.cachedCountOverride = { scope, _ in
        await (scope == .favorites ? favorite : album).enter()
        return 3
      }
      f.library.invalidateCache(changedThumbnailAssetIDs: [])
      f.library.libraryRefresh.flush()
      await favorite.waitForEnter(count: 1)
      await album.waitForEnter(count: 1)
      try await f.barrier()
      let bodies = f.counter.count(for: "collections-sidebar")
      let consumed = f.counter.count(for: "collection-count-result")
      await favorite.releaseAll()
      try #require(
        await observe(in: f.window) {
          f.counter.count(for: "collection-count-result") > consumed
        })
      try await f.barrier()
      #expect(f.counter.count(for: "collections-sidebar") - bodies == 0)
      await album.releaseAll()
      try #require(
        await observe(in: f.window) {
          f.counter.renderedText["collection-sidebar:album:family"] == ["count:3"]
            && f.counter.renderedText["collection-sidebar:favorites"] == ["count:3"]
        })
      try await f.barrier()
      #expect(f.counter.count(for: "collections-sidebar") - bodies <= 1)
    } cleanup: {
      await favorite.releaseAll()
      await album.releaseAll()
      await f.close()
    }
  }
}
