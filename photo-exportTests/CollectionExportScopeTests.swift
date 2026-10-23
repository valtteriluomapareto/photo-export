import AppKit
import SwiftUI
import Testing

@testable import Photo_Export

#if DEBUG
  @MainActor
  @Suite(.serialized, .timeLimit(.minutes(2)))
  struct CollectionExportScopeTests {
    enum Action: CaseIterable { case all, toolbarSelection, sidebarSelection }

    private struct Host: View {
      let manager: ExportManager
      let action: Action
      @State private var selection: Set<LibrarySelection> = [
        .folder(collectionId: "folder"), .album(collectionId: "B"),
      ]
      var body: some View {
        CollectionsSidebarView(selectionSet: $selection, exportManager: manager)
          .toolbar {
            ExportToolbarView(
              section: .collections,
              selectionSet: action == .all ? [] : selection,
              focusedSelection: nil, historyState: .ready)
          }
      }
    }

    @MainActor private final class Fixture {
      let h = ExportManagerHarness(label: "CollectionExportScope")
      let library: PhotoLibraryManager
      let counter = BodyInvalidationCounter()
      let gate = AsyncCheckpoint()
      let window: NSWindow

      init(action: Action) {
        library = PhotoLibraryManager(overrideService: h.photoLib, refreshClock: TestClock())
        let destination = ExportDestinationManager(skipRestore: true, userDefaults: h.defaults)
        destination.configureForScreenshotMode()
        let environment = HostedViewHarness(
          library: library, export: h, destination: destination, autoSync: AutoSyncManager(),
          whatsNew: WhatsNewState(userDefaults: h.defaults, currentVersion: "test", catalog: []))
        window = HostedViewHarness.makeWindow(
          contentRect: NSRect(x: -10000, y: -10000, width: 900, height: 600),
          styleMask: [.titled], toolbarStyle: .unified)
        window.contentView = NSHostingView(
          rootView: environment.environment(Host(manager: h.manager, action: action))
            .environment(\.bodyInvalidationCounter, counter).defaultAppStorage(h.defaults))
        for id in ["A", "B", "old", "favorite"] {
          let asset = TestAssetFactory.makeAsset(id: id)
          h.photoLib.assetsByAlbumLocalId[id] = [asset]
          h.photoLib.resourcesByAssetId[id] = [
            ResourceDescriptor(type: .photo, originalFilename: "\(id).jpg")
          ]
        }
        h.photoLib.favoritesAssets = [TestAssetFactory.makeAsset(id: "favorite")]
        h.manager.queueCoordinator.pause()
      }

      func tree(_ member: String) -> [PhotoCollectionDescriptor] {
        func album(_ id: String) -> PhotoCollectionDescriptor {
          PhotoCollectionDescriptor(
            id: "album:\(id)", localIdentifier: id, title: id, kind: .album,
            pathComponents: [], children: [])
        }
        return [
          PhotoCollectionDescriptor(
            id: "folder:folder", localIdentifier: "folder", title: "Folder", kind: .folder,
            pathComponents: [], children: [album(member)]),
          album("B"),
        ]
      }

      func close() async {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        h.manager.cancelAndClear()
        await gate.releaseAll()
        h.store.drainSynchronously()
        h.collectionStore.drainSynchronously()
        h.dest.cleanup()
      }
    }

    @Test(arguments: Action.allCases, [false, true])
    func exportActionsResolveColdAndStaleDisplayTrees(action: Action, stale: Bool) async throws {
      let f = Fixture(action: action)
      try await withCleanup {
        if stale {
          f.h.photoLib.collectionTree = f.tree("old")
          await f.library.libraryRefresh.loadTree()
        }
        f.h.photoLib.collectionTree = f.tree("A")
        f.h.photoLib.inventoryCheckpoint = f.gate
        if stale { f.library.invalidateCache(changedThumbnailAssetIDs: []) }
        f.window.orderFront(nil)
        let key = action == .sidebarSelection ? "sidebar-export-selection" : "toolbar-export"
        try #require(await observe(in: f.window) { f.counter.renderedActions[key] != nil })
        let before = await f.gate.enteredSoFar
        f.counter.renderedActions[key]?()
        try #require(
          await eventually("owned tree load or completed preparation") {
            await f.gate.enteredSoFar > before || !f.h.manager.isEnqueueingAll
          })
        #expect(f.h.manager.isEnqueueingAll)
        #expect(f.h.manager.pendingJobs.isEmpty)
        let tasks = f.h.manager.currentPreparationTasks
        await f.gate.releaseAll()
        for task in tasks { await task.value }
        let expected: Set<String> = action == .all ? ["A", "B", "favorite"] : ["A", "B"]
        #expect(Set(f.h.manager.pendingJobs.map(\.assetLocalIdentifier)) == expected)
      } cleanup: {
        await f.close()
      }
    }

    @Test func cancellingHeldScopeResolutionCannotDispatchIntoANewerRun() async throws {
      let f = Fixture(action: .all)
      try await withCleanup {
        f.h.photoLib.collectionTree = f.tree("A")
        f.h.photoLib.inventoryCheckpoint = f.gate
        f.window.orderFront(nil)
        try #require(
          await observe(in: f.window) { f.counter.renderedActions["toolbar-export"] != nil })
        let before = await f.gate.enteredSoFar
        f.counter.renderedActions["toolbar-export"]?()
        try #require(
          await eventually("held action or completed preparation") {
            await f.gate.enteredSoFar > before || !f.h.manager.isEnqueueingAll
          })
        #expect(f.h.manager.pendingJobs.isEmpty)
        let oldTasks = f.h.manager.currentPreparationTasks
        f.h.manager.cancelAndClear()
        f.h.photoLib.inventoryCheckpoint = nil
        f.h.manager.startExportCollectionsSelection(
          CollectionsSelectionBuckets(includesFavorites: false, albumIds: ["B"], sharedAlbumIds: [])
        )
        let newTasks = f.h.manager.currentPreparationTasks
        for task in newTasks { await task.value }
        await f.gate.releaseAll()
        for task in oldTasks { await task.value }
        #expect(f.h.manager.pendingJobs.map(\.assetLocalIdentifier) == ["B"])
      } cleanup: {
        await f.close()
      }
    }
  }
#endif
