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
      let service: FakePhotoLibraryService
      let library: PhotoLibraryManager
      let manager: ExportManager
      let timeline: ExportRecordStore
      let records: CollectionExportRecordStore
      let destination: ExportDestinationManager
      let fakeDestination = FakeExportDestination()
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let defaultsName = "CollectionObservation-\(UUID().uuidString)"
      let defaults: UserDefaults
      let window: NSWindow
      let favorite = ExportPlacement.favorites()

      init() {
        service = BulkLibraryFixture.makeFakeLibrary(
          timelineAssets: 0,
          albumFolders: 1, albumsPerFolder: 1, assetsPerAlbum: 10_000)
        service.favoritesAssets = service.assetsByAlbumLocalId["bulk-album-0-0"]!
        library = PhotoLibraryManager(overrideService: service)
        defaults = UserDefaults(suiteName: defaultsName)!
        timeline = ExportRecordStore(baseDirectoryURL: root)
        records = CollectionExportRecordStore(baseDirectoryURL: root)
        timeline.configure(for: "test")
        records.configure(for: "test")
        records.upsertPlacement(favorite)
        manager = ExportManager(
          photoLibraryService: service, exportDestination: fakeDestination,
          exportRecordStore: timeline, collectionExportRecordStore: records,
          assetResourceWriter: FakeAssetResourceWriter(), fileSystem: FakeFileSystem(),
          userDefaults: defaults)
        destination = ExportDestinationManager(skipRestore: true, userDefaults: defaults)
        let hosted = NSHostingView(
          rootView: Parent(
            manager: manager, navigation: navigation,
            service: service, counter: counter
          )
          .environmentObject(library).environmentObject(records).environmentObject(manager)
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
        timeline.flushForTesting()
        records.flushForTesting()
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
    }

    private func observe(_ condition: () -> Bool) async -> Bool {
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: .seconds(15))
      while !condition(), !Task.isCancelled, clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
      }
      return condition()
    }

    @Test(.timeLimit(.minutes(2)))
    func unrelatedQueuePublicationsDoNotRescanLoadedCollection() async throws {
      let f = Fixture()
      defer { f.close() }
      f.show()
      let loaded = await observe {
        f.counter.count(for: "summary:0/10000") > 0 && f.service.startCachingCalls.count == 1
      }
      try #require(loaded, "Must measure a loaded collection with an actual matching placement")
      await f.renderBarrier()
      let scans = f.counter.count(for: "summaryScan")
      let bodies = f.counter.count(for: "collectionBody")
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
        let acknowledged = await observe { f.counter.count(for: key) > parent }
        try #require(acknowledged, "Parent must process the actual queue-count publication")
        await f.renderBarrier()
      }
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
      f.show()
      let initial = await observe {
        f.counter.count(for: "summary:3/3") > 0 && f.counter.count(for: "selected:adjusted") > 0
      }
      try #require(initial)
      let selectedBefore = f.counter.count(for: "selected:live")
      f.navigation.asset = live
      let rebound = await observe { f.counter.count(for: "selected:live") > selectedBefore }
      try #require(rebound, "A live binding change must update the pane's selected-thumbnail input")
      #expect(f.navigation.asset == live)

      f.manager.versionSelection = .editedWithOriginals
      let originals = await observe { f.counter.count(for: "summary:2/3") > 0 }
      try #require(originals)
      f.manager.livePhotosPairedExport = true
      let paired = await observe { f.counter.count(for: "summary:1/3") > 0 }
      try #require(paired)
      let beforeStatus = f.counter.count(for: "summary:2/3")
      f.records.markVariantExported(
        assetId: adjusted.id, placement: f.favorite, variant: .original,
        filename: "ORIGINAL.HEIC", exportedAt: Date())
      let status = await observe { f.counter.count(for: "summary:2/3") > beforeStatus }
      try #require(status)
      f.service.favoritesAssets.append(TestAssetFactory.makeAsset(id: "new-member"))
      f.library.libraryRevision += 1
      let refreshed = await observe { f.counter.count(for: "summary:2/4") > 0 }
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
      f.service.assetsBySharedAlbumLocalId["shared"] = [adjusted]
      f.navigation.asset = nil
      f.navigation.selection = .sharedAlbum(collectionId: "shared")
      f.navigation.title = "Updated shared title"
      let sharedRendered = await observe {
        f.counter.count(for: "summary:1/1") > 0 && f.counter.count(for: "banner:true") > 0
          && f.counter.count(for: "title:Updated shared title") > 0
      }
      try #require(sharedRendered)
      let bannersBefore = f.counter.count(for: "banner:false")
      f.manager.versionSelection = .edited
      let bannerRemoved = await observe { f.counter.count(for: "banner:false") > bannersBefore }
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
      let ready = await observe { f.counter.count(for: "canExport:true") > 0 }
      try #require(ready)
      let disabledBefore = f.counter.count(for: "canExport:false")
      f.records.configure(for: nil)
      let disabled = await observe { f.counter.count(for: "canExport:false") > disabledBefore }
      try #require(disabled)
      let enabledBefore = f.counter.count(for: "canExport:true")
      f.records.configure(for: "test")
      let reenabled = await observe { f.counter.count(for: "canExport:true") > enabledBefore }
      try #require(reenabled)
      let action = try #require(f.counter.renderedActions["collectionExport"])
      action()
      let favoriteRan = await observe {
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
        let changed = await observe { f.counter.count(for: "scope:\(scopeKey)") > 0 }
        try #require(changed)
        let action = try #require(f.counter.renderedActions["collectionExport"])
        action()
        let ran = await observe {
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
