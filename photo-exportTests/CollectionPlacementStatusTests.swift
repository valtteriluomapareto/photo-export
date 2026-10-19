import AppKit
import SwiftUI
import Testing

@testable import Photo_Export

#if DEBUG
  @MainActor
  @Suite(.serialized)
  struct CollectionPlacementStatusTests {
    enum Change: CaseIterable { case rename, ancestorRename, move, sharedRename }

    @MainActor
    private struct Host: View {
      let service: FakePhotoLibraryService
      let selection: LibrarySelection
      let folderId: String?
      @State private var selectedAsset: AssetDescriptor?
      @State private var sidebarSelection: Set<LibrarySelection> = []
      @State private var folderSelection: LibrarySelection?

      var body: some View {
        HStack(alignment: .top) {
          CollectionsSidebarView(selectionSet: $sidebarSelection).frame(width: 260)
          CollectionContentView(
            selection: selection, title: "Current album", versionSelection: .edited,
            livePhotosPaired: false, onExportCollection: {}, selectedAsset: $selectedAsset,
            photoLibraryService: service
          ).equatable().frame(width: 350)
          if let folderId {
            FolderContentView(
              folderId: folderId, title: "Current folder", selection: $folderSelection,
              selectedAsset: $selectedAsset, photoLibraryService: service
            ).frame(width: 350)
          }
        }
      }
    }

    @MainActor
    private final class Fixture {
      let service = FakePhotoLibraryService()
      let library: PhotoLibraryManager
      let timeline: ExportRecordStore
      let records: CollectionExportRecordStore
      let manager: ExportManager
      let fakeDestination = FakeExportDestination()
      let counter = BodyInvalidationCounter()
      let asset = TestAssetFactory.makeAsset(id: "changed-asset")
      let unchangedAsset = TestAssetFactory.makeAsset(id: "unchanged-asset")
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let defaultsName = "PlacementStatus-\(UUID().uuidString)"
      let defaults: UserDefaults
      let selection: LibrarySelection
      let old: ExportPlacement
      let current: ExportPlacement
      let unchanged: ExportPlacement?
      let currentTree: [PhotoCollectionDescriptor]
      let folderId: String?
      let sidebarFolderId: String?
      var window: NSWindow?

      init(change: Change) throws {
        library = PhotoLibraryManager(overrideService: service)
        timeline = ExportRecordStore(baseDirectoryURL: root)
        records = CollectionExportRecordStore(baseDirectoryURL: root)
        defaults = UserDefaults(suiteName: defaultsName)!
        timeline.configure(for: "A")
        records.configure(for: "A")
        manager = ExportManager(
          photoLibraryService: service, exportDestination: fakeDestination,
          exportRecordStore: timeline, collectionExportRecordStore: records,
          assetResourceWriter: FakeAssetResourceWriter(), fileSystem: FakeFileSystem(),
          userDefaults: defaults)
        let shared = change == .sharedRename
        selection = shared ? .sharedAlbum(collectionId: "target") : .album(collectionId: "target")
        let parent: [String] =
          change == .ancestorRename ? ["Folder"] : change == .move ? ["Parent", "Folder"] : []
        let oldParent: [String] =
          change == .ancestorRename ? ["Old Folder"] : change == .move ? ["Previous"] : []
        let currentDescriptor = PhotoCollectionDescriptor(
          id: shared ? "shared:target" : "album:target", localIdentifier: "target",
          title: parent.isEmpty ? "New" : "Album", kind: shared ? .sharedAlbum : .album,
          pathComponents: parent, children: [])
        let oldDescriptor = PhotoCollectionDescriptor(
          id: currentDescriptor.id, localIdentifier: "target",
          title: parent.isEmpty ? "Old" : "Album",
          kind: currentDescriptor.kind, pathComponents: oldParent, children: [])
        let resolver = ExportPlacementResolver(now: { Date(timeIntervalSince1970: 100) })
        let historicalResolver = ExportPlacementResolver(now: { Date(timeIntervalSince1970: 999) })
        old = try historicalResolver.placement(
          for: selection, collections: [oldDescriptor], existingPlacements: [])
        current = try resolver.placement(
          for: selection, collections: [currentDescriptor], existingPlacements: [old])
        if parent.isEmpty {
          currentTree = [currentDescriptor]
          folderId = nil
          sidebarFolderId = nil
          unchanged = nil
        } else {
          let stable = PhotoCollectionDescriptor(
            id: "album:stable", localIdentifier: "stable", title: "Unchanged", kind: .album,
            pathComponents: parent, children: [])
          let folder = PhotoCollectionDescriptor(
            id: "folder:folder", localIdentifier: "folder", title: "Folder", kind: .folder,
            pathComponents: Array(parent.dropLast()), children: [currentDescriptor, stable])
          folderId = "folder"
          if change == .move {
            currentTree = [
              PhotoCollectionDescriptor(
                id: "folder:parent", localIdentifier: "parent", title: "Parent", kind: .folder,
                pathComponents: [], children: [folder])
            ]
            sidebarFolderId = "folder:parent"
          } else {
            currentTree = [folder]
            sidebarFolderId = "folder:folder"
          }
          unchanged = try resolver.placement(
            for: .album(collectionId: "stable"), collections: [stable],
            existingPlacements: [old, current])
          service.assetsByAlbumLocalId["stable"] = [unchangedAsset]
        }
        service.collectionTree = currentTree
        if shared {
          service.assetsBySharedAlbumLocalId["target"] = [asset]
        } else {
          service.assetsByAlbumLocalId["target"] = [asset]
        }
      }

      func set(
        _ placement: ExportPlacement, _ status: ExportStatus, assetId: String = "changed-asset"
      ) {
        records.upsertPlacement(placement)
        records.upsert(
          ScopedExportRecord(
            placement: placement, assetId: assetId,
            variants: [
              .original: ExportVariantRecord(
                filename: "FILE.JPG", status: status, exportDate: nil,
                lastError: status == .failed ? "failed" : nil)
            ]))
      }

      func show(selectionOverride: LibrarySelection? = nil) {
        let hosted = NSHostingView(
          rootView:
            Host(service: service, selection: selectionOverride ?? selection, folderId: folderId)
            .environmentObject(library).environmentObject(timeline).environmentObject(records)
            .environmentObject(manager)
            .environmentObject(ExportDestinationManager(skipRestore: true, userDefaults: defaults))
            .environment(\.bodyInvalidationCounter, counter))
        let hostWindow = NSWindow(
          contentRect: NSRect(x: -10000, y: -10000, width: 1000, height: 800),
          styleMask: [.borderless], backing: .buffered, defer: false)
        hostWindow.isReleasedWhenClosed = false
        hostWindow.contentView = hosted
        window = hostWindow
        hostWindow.orderFront(nil)
      }

      func close() {
        window?.orderOut(nil)
        window?.contentView = nil
        window?.close()
        window = nil
        counter.reset()
        timeline.flushForTesting()
        records.flushForTesting()
        defaults.removePersistentDomain(forName: defaultsName)
        fakeDestination.cleanup()
        try? FileManager.default.removeItem(at: root)
      }
    }

    private func observe(
      _ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
      await eventually("observed condition", sourceLocation: sourceLocation) { condition() }
    }
    private func loaded(_ f: Fixture) async throws {
      let ready = await observe {
        guard f.counter.renderedText["thumbnail-exported:changed-asset"] != nil else {
          return false
        }
        if let id = f.sidebarFolderId {
          return f.counter.renderedText["folder-summary"]?.first?.hasSuffix("/2") == true
            && f.counter.renderedText["folder-sidebar:\(id)"] != nil
        }
        let id = f.current.kind == .sharedAlbum ? "shared:target" : "album:target"
        return f.counter.renderedText["collection-sidebar:\(id)"] != nil
      }
      try #require(ready, "Wait for actual asset/count rendering before checking status")
    }

    private func expectStatus(
      _ f: Fixture, exported: Bool, currentExists: Bool = true,
      sourceLocation: SourceLocation = #_sourceLocation
    ) async {
      let expected = [exported ? "1/1" : "0/1"]
      _ = await eventually("collection summary \(expected)", sourceLocation: sourceLocation) {
        f.counter.renderedText["collection-summary"] == expected
          && f.counter.renderedText["thumbnail-exported:changed-asset"] == [String(exported)]
      }
      #expect(
        f.counter.renderedText["collection-summary"] == expected, sourceLocation: sourceLocation)
      #expect(
        f.counter.renderedText["thumbnail-exported:changed-asset"] == [String(exported)],
        sourceLocation: sourceLocation)
      if let id = f.sidebarFolderId {
        let expectedFolder = exported ? "2/2" : "1/2"
        let expectedBadge = exported ? "complete" : "partial(exported: 1, total: 2)"
        let settled = await observe {
          f.counter.renderedText["folder-summary"] == [expectedFolder]
            && f.counter.renderedText["folder-sidebar:\(id)"] == [expectedBadge]
            && f.counter.renderedText["folder-tile-exported:album:target"] == [String(exported)]
            && f.counter.renderedText["folder-tile-exported:album:stable"] == ["true"]
        }
        #expect(settled, sourceLocation: sourceLocation)
        #expect(
          f.counter.renderedText["folder-tile-exported:album:stable"] == ["true"],
          sourceLocation: sourceLocation)
      } else {
        let id = f.current.kind == .sharedAlbum ? "shared:target" : "album:target"
        let expectedBadge =
          exported ? "complete" : currentExists ? "notStarted(total: 1)" : "count:1"
        let settled = await observe {
          f.counter.renderedText["collection-sidebar:\(id)"] == [expectedBadge]
        }
        #expect(settled, sourceLocation: sourceLocation)
      }
    }

    private func verifyUnchangedHistory(_ f: Fixture, mutations: Int) async throws {
      #expect(f.records.mutationCounter == mutations)
      let paths = f.records.placements.mapValues {
        [$0.relativePath, $0.displayName, String($0.createdAt.timeIntervalSince1970)]
      }
      let history = f.records.placements.values.compactMap {
        f.records.exportInfo(assetId: f.asset.id, placement: $0)
      }
      try await f.records.flush()
      let reopened = CollectionExportRecordStore(baseDirectoryURL: f.root)
      reopened.configure(for: "A")
      #expect(
        reopened.placements.mapValues {
          [$0.relativePath, $0.displayName, String($0.createdAt.timeIntervalSince1970)]
        } == paths)
      for record in history {
        #expect(
          reopened.exportInfo(assetId: f.asset.id, placement: record.placement)?.variants
            == record.variants)
      }
      #expect(reopened.placement(id: f.old.id)?.relativePath == f.old.relativePath)
      reopened.flushForTesting()
    }

    @Test(.timeLimit(.minutes(3)), arguments: Change.allCases)
    func historicalSuccessDoesNotCompleteChangedTarget(change: Change) async throws {
      let f = try Fixture(change: change)
      defer { f.close() }
      f.set(f.old, .done)
      if let stable = f.unchanged { f.set(stable, .done, assetId: f.unchangedAsset.id) }
      let notified = await observe { f.records.mutationCounter > 1 }
      try #require(notified)
      let mutations = f.records.mutationCounter
      f.show()
      try await loaded(f)
      await expectStatus(f, exported: false, currentExists: false)
      try await verifyUnchangedHistory(f, mutations: mutations)
      #expect(f.old.id != f.current.id)
      #expect(f.old.relativePath != f.current.relativePath)
      let expectedPaths: (String, String) =
        switch change {
        case .rename: ("Collections/Albums/Old/", "Collections/Albums/New/")
        case .ancestorRename:
          ("Collections/Albums/Old Folder/Album/", "Collections/Albums/Folder/Album/")
        case .move:
          ("Collections/Albums/Previous/Album/", "Collections/Albums/Parent/Folder/Album/")
        case .sharedRename: ("Collections/Shared Albums/Old/", "Collections/Shared Albums/New/")
        }
      #expect(f.old.relativePath == expectedPaths.0)
      #expect(f.current.relativePath == expectedPaths.1)
      #expect(f.old.createdAt == Date(timeIntervalSince1970: 999))
      #expect(f.current.createdAt == Date(timeIntervalSince1970: 100))
      let beforeExport = f.records.mutationCounter
      f.set(f.current, .done)
      let notifiedExport = await observe { f.records.mutationCounter > beforeExport }
      try #require(notifiedExport)
      let afterExport = f.records.mutationCounter
      await expectStatus(f, exported: true)
      try await verifyUnchangedHistory(f, mutations: afterExport)
    }

    @Test(.timeLimit(.minutes(2)), arguments: Change.allCases, [false, true])
    func conflictsUseCurrentHistoryRegardlessOfInsertionOrder(change: Change, reverse: Bool)
      async throws
    {
      let f = try Fixture(change: change)
      defer { f.close() }
      let placements = reverse ? [f.current, f.old] : [f.old, f.current]
      for placement in placements {
        f.set(placement, placement.id == f.current.id ? .failed : .done)
      }
      if let stable = f.unchanged { f.set(stable, .done, assetId: f.unchangedAsset.id) }
      let notified = await observe { f.records.mutationCounter > 1 }
      try #require(notified)
      f.show()
      try await loaded(f)
      let firstMutations = f.records.mutationCounter
      await expectStatus(f, exported: false)
      try await verifyUnchangedHistory(f, mutations: firstMutations)
      let beforeUpdate = f.records.mutationCounter
      f.set(f.old, .failed)
      f.set(f.current, .done)
      let notifiedUpdate = await observe { f.records.mutationCounter > beforeUpdate }
      try #require(notifiedUpdate)
      let secondMutations = f.records.mutationCounter
      await expectStatus(f, exported: true)
      try await verifyUnchangedHistory(f, mutations: secondMutations)
      #expect(f.old.createdAt > f.current.createdAt, "Reject arbitrary newest-history selection")
    }

    @Test(.timeLimit(.minutes(2)))
    func mountedAncestorRenameMissingTreeAndRecoveryFollowCurrentTarget() async throws {
      let f = try Fixture(change: .ancestorRename)
      defer { f.close() }
      let oldAlbum = PhotoCollectionDescriptor(
        id: "album:target", localIdentifier: "target", title: "Album", kind: .album,
        pathComponents: ["Old Folder"], children: [])
      let oldStable = PhotoCollectionDescriptor(
        id: "album:stable", localIdentifier: "stable", title: "Unchanged", kind: .album,
        pathComponents: ["Old Folder"], children: [])
      f.service.collectionTree = [
        PhotoCollectionDescriptor(
          id: "folder:folder", localIdentifier: "folder", title: "Old Folder", kind: .folder,
          pathComponents: [], children: [oldAlbum, oldStable])
      ]
      f.set(f.old, .done)
      f.set(try #require(f.unchanged), .done, assetId: f.unchangedAsset.id)
      let notified = await observe { f.records.mutationCounter > 1 }
      try #require(notified)
      let mutations = f.records.mutationCounter
      f.show()
      try await loaded(f)
      let initial = await observe { f.counter.renderedText["collection-summary"] == ["1/1"] }
      try #require(initial)
      f.counter.reset()
      f.service.collectionTree = f.currentTree
      f.library.invalidateCache(changedThumbnailAssetIDs: [])
      await expectStatus(f, exported: false, currentExists: false)
      try await verifyUnchangedHistory(f, mutations: mutations)
      f.set(f.current, .done)
      let currentNotified = await observe { f.records.mutationCounter > mutations }
      try #require(currentNotified)
      await expectStatus(f, exported: true)
      let currentMutations = f.records.mutationCounter
      for fails in [false, true] {
        f.counter.reset()
        f.service.collectionTree = []
        f.service.collectionTreeError = fails ? CocoaError(.fileReadUnknown) : nil
        f.library.invalidateCache(changedThumbnailAssetIDs: [])
        let missing = await observe {
          f.counter.renderedText["collection-summary"] == ["0/1"]
            && f.counter.renderedText["thumbnail-exported:changed-asset"] == ["false"]
        }
        #expect(missing)
        #expect(f.records.mutationCounter == currentMutations)
        f.counter.reset()
        f.service.collectionTreeError = nil
        f.service.collectionTree = f.currentTree
        f.library.invalidateCache(changedThumbnailAssetIDs: [])
        await expectStatus(f, exported: true)
      }
      try await verifyUnchangedHistory(f, mutations: currentMutations)
      #expect(f.old.relativePath == "Collections/Albums/Old Folder/Album/")
      #expect(f.current.relativePath == "Collections/Albums/Folder/Album/")
    }

    @Test(.timeLimit(.minutes(2)))
    func favoritesIgnoreTreeErrorsAndDestinationSwitchDoesNotBorrowHistory() async throws {
      let f = try Fixture(change: .rename)
      defer { f.close() }
      let favorites = ExportPlacement.favorites()
      f.set(favorites, .done)
      f.service.favoritesAssets = [f.asset]
      f.service.collectionTreeError = CocoaError(.fileReadUnknown)
      let notified = await observe { f.records.mutationCounter > 1 }
      try #require(notified)
      f.show(selectionOverride: .favorites)
      let original = await observe {
        f.counter.renderedText["collection-summary"] == ["1/1"]
          && f.counter.renderedText["collection-sidebar:favorites"] == ["complete"]
          && f.counter.renderedText["thumbnail-exported:changed-asset"] == ["true"]
      }
      try #require(original)
      try await f.records.flush()
      f.counter.reset()
      f.records.configure(for: "B")
      let other = await observe {
        f.counter.renderedText["collection-summary"] == ["0/1"]
          && f.counter.renderedText["thumbnail-exported:changed-asset"] == ["false"]
          && f.counter.renderedText["collection-sidebar:favorites"] == ["count:1"]
      }
      #expect(other)
      #expect(f.records.placements.isEmpty)
      f.counter.reset()
      f.records.configure(for: "A")
      let restored = await observe {
        f.counter.renderedText["collection-summary"] == ["1/1"]
          && f.counter.renderedText["thumbnail-exported:changed-asset"] == ["true"]
          && f.counter.renderedText["collection-sidebar:favorites"] == ["complete"]
      }
      #expect(restored)
      #expect(
        f.records.exportInfo(assetId: f.asset.id, placement: favorites)?.variants[.original]?.status
          == .done)
      #expect(favorites.relativePath == "Collections/Favorites/")
    }

  }
#endif
