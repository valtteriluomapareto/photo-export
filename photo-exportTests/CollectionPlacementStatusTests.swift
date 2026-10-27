import AppKit
import SwiftUI
import Observation
import Testing

@testable import Photo_Export

#if DEBUG
  @MainActor
  @Suite(.serialized, .timeLimit(.minutes(2)))
  struct CollectionPlacementStatusTests {
    enum Change: CaseIterable { case rename, ancestorRename, move, sharedRename }

    @Observable
    final class RenderTick { var value = 0 }

    @MainActor
    private struct Host: View {
      let service: FakePhotoLibraryService
      let manager: ExportManager
      let selection: LibrarySelection
      let folderId: String?
      var showsSidebar = true
      var showsFolderPane = true
      let tick: RenderTick
      let records: CollectionExportRecordStore
      let counter: BodyInvalidationCounter
      @State private var selectedAsset: AssetDescriptor?
      @State private var sidebarSelection: Set<LibrarySelection> = []
      @State private var folderSelection: LibrarySelection?

      var body: some View {
        HStack(alignment: .top) {
          if showsSidebar {
            CollectionsSidebarView(selectionSet: $sidebarSelection, exportManager: manager)
              .frame(width: 260)
          }
          CollectionContentView(
            selection: selection, title: "Current album", versionSelection: .edited,
            livePhotosPaired: false, onExportCollection: {}, selectedAsset: $selectedAsset,
            photoLibraryService: service
          ).equatable().frame(width: 350)
          if let folderId, showsFolderPane {
            FolderContentView(
              folderId: folderId, title: "Current folder", selection: $folderSelection,
              selectedAsset: $selectedAsset, photoLibraryService: service
            ).frame(width: 350)
          }
        }
        .overlay { PublicationProbe(tick: tick, records: records, counter: counter) }
      }
    }

    private struct PublicationProbe: View {
      let tick: RenderTick
      let records: CollectionExportRecordStore
      let counter: BodyInvalidationCounter
      var body: some View {
        // swiftlint:disable:next redundant_discardable_let
        let _ = counter.record("collection-barrier:\(tick.value)")
        // swiftlint:disable:next redundant_discardable_let
        let _ = counter.record("sidebar-publication:\(records.mutationCounter)")
        Color.clear.frame(width: 1, height: 1)
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
      // Preserve rendered snapshots while mounted; unchanged children may skip body evaluation.
      let counter = BodyInvalidationCounter()
      let tick = RenderTick()
      let asset = TestAssetFactory.makeAsset(id: "changed-asset")
      let unchangedAsset = TestAssetFactory.makeAsset(id: "unchanged-asset")
      let root = TestScratch.directory("CollectionPlacementStatus")
      let defaultsName = TestScratch.suiteName("PlacementStatus")
      let defaults: UserDefaults
      let selection: LibrarySelection
      let old: ExportPlacement
      let current: ExportPlacement
      let unchanged: ExportPlacement?
      let currentTree: [PhotoCollectionDescriptor]
      let folderId: String?
      let sidebarFolderId: String?
      var window: NSWindow?

      init(change: Change, notificationClock: (any AutoSyncClock)? = nil) async throws {
        library = PhotoLibraryManager(overrideService: service)
        timeline = ExportRecordStore(baseDirectoryURL: root)
        records = CollectionExportRecordStore(
          baseDirectoryURL: root, notificationClock: notificationClock ?? SystemAutoSyncClock())
        defaults = TestScratch.defaults(suiteName: defaultsName)
        await timeline.configureAndWait(for: "A")
        await records.configureAndWait(for: "A")
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

      func show(
        selectionOverride: LibrarySelection? = nil, sidebar: Bool = true, folderPane: Bool = true
      ) {
        let hosted = NSHostingView(
          rootView:
            Host(
              service: service, manager: manager, selection: selectionOverride ?? selection,
              folderId: folderId, showsSidebar: sidebar, showsFolderPane: folderPane,
              tick: tick, records: records, counter: counter
            )
            .environment(library).environment(timeline).environment(records)
            .environment(manager)
            .environmentObject(ExportDestinationManager(skipRestore: true, userDefaults: defaults))
            .environment(\.bodyInvalidationCounter, counter).defaultAppStorage(defaults))
        let hostWindow = NSWindow(
          contentRect: NSRect(x: -10000, y: -10000, width: 1000, height: 800),
          styleMask: [.borderless], backing: .buffered, defer: false)
        hostWindow.isReleasedWhenClosed = false
        hostWindow.contentView = hosted
        window = hostWindow
        hostWindow.orderFront(nil)
      }

      /// Reads live fake counts; the fake's own count cache survives `invalidateCache`.
      static func liveCount(
        _ service: FakePhotoLibraryService, _ scope: PhotoFetchScope, adjusted: Bool
      ) async throws -> Int {
        adjusted
          ? try await service.countAdjustedAssets(in: scope)
          : try await service.countAssets(in: scope)
      }

      func useLiveCounts() {
        service.cachedCountOverride = { [service] scope, adjusted in
          try await Self.liveCount(service, scope, adjusted: adjusted)
        }
      }

      func barrier() async throws {
        tick.value += 1
        let key = "collection-barrier:\(tick.value)"
        try #require(await observe(in: window) { counter.count(for: key) > 0 })
        var awaited = 0
        while awaited < counter.tasks.count {
          let pending = Array(counter.tasks.dropFirst(awaited))
          awaited = counter.tasks.count
          for task in pending { _ = await finished(task) }
        }
        window?.contentView?.layoutSubtreeIfNeeded()
      }

      func close() {
        window?.orderOut(nil)
        window?.contentView = nil
        window?.close()
        window = nil
        counter.reset()
        timeline.drainSynchronously()
        records.drainSynchronously()
        defaults.removePersistentDomain(forName: defaultsName)
        fakeDestination.cleanup()
        try? FileManager.default.removeItem(at: root)
      }
    }

    @Test(arguments: [false, true])
    func sidebarUpdatesOnlyAffectedBadge(folder: Bool) async throws {
      let f = try await Fixture(
        change: folder ? .ancestorRename : .rename, notificationClock: TestClock())
      defer { f.close() }
      let other = PhotoCollectionDescriptor(
        id: "album:other", localIdentifier: "other", title: "Other", kind: .album,
        pathComponents: [], children: [])
      f.service.collectionTree = f.currentTree + [other]
      f.service.assetsByAlbumLocalId["other"] = [TestAssetFactory.makeAsset(id: "other")]
      let otherPlacement = try ExportPlacementResolver().placement(
        for: .album(collectionId: "other"), collections: [other], existingPlacements: [])
      f.set(f.current, .inProgress)
      f.set(otherPlacement, .inProgress, assetId: "other")
      if let stable = f.unchanged { f.set(stable, .done, assetId: "unchanged-asset") }
      f.records.flushPendingNotifications()
      f.show(folderPane: false)
      let changedKey = folder ? "folder-sidebar:folder:folder" : "collection-sidebar:album:target"
      try #require(
        await observe(in: f.window) {
          f.counter.renderedText["collection-sidebar:album:other"] == ["notStarted(total: 1)"]
            && f.counter.renderedText[changedKey] != nil
        })
      try await f.barrier()
      let otherBodies = f.counter.count(for: "collection-row-body:album:other")
      let changedBodyKey =
        folder ? "folder-row-body:folder:folder" : "collection-row-body:album:target"
      let changedBodies = f.counter.count(for: changedBodyKey)
      f.set(f.current, .done)
      f.records.flushPendingNotifications()
      let revisionKey = "sidebar-publication:\(f.records.mutationCounter)"
      try #require(
        await observe(in: f.window) {
          f.counter.renderedText[changedKey] == ["complete"]
            && f.counter.count(for: revisionKey) > 0
        })
      try await f.barrier()
      #expect(f.counter.count(for: "collection-row-body:album:other") == otherBodies)
      #expect(f.counter.count(for: changedBodyKey) - changedBodies <= 1)
    }

    @Test func coalescedChildChangesLeaveNetZeroFolderBadgeQuiet() async throws {
      let f = try await Fixture(change: .ancestorRename, notificationClock: TestClock())
      defer { f.close() }
      let stable = try #require(f.unchanged)
      let folder = try #require(f.currentTree.first)
      let target = try #require(folder.children.first { $0.localIdentifier == "target" })
      let unchanged = try #require(folder.children.first { $0.localIdentifier == "stable" })
      f.set(f.current, .done)
      f.set(stable, .inProgress, assetId: "unchanged-asset")
      f.records.flushPendingNotifications()
      let folderStatus = f.records.sidebarStatus(for: folder)
      let targetStatus = f.records.sidebarStatus(for: target)
      let stableStatus = f.records.sidebarStatus(for: unchanged)
      let folderProbe = ObservationProbe { _ = folderStatus.value }
      let targetProbe = ObservationProbe { _ = targetStatus.value }
      let stableProbe = ObservationProbe { _ = stableStatus.value }
      defer {
        folderProbe.stop()
        targetProbe.stop()
        stableProbe.stop()
      }
      f.set(f.current, .inProgress)
      f.set(stable, .done, assetId: "unchanged-asset")
      #expect(targetStatus.value.exportedCount == 1)
      #expect(stableStatus.value.exportedCount == 0)
      f.records.flushPendingNotifications()
      #expect(folderStatus.value.exportedCount == 1)
      #expect(folderProbe.changeCount == 0)
      #expect(targetStatus.value.exportedCount == 0)
      #expect(stableStatus.value.exportedCount == 1)
      // Each source publication replaces one equatable snapshot per changed row.
      #expect(targetProbe.changeCount > 0 && targetProbe.changeCount <= 1)
      #expect(stableProbe.changeCount > 0 && stableProbe.changeCount <= 1)
    }

    enum BadgeReentry: CaseIterable { case identicalTree, firstBadgeFlush }

    @Test(arguments: BadgeReentry.allCases)
    func reentrantPublicationDeliversBothPendingBadges(reentry: BadgeReentry) async throws {
      let f = try await Fixture(change: .ancestorRename, notificationClock: TestClock())
      defer { f.close() }
      let stable = try #require(f.unchanged)
      let folder = try #require(f.currentTree.first)
      let target = try #require(folder.children.first { $0.localIdentifier == "target" })
      let unchanged = try #require(folder.children.first { $0.localIdentifier == "stable" })
      f.set(f.current, .inProgress)
      f.set(stable, .inProgress, assetId: "unchanged-asset")
      f.records.flushPendingNotifications()
      f.records.updateSidebarCollections(f.currentTree)
      let targetStatus = f.records.sidebarStatus(for: target)
      let stableStatus = f.records.sidebarStatus(for: unchanged)
      var reentered = false
      func reenter(placement: ExportPlacement, assetId: String) {
        guard !reentered else { return }
        reentered = true
        switch reentry {
        case .identicalTree: f.records.updateSidebarCollections(f.currentTree)
        case .firstBadgeFlush:
          // Changing another variant preserves this badge's any-done value.
          f.records.markVariantInProgress(
            assetId: assetId, placement: placement, variant: .edited, filename: "EDIT.JPG")
          f.records.flushPendingNotifications()
        }
      }
      let targetProbe = ObservationProbe(
        { _ = targetStatus.value },
        onChange: {
          reenter(placement: f.current, assetId: "changed-asset")
        })
      let stableProbe = ObservationProbe(
        { _ = stableStatus.value },
        onChange: {
          reenter(placement: stable, assetId: "unchanged-asset")
        })
      defer {
        targetProbe.stop()
        stableProbe.stop()
      }
      f.set(f.current, .done)
      f.set(stable, .done, assetId: "unchanged-asset")
      f.records.flushPendingNotifications()
      #expect(reentered)
      #expect(targetStatus.value.exportedCount == 1)
      #expect(stableStatus.value.exportedCount == 1)
      #expect(targetProbe.changeCount == 1)
      #expect(stableProbe.changeCount == 1)
      // An unchanged later publication cannot serve as a delayed delivery for either row.
      f.records.updateSidebarCollections(f.currentTree)
      #expect(targetProbe.changeCount == 1)
      #expect(stableProbe.changeCount == 1)
    }

    @Test func badgePublicationCannotRestoreHistoryAfterReentrantConfigure() async throws {
      let f = try await Fixture(change: .ancestorRename, notificationClock: TestClock())
      defer { f.close() }
      let folder = try #require(f.currentTree.first)
      let target = try #require(folder.children.first { $0.localIdentifier == "target" })
      f.set(f.current, .inProgress)
      f.records.flushPendingNotifications()
      let folderStatus = f.records.sidebarStatus(for: folder)
      let targetStatus = f.records.sidebarStatus(for: target)
      var reconfigured = false
      let probe = ObservationProbe(
        {
          _ = folderStatus.value
          _ = targetStatus.value
        },
        onChange: {
          guard !reconfigured else { return }
          reconfigured = true
          f.records.beginConfigure(for: "B")
        })
      defer { probe.stop() }
      f.set(f.current, .done)
      f.records.flushPendingNotifications()
      #expect(reconfigured)
      await f.records.waitUntilSettled()
      #expect(f.records.state == .ready)
      #expect(f.records.recordBodies.isEmpty)
      #expect(f.records.summary(for: f.current).totalCount == 0)
      #expect(folderStatus.value.exportedCount == 0)
      #expect(targetStatus.value.exportedCount == 0)
      #expect(!targetStatus.value.hasPlacement)
      #expect(f.records.currentGridPlacement(for: f.selection, collections: f.currentTree) == nil)
    }

    @Test func replacingSidebarTreeReleasesRemovedBadgesAndUpdatesCurrentPaths() async throws {
      let f = try await Fixture(change: .rename, notificationClock: TestClock())
      defer { f.close() }
      let current = try #require(f.currentTree.first)
      f.set(f.old, .done)
      f.set(f.current, .inProgress)
      f.records.flushPendingNotifications()
      f.records.updateSidebarCollections([current])
      var status: CollectionExportRecordStore.SidebarStatus? = f.records.sidebarStatus(for: current)
      weak var released = status
      let historical = PhotoCollectionDescriptor(
        id: current.id, localIdentifier: current.localIdentifier, title: "Old", kind: .album,
        pathComponents: [], children: [])
      f.records.updateSidebarCollections([historical])
      #expect(f.records.sidebarStatus(for: historical) === status)
      #expect(status?.value.exportedCount == 1)
      status = nil
      f.records.updateSidebarCollections([])
      #expect(released == nil)
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
      await reopened.configureAndWait(for: "A")
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
      reopened.drainSynchronously()
    }

    @Test(.timeLimit(.minutes(3)), arguments: Change.allCases)
    func historicalSuccessDoesNotCompleteChangedTarget(change: Change) async throws {
      let f = try await Fixture(change: change)
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
      let f = try await Fixture(change: change)
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
      let f = try await Fixture(change: .ancestorRename)
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
      f.service.collectionTree = f.currentTree
      f.library.invalidateCache(changedThumbnailAssetIDs: [])
      f.library.libraryRefresh.flush()
      await expectStatus(f, exported: false, currentExists: false)
      try await verifyUnchangedHistory(f, mutations: mutations)
      f.set(f.current, .done)
      let currentNotified = await observe { f.records.mutationCounter > mutations }
      try #require(currentNotified)
      await expectStatus(f, exported: true)
      let currentMutations = f.records.mutationCounter
      for fails in [false, true] {
        f.service.collectionTree = []
        f.service.collectionTreeError = fails ? CocoaError(.fileReadUnknown) : nil
        f.library.invalidateCache(changedThumbnailAssetIDs: [])
        f.library.libraryRefresh.flush()
        let missing = await observe {
          f.counter.renderedText["collection-summary"] == ["0/1"]
            && f.counter.renderedText["thumbnail-exported:changed-asset"] == ["false"]
        }
        #expect(missing)
        #expect(f.records.mutationCounter == currentMutations)
        f.service.collectionTreeError = nil
        f.service.collectionTree = f.currentTree
        f.library.invalidateCache(changedThumbnailAssetIDs: [])
        f.library.libraryRefresh.flush()
        await expectStatus(f, exported: true)
      }
      try await verifyUnchangedHistory(f, mutations: currentMutations)
      #expect(f.old.relativePath == "Collections/Albums/Old Folder/Album/")
      #expect(f.current.relativePath == "Collections/Albums/Folder/Album/")
    }

    @Test(.timeLimit(.minutes(2)))
    func favoritesIgnoreTreeErrorsAndDestinationSwitchDoesNotBorrowHistory() async throws {
      let f = try await Fixture(change: .rename)
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
      await f.records.configureAndWait(for: "B")
      let other = await observe {
        f.counter.renderedText["collection-summary"] == ["0/1"]
          && f.counter.renderedText["thumbnail-exported:changed-asset"] == ["false"]
          && f.counter.renderedText["collection-sidebar:favorites"] == ["count:1"]
      }
      #expect(other)
      #expect(f.records.placements.isEmpty)
      await f.records.configureAndWait(for: "A")
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

#if DEBUG
  extension CollectionPlacementStatusTests {
    /// A Photos library change refreshes the folder in place: the multi-selection survives,
    /// and only a child that left the folder drops out of it.
    @Test(.timeLimit(.minutes(2)))
    func libraryChangeKeepsFolderSelectionAndPrunesRemovedChildren() async throws {
      let f = try await Fixture(change: .ancestorRename)
      defer { f.close() }
      f.useLiveCounts()
      f.show(sidebar: false)
      let loaded = await observe { f.counter.renderedText["folder-summary"] == ["0/2"] }
      try #require(loaded)
      let selectAll = try #require(f.counter.renderedActions["folder-select-all"])
      selectAll()
      let both = ["album:stable", "album:target"]
      let selected = await observe { f.counter.renderedText["folder-selection"] == both }
      try #require(selected)

      f.service.assetsByAlbumLocalId["stable"]?.append(TestAssetFactory.makeAsset(id: "added"))
      f.library.invalidateCache()
      f.library.libraryRefresh.flush()
      let refreshed = await observe { f.counter.renderedText["folder-summary"] == ["0/3"] }
      try #require(refreshed)
      #expect(f.counter.renderedText["folder-selection"] == both)

      let folder = try #require(f.service.collectionTree.first)
      f.service.collectionTree = [
        PhotoCollectionDescriptor(
          id: folder.id, localIdentifier: folder.localIdentifier, title: folder.title,
          kind: folder.kind, pathComponents: folder.pathComponents,
          children: folder.children.filter { $0.id != "album:target" })
      ]
      f.library.invalidateCache()
      f.library.libraryRefresh.flush()
      let pruned = await observe { f.counter.renderedText["folder-summary"] == ["0/2"] }
      try #require(pruned)
      #expect(f.counter.renderedText["folder-selection"] == ["album:stable"])
    }

    enum FolderCountSurface: CaseIterable { case folderPane, sidebarBadge }

    /// A folder count load superseded by a newer library change must not publish, or a
    /// stale (or, in the manager, cancelled-as-zero) result overwrites the newer counts.
    @Test(.timeLimit(.minutes(2)), arguments: FolderCountSurface.allCases)
    func supersededFolderCountLoadDoesNotOverwriteNewerCounts(
      surface: FolderCountSurface
    ) async throws {
      let f = try await Fixture(change: .ancestorRename)
      defer { f.close() }
      let older = AsyncCheckpoint()
      let newer = AsyncCheckpoint()
      try await withCleanup {
        let (key, supersededKey, rendered): (String, String, (Int) -> [String]) =
          switch surface {
          case .folderPane: ("folder-summary", "folder-counts-superseded", { ["0/\($0)"] })
          case .sidebarBadge:
            (
              "folder-sidebar:folder:folder", "sidebar-folder-count-superseded",
              { ["notStarted(total: \($0))"] }
            )
          }
        // Exactly one view loads the folder's counts, so 'stable' fetches map to its loads.
        // The sidebar folder starts collapsed, so its album rows don't fetch 'stable' too.
        f.useLiveCounts()
        f.show(sidebar: surface == .sidebarBadge, folderPane: surface == .folderPane)
        let loaded = await observe { f.counter.renderedText[key] == rendered(2) }
        try #require(loaded)

        let service = f.service
        let stale = try await Fixture.liveCount(
          service, .album(collectionId: "stable"), adjusted: false)
        service.assetsByAlbumLocalId["stable"]?.append(TestAssetFactory.makeAsset(id: "added"))
        var stableFetches = 0
        service.cachedCountOverride = { scope, adjusted in
          if case .album("stable") = scope, !adjusted {
            stableFetches += 1
            if stableFetches == 1 {
              await older.enter()
              return stale
            }
            await newer.enter()
          }
          return try await Fixture.liveCount(service, scope, adjusted: adjusted)
        }
        f.library.invalidateCache()
        f.library.libraryRefresh.flush()
        let olderStarted = await older.waitForEnter(count: 1)
        try #require(olderStarted)
        f.library.invalidateCache()
        f.library.libraryRefresh.flush()
        let newerStarted = await newer.waitForEnter(count: 1)
        try #require(newerStarted, "A newer library change must restart the folder count load")
        await newer.release()
        let refreshed = await observe { f.counter.renderedText[key] == rendered(3) }
        try #require(refreshed)

        let supersededBefore = f.counter.count(for: supersededKey)
        await older.release()
        let settled = await observe {
          f.counter.count(for: supersededKey) > supersededBefore
            || f.counter.renderedText[key] != rendered(3)
        }
        #expect(settled)
        #expect(f.counter.renderedText[key] == rendered(3))
      } cleanup: {
        await older.releaseAll()
        await newer.releaseAll()
      }
    }
  }
#endif
