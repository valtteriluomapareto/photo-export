import AppKit
import SwiftUI
import Testing

@testable import Photo_Export

#if DEBUG
  @MainActor
  @Suite(.serialized)
  struct AssetDetailStatusTests {
    @MainActor
    private final class Navigation: ObservableObject {
      @Published var placement: ExportPlacement?
      @Published var selection: LibrarySelection?
      let asset: AssetDescriptor
      init(asset: AssetDescriptor) { self.asset = asset }
    }

    @MainActor
    private struct Host: View {
      @ObservedObject var navigation: Navigation
      let library: PhotoLibraryManager
      let collections: CollectionExportRecordStore
      var body: some View {
        let current: ExportPlacement? = {
          guard let selection = navigation.selection else { return navigation.placement }
          guard let tree = library.libraryRefresh.tree else { return nil }
          return collections.currentPlacement(for: selection, collections: tree)
        }()
        AssetDetailView(asset: navigation.asset, placement: current)
          .modifier(LibraryTreeLoading())
      }
    }

    @MainActor
    private final class RequestLog { var ids: [String] = [] }

    @MainActor
    private final class Fixture {
      let photos = FakePhotoLibraryService()
      let library: PhotoLibraryManager
      let timeline: ExportRecordStore
      let collections: CollectionExportRecordStore
      let navigation: Navigation
      let gate = AsyncCheckpoint()
      let requests = RequestLog()
      let root = TestScratch.directory("AssetDetailStatus")
      let window: NSWindow
      let timelinePlacement = ExportPlacement.timeline(year: 2025, month: 1)

      init(
        paneSize: NSSize = NSSize(width: 500, height: 600)
      ) async {
        library = PhotoLibraryManager(overrideService: photos)
        timeline = ExportRecordStore(baseDirectoryURL: root)
        collections = CollectionExportRecordStore(baseDirectoryURL: root)
        await timeline.configureAndWait(for: "A")
        await collections.configureAndWait(for: "A")
        navigation = Navigation(
          asset: TestAssetFactory.makeAsset(
            id: "selected"))
        photos.fullImageRequestOverride = { [gate, requests] id in
          requests.ids.append(id)
          await gate.enter()
          try Task.checkCancellation()
          return NSImage(size: NSSize(width: 4, height: 4))
        }
        let hosting = NSHostingView(
          rootView: Host(navigation: navigation, library: library, collections: collections)
            .environment(library).environment(timeline).environment(collections)
            .environment(\.accessibilityEnabled, true))
        window = HostedViewHarness.makeWindow(
          contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: paneSize),
          styleMask: [.borderless])

        window.contentView = hosting
      }

      func set(_ placement: ExportPlacement, variants: [ExportVariant: ExportVariantRecord]) {
        if placement.kind == .timeline {
          timeline.bulkImportRecords([
            ExportRecord(
              id: navigation.asset.id, year: 2025, month: 1, relPath: placement.relativePath,
              variants: variants)
          ])
        } else {
          collections.upsertPlacement(placement)
          collections.upsert(
            ScopedExportRecord(
              placement: placement, assetId: navigation.asset.id, variants: variants))
        }
      }

      func show(_ placement: ExportPlacement?) async {
        navigation.placement = placement
        window.orderFront(nil)
        await gate.waitForEnter(count: 1)
      }

      private func visibleRows() -> [String] {
        let prefixes = [
          "Original:", "Original failed:", "Live Photo video:", "Live Photo video failed:",
          "Edited:", "Edited failed:", "Edited version", "Edited Live Photo video:",
          "Edited Live Photo video failed:",
        ]
        var rows: [String] = []
        for text in NativeViewAccess.texts(in: window)
        where prefixes.contains(where: { text.hasPrefix($0) }) && !rows.contains(text) {
          rows.append(text)
        }
        return rows
      }

      func expectRows(_ expected: [String], sourceLocation: SourceLocation = #_sourceLocation) async
      {
        #expect(
          await observe(in: window) { visibleRows() == expected }, sourceLocation: sourceLocation)
        #expect(visibleRows() == expected, sourceLocation: sourceLocation)
      }

      func close() async {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        await gate.releaseAll()
        timeline.drainSynchronously()
        collections.drainSynchronously()
        try? FileManager.default.removeItem(at: root)
      }
    }

    private func record(
      _ status: ExportStatus, error: String? = nil, reason: ExportVariantReason? = nil
    ) -> ExportVariantRecord {
      ExportVariantRecord(
        filename: "FILE.JPG", status: status, exportDate: nil, lastError: error, reason: reason)
    }

    private func placement(_ kind: ExportPlacement.Kind, _ id: String) -> ExportPlacement {
      ExportPlacement(
        kind: kind, id: id, displayName: id, collectionLocalIdentifier: id,
        relativePath: "Collections/\(id)/", createdAt: Date(timeIntervalSince1970: 0))
    }

    @Test(.timeLimit(.minutes(1)))
    func actualRowsFollowCurrentScopeWhileOneImageRequestRemainsHeld() async {
      let f = await Fixture()
      await withCleanup {
        let favorites = ExportPlacement.favorites()
        let album = placement(.album, "album")
        let shared = placement(.sharedAlbum, "shared")
        f.set(favorites, variants: [.original: record(.done)])
        await f.show(favorites)
        await f.expectRows(["Original: Exported"])
        #expect(f.timeline.exportInfo(assetId: f.navigation.asset.id) == nil)
        f.set(f.timelinePlacement, variants: [.original: record(.pending)])
        f.set(favorites, variants: [.original: record(.pending)])
        f.set(album, variants: [.original: record(.failed, error: "Album disk full")])
        f.set(shared, variants: [.original: record(.inProgress)])
        f.collections.flushPendingNotifications()
        await f.expectRows(["Original: Pending"])
        f.navigation.placement = f.timelinePlacement
        await f.expectRows(["Original: Pending"])
        let timelineDetails = f.photos.detailsFetchCalls.count
        #expect(timelineDetails == 1)
        f.set(f.timelinePlacement, variants: [.original: record(.done)])
        f.timeline.flushPendingNotifications()
        await f.expectRows(["Original: Exported"])
        #expect(f.photos.detailsFetchCalls.count - timelineDetails == 0)
        f.navigation.placement = favorites
        await f.expectRows(["Original: Pending"])
        f.navigation.placement = album
        await f.expectRows(["Original failed: Album disk full"])
        f.navigation.placement = shared
        await f.expectRows(["Original: In progress"])
        let details = f.photos.detailsFetchCalls.count
        #expect(details == 1)
        f.set(shared, variants: [.original: record(.done)])
        await f.expectRows(["Original: Exported"])
        #expect(f.photos.detailsFetchCalls.count == details)
        f.navigation.placement = nil
        await f.expectRows([])
        #expect(f.requests.ids == [f.navigation.asset.id])
      } cleanup: {
        await f.close()
      }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func mountedPreviewUsesBoundedPanePixels(oversized: Bool) async throws {
      let f = await Fixture(
        paneSize: oversized ? NSSize(width: 4096, height: 3072) : NSSize(width: 500, height: 600))
      try await withCleanup {
        await f.show(f.timelinePlacement)
        let size = try #require(f.photos.previewPixelSizes.last)
        #expect(size.width > 0 && size.height > 0)
        #expect(size.width <= 2560 && size.height <= 2560)
        if oversized {
          #expect(max(size.width, size.height) == 2560)
        } else {
          #expect(size.width <= 1000, "The 500-point pane needs at most Retina width")
        }
      } cleanup: {
        await f.close()
      }
    }

    @Test(.timeLimit(.minutes(1)))
    func actualRowsRefreshOnCurrentTreeAndStoreChangesWithoutReloadingImage() async throws {
      let f = await Fixture()
      try await withCleanup {
        func album(_ title: String) -> PhotoCollectionDescriptor {
          PhotoCollectionDescriptor(
            id: "album", localIdentifier: "album", title: title, kind: .album, pathComponents: [],
            children: [])
        }
        let selection = LibrarySelection.album(collectionId: "album")
        let oldDescriptor = album("Old")
        let resolver = ExportPlacementResolver()
        let old = try resolver.placement(
          for: selection, collections: [oldDescriptor], existingPlacements: [])
        f.photos.collectionTree = [oldDescriptor]
        f.set(old, variants: [.original: record(.done)])
        f.navigation.selection = selection
        await f.show(nil)
        await f.expectRows(["Original: Exported"])
        let renamed = album("New")
        f.photos.collectionTree = [renamed]
        f.library.invalidateCache(changedThumbnailAssetIDs: [])
        await f.expectRows([])
        let current = try resolver.placement(
          for: selection, collections: [renamed], existingPlacements: [old])
        f.set(current, variants: [.original: record(.failed, error: "New folder failure")])
        await f.expectRows(["Original failed: New folder failure"])
        f.photos.collectionTreeError = CocoaError(.fileReadNoPermission)
        f.library.invalidateCache(changedThumbnailAssetIDs: [])
        await f.expectRows([])
        f.photos.collectionTreeError = nil
        f.library.invalidateCache(changedThumbnailAssetIDs: [])
        await f.expectRows(["Original failed: New folder failure"])
        f.photos.collectionTree = []
        f.library.invalidateCache(changedThumbnailAssetIDs: [])
        await f.expectRows([])
        #expect(f.requests.ids == [f.navigation.asset.id])
        #expect(f.collections.placement(id: old.id)?.relativePath == old.relativePath)
      } cleanup: {
        await f.close()
      }
    }

  }
#endif
