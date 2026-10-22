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
      @ObservedObject var library: PhotoLibraryManager
      let collections: CollectionExportRecordStore
      var body: some View {
        let current: ExportPlacement? = {
          guard let selection = navigation.selection else { return navigation.placement }
          guard let tree = try? library.fetchCollectionTree() else { return nil }
          return collections.currentPlacement(for: selection, collections: tree)
        }()
        AssetDetailView(asset: navigation.asset, placement: current)
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
      let counter = BodyInvalidationCounter()
      let gate = AsyncCheckpoint()
      let requests = RequestLog()
      let root = TestScratch.directory("AssetDetailStatus")
      let window: NSWindow
      let timelinePlacement = ExportPlacement.timeline(year: 2025, month: 1)

      init(adjusted: Bool = false, live: Bool = false) {
        library = PhotoLibraryManager(overrideService: photos)
        timeline = ExportRecordStore(baseDirectoryURL: root)
        collections = CollectionExportRecordStore(baseDirectoryURL: root)
        timeline.configure(for: "A")
        collections.configure(for: "A")
        navigation = Navigation(
          asset: TestAssetFactory.makeAsset(
            id: "selected", hasAdjustments: adjusted, isLivePhoto: live))
        photos.fullImageRequestOverride = { [gate, requests] id in
          requests.ids.append(id)
          await gate.enter()
          try Task.checkCancellation()
          return NSImage(size: NSSize(width: 4, height: 4))
        }
        let hosting = NSHostingView(
          rootView: Host(navigation: navigation, library: library, collections: collections)
            .environmentObject(library).environment(timeline).environment(collections)
            .environment(\.bodyInvalidationCounter, counter))
        window = NSWindow(
          contentRect: NSRect(x: -10_000, y: -10_000, width: 500, height: 600),
          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
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

      func expectRows(_ expected: [String], sourceLocation: SourceLocation = #_sourceLocation) async
      {
        _ = await eventually("asset detail rows \(expected)", sourceLocation: sourceLocation) {
          window.contentView?.layoutSubtreeIfNeeded()
          return counter.renderedText["asset-detail-status"] == expected
        }
        #expect(
          counter.renderedText["asset-detail-status"] == expected, sourceLocation: sourceLocation)
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
      let f = Fixture()
      await withCleanup {
        let favorites = ExportPlacement.favorites()
        let album = placement(.album, "album")
        let shared = placement(.sharedAlbum, "shared")
        f.set(f.timelinePlacement, variants: [.original: record(.done)])
        f.set(favorites, variants: [.original: record(.pending)])
        f.set(album, variants: [.original: record(.failed, error: "Album disk full")])
        f.set(shared, variants: [.original: record(.inProgress)])
        await f.show(f.timelinePlacement)
        await f.expectRows(["Original: Exported"])
        f.navigation.placement = favorites
        await f.expectRows(["Original: Pending"])
        f.navigation.placement = album
        await f.expectRows(["Original failed: Album disk full"])
        f.navigation.placement = shared
        await f.expectRows(["Original: In progress"])
        f.set(shared, variants: [.original: record(.done)])
        await f.expectRows(["Original: Exported"])
        f.navigation.placement = nil
        await f.expectRows([])
        #expect(f.requests.ids == [f.navigation.asset.id])
      } cleanup: {
        await f.close()
      }
    }

    @Test(.timeLimit(.minutes(1)))
    func collectionOnlySuccessIsVisibleWithoutTimelineHistory() async {
      let f = Fixture()
      await withCleanup {
        let album = placement(.album, "only-album")
        f.set(album, variants: [.original: record(.done)])
        await f.show(album)
        await f.expectRows(["Original: Exported"])
        #expect(f.timeline.exportInfo(assetId: f.navigation.asset.id) == nil)
      } cleanup: {
        await f.close()
      }
    }

    @Test(.timeLimit(.minutes(1)))
    func sharedAlbumShowsOnlySingleResourceHistoryForAdjustedLivePhoto() async {
      let f = Fixture(adjusted: true, live: true)
      await withCleanup {
        let variants: [ExportVariant: ExportVariantRecord] = [
          .original: record(.done), .originalPairedVideo: record(.pending),
          .edited: record(.failed, error: "irrelevant edit"), .editedPairedVideo: record(.pending),
        ]
        f.set(f.timelinePlacement, variants: variants)
        let shared = placement(.sharedAlbum, "shared")
        f.set(shared, variants: variants)
        await f.show(shared)
        await f.expectRows(["Original: Exported"])
      } cleanup: {
        await f.close()
      }
    }

    @Test(.timeLimit(.minutes(1)))
    func convertedEditedHistoryIsVisibleWithoutPhotosAdjustments() async {
      let f = Fixture()
      await withCleanup {
        f.set(f.timelinePlacement, variants: [.edited: record(.done)])
        await f.show(f.timelinePlacement)
        await f.expectRows(["Edited: Exported"])
      } cleanup: {
        await f.close()
      }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func currentPlacementLookupIsExactAndReadOnly(shared: Bool) async throws {
      let f = Fixture()
      try await withCleanup {
        let kind: PhotoCollectionDescriptor.Kind = shared ? .sharedAlbum : .album
        let selection: LibrarySelection =
          shared ? .sharedAlbum(collectionId: "album") : .album(collectionId: "album")
        func album(_ title: String, parent: [String] = []) -> PhotoCollectionDescriptor {
          PhotoCollectionDescriptor(
            id: "album", localIdentifier: "album", title: title, kind: kind, pathComponents: parent,
            children: [])
        }
        let resolver = ExportPlacementResolver()
        let prior = album("Old")
        let old = try resolver.placement(
          for: selection, collections: [prior], existingPlacements: [])
        f.set(old, variants: [.original: record(.done)])
        try await f.collections.flush()
        let count = f.collections.mutationCounter
        let keys = Set(f.collections.placements.keys)
        for changed in [album("New"), album("Old", parent: shared ? [] : ["Moved"])] {
          let result = f.collections.currentPlacement(for: selection, collections: [changed])
          if !shared || changed.title == "New" { #expect(result == nil) }
        }
        #expect(f.collections.currentPlacement(for: selection, collections: []) == nil)
        #expect(f.collections.mutationCounter == count)
        #expect(Set(f.collections.placements.keys) == keys)
        let current = album("New")
        let fresh = try resolver.placement(
          for: selection, collections: [current], existingPlacements: [old])
        f.set(fresh, variants: [.original: record(.failed, error: "current failure")])
        let found = try #require(
          f.collections.currentPlacement(for: selection, collections: [current]))
        #expect(found.id == fresh.id)
        #expect(found.relativePath == fresh.relativePath)
        #expect(found.id != old.id)
        #expect(
          f.collections.exportInfo(assetId: f.navigation.asset.id, placement: old)?.variants[
            .original]?.status == .done)
      } cleanup: {
        await f.close()
      }
    }

    @Test(.timeLimit(.minutes(1)))
    func actualRowsRefreshOnCurrentTreeAndStoreChangesWithoutReloadingImage() async throws {
      let f = Fixture()
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

    @Test(.timeLimit(.minutes(1)))
    func typedRecoveryRowsRemainLiteralInCurrentCollection() async {
      let f = Fixture(adjusted: true, live: true)
      await withCleanup {
        let album = placement(.album, "fallback")
        f.set(
          album,
          variants: [
            .original: record(.done),
            .originalPairedVideo: record(.failed, reason: .pairedVideoUnavailable),
            .edited: record(.failed, reason: .editedUnavailableOriginalBackedUp),
          ])
        await f.show(album)
        await f.expectRows([
          "Original: Exported",
          "Live Photo video: Photos doesn't currently expose a paired video for this Live Photo. The still was exported.",
          "Edited version was unavailable. The original was saved as a `_orig` companion.",
        ])
      } cleanup: {
        await f.close()
      }
    }
  }
#endif
