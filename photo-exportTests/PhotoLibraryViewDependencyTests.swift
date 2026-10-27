import AppKit
import SwiftUI
import Testing

@testable import Photo_Export

#if DEBUG
  @MainActor
  @Suite(.serialized, .timeLimit(.minutes(2)))
  struct PhotoLibraryViewDependencyTests {
    @Observable @MainActor final class YearInput { var year = 2026 }

    private struct YearHost: View {
      var input = YearInput()
      let service: FakePhotoLibraryService
      @State private var selection: LibrarySelection?
      @State private var selectedAsset: AssetDescriptor?
      var body: some View {
        YearContentView(
          year: input.year, selection: $selection, selectedAsset: $selectedAsset,
          photoLibraryService: service)
      }
    }

    @MainActor
    private final class Fixture {
      let service = FakePhotoLibraryService()
      let library: PhotoLibraryManager
      let export: ExportManagerHarness
      let destination: ExportDestinationManager
      let counter = BodyInvalidationCounter()
      let imageGate = AsyncCheckpoint()
      let window: NSWindow

      init() async {
        library = PhotoLibraryManager(overrideService: service)
        export = await ExportManagerHarness(label: "PhotoLibraryViewDependency", photoLib: service)
        destination = ExportDestinationManager(skipRestore: true, userDefaults: export.defaults)
        window = HostedViewHarness.makeWindow(
          contentRect: NSRect(x: -10000, y: -10000, width: 900, height: 700),
          styleMask: [.borderless])
      }

      func show<Content: View>(_ content: Content) {
        let harness = HostedViewHarness(
          library: library, export: export, destination: destination,
          autoSync: AutoSyncManager(),
          whatsNew: WhatsNewState(
            userDefaults: export.defaults, currentVersion: "test", catalog: []))
        window.contentView = NSHostingView(
          rootView: harness.environment(content)
            .environment(\.bodyInvalidationCounter, counter).defaultAppStorage(export.defaults))
        window.orderFront(nil)
      }

      func close() async {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        await imageGate.releaseAll()
        export.manager.cancelAndClear()
        try? await export.store.flush()
        try? await export.collectionStore.flush()
        export.dest.cleanup()
        try? FileManager.default.removeItem(at: export.storeRoot)
      }
    }

    /// Already passes: metadata is reread while the unrelated preview load remains suspended.
    @Test func assetDetailRereadsMetadataAfterALibraryChange() async throws {
      let f = await Fixture()
      f.service.detailsByAssetId["selected"] = AssetDetails(
        originalFilename: "Before.jpg", fileSize: 10, resources: [])
      f.service.fullImageRequestOverride = { [gate = f.imageGate] _ in
        await gate.enter()
        return NSImage(size: NSSize(width: 4, height: 4))
      }
      try await withCleanup {
        f.show(AssetDetailView(asset: TestAssetFactory.makeAsset(id: "selected"), placement: nil))
        await f.imageGate.waitForEnter(count: 1)
        try #require(await observe(in: f.window) { !f.service.detailsFetchCalls.isEmpty })
        let before = f.service.detailsFetchCalls.count
        f.service.detailsByAssetId["selected"] = AssetDetails(
          originalFilename: "After.jpg", fileSize: 20, resources: [])
        f.library.invalidateCache(changedThumbnailAssetIDs: [])
        #expect(await observe(in: f.window) { f.service.detailsFetchCalls.count > before })
      } cleanup: {
        await f.close()
      }
    }

    @Test func yearSummaryNeverShowsThePreviousYearsHeldCount() async throws {
      let f = await Fixture()
      let input = YearInput()
      let gate = AsyncCheckpoint()
      let refreshGate = AsyncCheckpoint()
      f.service.countOverride = { scope in
        if scope == .timeline(year: 2027, month: nil) {
          await gate.enter()
          return 2
        }
        return 1
      }
      try await withCleanup {
        f.show(YearHost(input: input, service: f.service))
        try #require(
          await observe(in: f.window) { f.counter.renderedText["year-summary"] == ["1 photo"] })
        input.year = 2027
        await gate.waitForEnter(count: 1)
        try #require(
          await observe(in: f.window) { f.counter.count(for: "year-content-body:2027") > 0 })
        #expect(f.counter.renderedText["year-summary"] == ["Counting…"])
        await gate.releaseAll()
        #expect(
          await observe(in: f.window) { f.counter.renderedText["year-summary"] == ["2 photos"] })
        f.service.countOverride = { _ in
          await refreshGate.enter()
          return 3
        }
        let rendered = f.counter.count(for: "year-content-body:2027")
        f.library.invalidateCache(changedThumbnailAssetIDs: [])
        f.library.libraryRefresh.flush()
        await refreshGate.waitForEnter(count: 1)
        try #require(
          await observe(in: f.window) {
            f.counter.count(for: "year-content-body:2027") > rendered
          })
        #expect(f.counter.renderedText["year-summary"] == ["2 photos"])
        await refreshGate.releaseAll()
        #expect(
          await observe(in: f.window) { f.counter.renderedText["year-summary"] == ["3 photos"] })
      } cleanup: {
        await refreshGate.releaseAll()
        await gate.releaseAll()
        await f.close()
      }
    }

    /// Already passes: the year total follows library invalidation without remounting.
    @Test func yearSummaryRecountsAfterALibraryChange() async throws {
      let f = await Fixture()
      let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 15))!
      f.service.assetsByYearMonth["2026-9"] = [
        TestAssetFactory.makeAsset(id: "first", creationDate: date)
      ]
      f.service.yearCounts = [(2026, 1)]
      try await withCleanup {
        f.show(YearHost(service: f.service))
        try #require(
          await observe(in: f.window) { f.counter.renderedText["year-summary"] == ["1 photo"] })
        f.service.assetsByYearMonth["2026-9", default: []].append(
          TestAssetFactory.makeAsset(id: "second", creationDate: date))
        f.service.yearCounts = [(2026, 2)]
        f.library.invalidateCache()
        f.library.libraryRefresh.flush()
        #expect(
          await observe(in: f.window) { f.counter.renderedText["year-summary"] == ["2 photos"] })
      } cleanup: {
        await f.close()
      }
    }
  }
#endif
