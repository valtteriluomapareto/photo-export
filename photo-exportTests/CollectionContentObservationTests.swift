import AppKit
import SwiftUI
import Testing

@testable import Photo_Export

#if DEBUG
  @MainActor
  @Suite(.serialized)
  struct CollectionContentObservationTests {
    @MainActor
    private final class Navigation: ObservableObject {
      @Published var selection: LibrarySelection = .favorites
      @Published var title = "Favorites"
      @Published var asset: AssetDescriptor?
    }

    @MainActor
    private struct Parent: View {
      @ObservedObject var manager: ExportManager
      @ObservedObject var navigation: Navigation
      let service: FakePhotoLibraryService
      let counter: BodyInvalidationCounter

      var body: some View {
        // A declaration keeps the probe out of ViewBuilder's view expressions.
        // swiftlint:disable:next redundant_discardable_let
        let _ = counter.record("parent:\(manager.queueCount)")
        let scope = navigation.selection
        let pane = CollectionContentView(
          selection: navigation.selection, title: navigation.title,
          versionSelection: manager.versionSelection,
          livePhotosPaired: manager.livePhotosPairedExport,
          onExportCollection: {
            switch scope {
            case .favorites: manager.startExportFavorites()
            case .album(let id): manager.startExportAlbum(collectionId: id)
            case .sharedAlbum(let id): manager.startExportSharedAlbum(collectionId: id)
            default: break
            }
          },
          selectedAsset: $navigation.asset, photoLibraryService: service
        )
        pane.equatable()
      }
    }

    @MainActor
    private final class Fixture {
      let navigation = Navigation()
      let counter = BodyInvalidationCounter()
      let clock = TestClock()
      let service: FakePhotoLibraryService
      let library: PhotoLibraryManager
      let manager: ExportManager
      let timeline: ExportRecordStore
      let records: CollectionExportRecordStore
      let destination: ExportDestinationManager
      let fakeDestination = FakeExportDestination()
      let root = TestScratch.directory("CollectionContentObservation")
      let defaultsName = TestScratch.suiteName("CollectionObservation")
      let defaults: UserDefaults
      let window: NSWindow
      let favorite = ExportPlacement.favorites()

      init() {
        service = BulkLibraryFixture.makeFakeLibrary(
          timelineAssets: 0,
          albumFolders: 1, albumsPerFolder: 1, assetsPerAlbum: 10_000)
        service.favoritesAssets = service.assetsByAlbumLocalId["bulk-album-0-0"]!
        library = PhotoLibraryManager(overrideService: service)
        defaults = TestScratch.defaults(suiteName: defaultsName)
        timeline = ExportRecordStore(baseDirectoryURL: root)
        records = CollectionExportRecordStore(baseDirectoryURL: root, notificationClock: clock)
        timeline.configure(for: "test")
        records.configure(for: "test")
        records.upsertPlacement(favorite)
        manager = ExportManager(
          photoLibraryService: service, exportDestination: fakeDestination,
          exportRecordStore: timeline, collectionExportRecordStore: records,
          assetResourceWriter: FakeAssetResourceWriter(), fileSystem: FakeFileSystem(),
          userDefaults: defaults)
        destination = ExportDestinationManager(skipRestore: true, userDefaults: defaults)
        // Deliver the coalesced setup publication now so it cannot land after a test's baseline.
        records.flushPendingNotifications()
        let hosted = NSHostingView(
          rootView: Parent(
            manager: manager, navigation: navigation,
            service: service, counter: counter
          )
          .environmentObject(library).environment(records).environmentObject(manager)
          .environmentObject(destination).environment(\.bodyInvalidationCounter, counter))
        window = NSWindow(
          contentRect: NSRect(x: -10_000, y: -10_000, width: 600, height: 400),
          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosted
      }

      func show() { window.orderFront(nil) }

      func close() {
        manager.cancelAndClear()
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        counter.reset()  // Release captured action closures after dismantling the host.
        timeline.drainSynchronously()
        records.drainSynchronously()
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: defaultsName)
        fakeDestination.cleanup()
      }

      func renderBarrier() async {
        window.contentView?.layoutSubtreeIfNeeded()
        // Let the acknowledged parent transaction commit its children through AppKit.
        try? await Task.sleep(for: .milliseconds(30))
        window.contentView?.layoutSubtreeIfNeeded()
      }

      var readinessDescription: String {
        "summary=\(counter.count(for: "summary:0/10000")), "
          + "scans=\(counter.count(for: "summaryScan")), "
          + "bodies=\(counter.count(for: "collectionBody")), "
          + "preheatStarts=\(service.startCachingCalls.count)"
      }
    }

    /// Unrelated queue publications must not re-render the pane, through either its inputs (the
    /// `CollectionContentView.==` conformance) or its observations. SwiftUI currently applies the
    /// view's Equatable conformance even without `.equatable()`, so removing the parent's
    /// modifier alone doesn't fail this.
    @Test(.timeLimit(.minutes(2)))
    func unrelatedQueuePublicationsDoNotRescanLoadedCollection() async throws {
      let f = Fixture()
      defer { f.close() }
      f.show()
      let loaded = await observe(in: f.window) {
        f.counter.count(for: "summary:0/10000") > 0 && f.service.startCachingCalls.count == 1
      }
      let diagnostics = f.readinessDescription
      try #require(
        loaded, "Must measure a loaded collection with an actual matching placement: \(diagnostics)"
      )
      await f.renderBarrier()
      let scans = f.counter.count(for: "summaryScan")
      let bodies = f.counter.count(for: "collectionBody")
      let revision = f.records.mutationCounter
      try #require(scans > 0)
      for index in 1...10 {
        let key = "parent:\(index)"
        let parent = f.counter.count(for: key)
        f.manager.progressState.currentAssetFilename = "unrelated-\(index).JPG"
        f.manager.progressState.totalJobsCompleted = index
        f.manager.queueCoordinator.enqueue([
          ExportManager.ExportJob(
            assetLocalIdentifier: "unrelated-\(index)",
            placement: .timeline(year: 2025, month: 1), selection: .edited)
        ])
        let acknowledged = await observe(in: f.window) { f.counter.count(for: key) > parent }
        try #require(acknowledged, "Parent must process the actual queue-count publication")
        await f.renderBarrier()
      }
      // Surface any record publication still inside its coalescing window.
      f.records.flushPendingNotifications()
      await f.renderBarrier()
      #expect(f.records.mutationCounter == revision, "record publication during the loop")
      let extraScans = f.counter.count(for: "summaryScan") - scans
      let extraBodies = f.counter.count(for: "collectionBody") - bodies
      #expect(extraScans == 0)
      #expect(extraBodies == 0)
    }
  }
#endif

#if DEBUG
  extension CollectionContentObservationTests {
    @Test(.timeLimit(.minutes(2)))
    func settingsRecordsMembershipAndLiveBindingStillRender() async throws {
      let f = Fixture()
      defer { f.close() }
      let adjusted = TestAssetFactory.makeAsset(
        id: "adjusted", creationDate: Date(timeIntervalSince1970: 1_700_000_000),
        hasAdjustments: true)
      let live = TestAssetFactory.makeAsset(
        id: "live", creationDate: Date(timeIntervalSince1970: 1_700_086_400),
        isLivePhoto: true)
      let plain = TestAssetFactory.makeAsset(id: "plain")
      f.service.favoritesAssets = [adjusted, live, plain]
      f.records.markVariantExported(
        assetId: adjusted.id, placement: f.favorite, variant: .edited,
        filename: "ADJUSTED.JPG", exportedAt: Date())
      for asset in [live, plain] {
        f.records.markVariantExported(
          assetId: asset.id, placement: f.favorite, variant: .original,
          filename: "IMG.JPG", exportedAt: Date())
      }
      f.records.flushPendingNotifications()
      f.show()
      let initial = await observe(in: f.window) {
        f.counter.count(for: "summary:3/3") > 0 && f.counter.count(for: "selected:adjusted") > 0
      }
      try #require(initial)
      let selectedBefore = f.counter.count(for: "selected:live")
      f.navigation.asset = live
      let rebound = await observe(in: f.window) {
        f.counter.count(for: "selected:live") > selectedBefore
      }
      try #require(rebound, "A live binding change must update the pane's selected-thumbnail input")
      #expect(f.navigation.asset == live)

      f.manager.versionSelection = .editedWithOriginals
      let originals = await observe(in: f.window) { f.counter.count(for: "summary:2/3") > 0 }
      try #require(originals)
      f.manager.livePhotosPairedExport = true
      let paired = await observe(in: f.window) { f.counter.count(for: "summary:1/3") > 0 }
      try #require(paired)
      let beforeStatus = f.counter.count(for: "summary:2/3")
      f.records.markVariantExported(
        assetId: adjusted.id, placement: f.favorite, variant: .original,
        filename: "ORIGINAL.HEIC", exportedAt: Date())
      f.records.flushPendingNotifications()
      let status = await observe(in: f.window) {
        f.counter.count(for: "summary:2/3") > beforeStatus
      }
      try #require(status)
      f.service.favoritesAssets.append(TestAssetFactory.makeAsset(id: "new-member"))
      f.library.libraryRevision += 1
      let refreshed = await observe(in: f.window) { f.counter.count(for: "summary:2/4") > 0 }
      try #require(refreshed)
      #expect(f.navigation.asset == live)

      let descriptor = PhotoCollectionDescriptor(
        id: "shared:shared", localIdentifier: "shared", title: "Shared", kind: .sharedAlbum,
        pathComponents: [], children: [])
      f.service.collectionTree.append(descriptor)
      f.library.invalidateCache(changedThumbnailAssetIDs: [])
      let shared = try ExportPlacementResolver().placement(
        for: .sharedAlbum(collectionId: "shared"), collections: [descriptor], existingPlacements: []
      )
      f.records.upsertPlacement(shared)
      f.records.markVariantExported(
        assetId: adjusted.id, placement: shared, variant: .original,
        filename: "SHARED.JPG", exportedAt: Date())
      f.records.flushPendingNotifications()
      try #require(
        f.clock.pendingCount == 0, "Record publications must finish before shared-album navigation")
      f.service.assetsBySharedAlbumLocalId["shared"] = [adjusted]
      f.navigation.asset = nil
      f.navigation.selection = .sharedAlbum(collectionId: "shared")
      f.navigation.title = "Updated shared title"
      let sharedRendered = await observe(in: f.window) {
        f.counter.count(for: "summary:1/1") > 0 && f.counter.count(for: "banner:true") > 0
          && f.counter.count(for: "title:Updated shared title") > 0
      }
      try #require(sharedRendered)
      let bannersBefore = f.counter.count(for: "banner:false")
      f.manager.versionSelection = .edited
      let bannerRemoved = await observe(in: f.window) {
        f.counter.count(for: "banner:false") > bannersBefore
      }
      #expect(bannerRemoved)
    }

    @Test(.timeLimit(.minutes(2)))
    func readinessAndRenderedActionsFollowCurrentScopeAfterNavigation() async throws {
      let f = Fixture()
      defer { f.close() }
      f.destination.configureForScreenshotMode()
      f.navigation.title = "Same title"
      f.service.favoritesAssets = [TestAssetFactory.makeAsset(id: "scope-asset")]
      f.service.assetsByAlbumLocalId["bulk-album-0-0"] = [
        TestAssetFactory.makeAsset(id: "scope-asset")
      ]
      f.service.assetsBySharedAlbumLocalId["shared-action"] = [
        TestAssetFactory.makeAsset(id: "scope-asset")
      ]
      f.service.collectionTree.append(
        PhotoCollectionDescriptor(
          id: "shared-action", localIdentifier: "shared-action",
          title: "Shared action", kind: .sharedAlbum, pathComponents: [], children: []))
      f.show()
      let ready = await observe(in: f.window) { f.counter.count(for: "canExport:true") > 0 }
      try #require(ready)
      let disabledBefore = f.counter.count(for: "canExport:false")
      f.records.configure(for: nil)
      let disabled = await observe(in: f.window) {
        f.counter.count(for: "canExport:false") > disabledBefore
      }
      try #require(disabled)
      let enabledBefore = f.counter.count(for: "canExport:true")
      f.records.configure(for: "test")
      let reenabled = await observe(in: f.window) {
        f.counter.count(for: "canExport:true") > enabledBefore
      }
      try #require(reenabled)
      let action = try #require(f.counter.renderedActions["collectionExport"])
      action()
      let favoriteRan = await observe(in: f.window) {
        f.records.exportInfo(assetId: "scope-asset", placement: f.favorite) != nil
      }
      try #require(favoriteRan)
      await f.manager.waitForQueueDrained()

      for (selection, scopeKey, assetId, kind, localId) in [
        (
          LibrarySelection.album(collectionId: "bulk-album-0-0"), "album:bulk-album-0-0",
          "scope-asset",
          ExportPlacement.Kind.album, "bulk-album-0-0"
        ),
        (
          .sharedAlbum(collectionId: "shared-action"), "shared-album:shared-action", "scope-asset",
          .sharedAlbum, "shared-action"
        ),
      ] {
        f.navigation.selection = selection
        let changed = await observe(in: f.window) { f.counter.count(for: "scope:\(scopeKey)") > 0 }
        try #require(changed)
        let action = try #require(f.counter.renderedActions["collectionExport"])
        action()
        let ran = await observe(in: f.window) {
          guard
            let placement = f.records.placements(matching: kind).first(where: {
              $0.collectionLocalIdentifier == localId
            })
          else { return false }
          return f.records.exportInfo(assetId: assetId, placement: placement) != nil
        }
        try #require(ran, "The action passed to the rendered pane must dispatch the current scope")
        await f.manager.waitForQueueDrained()
      }
    }
  }
#endif
