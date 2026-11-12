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
      var showsCollectionPane = true
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
          if showsCollectionPane {
            CollectionContentView(
              selection: selection, title: "Current album", versionSelection: .edited,
              livePhotosPaired: false, onExportCollection: {}, selectedAsset: $selectedAsset,
              photoLibraryService: service
            ).equatable().frame(width: 350)
          }
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
        selectionOverride: LibrarySelection? = nil, sidebar: Bool = true, folderPane: Bool = true,
        collectionPane: Bool = true
      ) {
        let hosted = NSHostingView(
          rootView:
            Host(
              service: service, manager: manager, selection: selectionOverride ?? selection,
              folderId: folderId, showsSidebar: sidebar, showsFolderPane: folderPane,
              showsCollectionPane: collectionPane,
              tick: tick, records: records, counter: counter
            )
            .environment(library).environment(timeline).environment(records)
            .environment(manager)
            .environmentObject(ExportDestinationManager(skipRestore: true, userDefaults: defaults))
            .environment(\.bodyInvalidationCounter, counter)
            .environment(\.accessibilityEnabled, true).defaultAppStorage(defaults))
        let hostWindow = NSWindow(
          contentRect: NSRect(
            x: -10000, y: -10000, width: collectionPane ? 1000 : 350, height: 800),
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
      try #require(
        await observe(in: f.window) {
          badge("1", id: "album:other", in: f)
            && badge(folder ? "1/2" : "1", id: folder ? "folder:folder" : "album:target", in: f)
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
          badge("Fully exported", id: folder ? "folder:folder" : "album:target", in: f)
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

    private func summary(_ value: String, in f: Fixture) -> Bool {
      f.window.map { NativeViewAccess.containsText(value + " exported", in: $0) } == true
    }

    private func badge(_ text: String, id: String, in f: Fixture) -> Bool {
      guard let window = f.window else { return false }
      return NativeViewAccess.identifiedElements("collection-row:" + id, in: window).contains {
        element in
        NativeViewAccess.texts(in: element).contains { $0 == text || $0.hasSuffix(", " + text) }
      }
    }

    private func folderSummary(_ value: String, albums: Int = 2, in f: Fixture) -> Bool {
      guard let window = f.window else { return false }
      return NativeViewAccess.containsText("\(albums) albums · " + value + " exported", in: window)
    }

    private func loaded(_ f: Fixture) async throws {
      try #require(
        await observe(in: f.window) {
          f.counter.count(for: "asset-tile-body:changed-asset") > 0
            && (summary("0/1", in: f) || summary("1/1", in: f))
        }, "Wait for the actual asset tile and native summary before checking status")
    }

    private func expectStatus(
      _ f: Fixture, exported: Bool, currentExists: Bool = true,
      sourceLocation: SourceLocation = #_sourceLocation
    ) async {
      if !currentExists {
        #expect(
          f.records.currentGridPlacement(for: f.selection, collections: f.currentTree) == nil,
          sourceLocation: sourceLocation)
      }
      #expect(
        await observe(in: f.window) { summary(exported ? "1/1" : "0/1", in: f) },
        sourceLocation: sourceLocation)
      if let id = f.sidebarFolderId {
        #expect(
          await observe(in: f.window) {
            folderSummary(exported ? "2/2" : "1/2", in: f)
              && badge(exported ? "Fully exported" : "1/2", id: id, in: f)
          }, sourceLocation: sourceLocation)
      } else {
        let id = f.current.kind == .sharedAlbum ? "shared:target" : "album:target"
        #expect(
          await observe(in: f.window) {
            badge(exported ? "Fully exported" : "1", id: id, in: f)
          }, sourceLocation: sourceLocation)
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
      f.records.flushPendingNotifications()
      let mutations = f.records.mutationCounter
      f.show()
      try await loaded(f)
      try await f.barrier()
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
      f.records.flushPendingNotifications()
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
      f.records.flushPendingNotifications()
      let mutations = f.records.mutationCounter
      f.show()
      try await loaded(f)
      let initial = await observe { summary("1/1", in: f) }
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
          summary("0/1", in: f)
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
      f.records.flushPendingNotifications()
      f.show(selectionOverride: .favorites)
      let original = await observe {
        summary("1/1", in: f)
          && badge("Fully exported", id: "favorites", in: f)
      }
      try #require(original)
      try await f.records.flush()
      await f.records.configureAndWait(for: "B")
      let other = await observe {
        summary("0/1", in: f)
          && badge("1", id: "favorites", in: f)
      }
      #expect(other)
      #expect(f.records.placements.isEmpty)
      await f.records.configureAndWait(for: "A")
      let restored = await observe {
        summary("1/1", in: f)
          && badge("Fully exported", id: "favorites", in: f)
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
      let loaded = await observe(in: f.window) { folderSummary("0/2", in: f) }
      try #require(loaded)
      let window = try #require(f.window)
      let selectAll = try #require(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
          windowNumber: window.windowNumber, context: nil, characters: "a",
          charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
      #expect(window.performKeyEquivalent(with: selectAll))
      let selected = await observe(in: window) {
        NativeViewAccess.containsText("2 selected · 2 albums · 0/2 exported", in: window)
      }
      try #require(selected)

      f.service.assetsByAlbumLocalId["stable"]?.append(TestAssetFactory.makeAsset(id: "added"))
      f.library.invalidateCache()
      f.library.libraryRefresh.flush()
      let refreshed = await observe(in: window) {
        NativeViewAccess.containsText("2 selected · 2 albums · 0/3 exported", in: window)
      }
      try #require(refreshed)
      #expect(NativeViewAccess.containsText("2 selected · 2 albums · 0/3 exported", in: window))

      let folder = try #require(f.service.collectionTree.first)
      f.service.collectionTree = [
        PhotoCollectionDescriptor(
          id: folder.id, localIdentifier: folder.localIdentifier, title: folder.title,
          kind: folder.kind, pathComponents: folder.pathComponents,
          children: folder.children.filter { $0.id != "album:target" })
      ]
      f.library.invalidateCache()
      f.library.libraryRefresh.flush()
      let pruned = await observe(in: window) {
        NativeViewAccess.containsText("1 selected · 1 album · 0/2 exported", in: window)
      }
      try #require(pruned)
      #expect(NativeViewAccess.containsText("1 selected · 1 album · 0/2 exported", in: window))
    }

    /// The caller must pass current-placement status to each real tile, independently.
    @Test(.timeLimit(.minutes(1)))
    func mountedFolderBadgesFollowCurrentPlacementAndKeepTheCompletedSibling() async throws {
      let f = try await Fixture(change: .ancestorRename)
      let images = AsyncCheckpoint()
      f.service.decodedThumbnailOverride = { _, _, _ in
        await images.enter()
        return nil
      }
      try await withCleanup {
        f.set(f.old, .done)
        f.set(try #require(f.unchanged), .done, assetId: f.unchangedAsset.id)
        f.records.flushPendingNotifications()
        f.show(sidebar: false, collectionPane: false)
        try #require(
          await observe(in: f.window) {
            folderSummary("1/2", in: f)
              && [f.asset.id, f.unchangedAsset.id].allSatisfy { id in
                f.service.decodedThumbnailCalls.contains {
                  $0.assetId == id && $0.deliveryMode == .highQuality
                }
              }
          })
        try await f.barrier()
        let view = try #require(f.window?.contentView)
        func bitmap() throws -> NSBitmapImageRep {
          view.layoutSubtreeIfNeeded()
          let raw = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
          view.cacheDisplay(in: view.bounds, to: raw)
          // PNG decoding normalizes extended-range host pixels before examining the real glyph.
          return try #require(
            raw.representation(using: .png, properties: [:]).flatMap(NSBitmapImageRep.init(data:)))
        }
        func pixels(_ image: NSBitmapImageRep, _ region: CGRect) throws -> Data {
          let crop = try #require(image.cgImage?.cropping(to: region))
          return try #require(
            NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:]))
        }
        let initial = try bitmap()
        var points: [CGPoint] = []
        for y in 0..<initial.pixelsHigh {
          for x in (initial.pixelsWide / 2)..<initial.pixelsWide {
            guard let color = initial.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            if color.greenComponent > 0.35 && color.greenComponent > color.redComponent + 0.15
              && color.greenComponent > color.blueComponent + 0.15
            {
              points.append(CGPoint(x: x, y: y))
            }
          }
        }
        let left = try #require(points.map(\.x).min()), top = try #require(points.map(\.y).min())
        let right = try #require(points.map(\.x).max()),
          bottom = try #require(points.map(\.y).max())
        let stableRegion = CGRect(
          x: left - 6, y: top - 6, width: right - left + 13, height: bottom - top + 13)
        // Two 144pt covers share the 350pt pane's 16pt outer padding and inter-column gap.
        let columnStep = (view.bounds.width - 32 - 16) / 2 + 16
        let changedRegion = stableRegion.offsetBy(
          dx: -columnStep * CGFloat(initial.pixelsWide) / view.bounds.width, dy: 0)
        let stable = try pixels(initial, stableRegion), missing = try pixels(initial, changedRegion)
        try #require(
          missing != stable, "Only the unchanged album starts with a real completed badge")
        f.set(f.current, .done)
        f.records.flushPendingNotifications()
        try #require(await observe(in: f.window) { folderSummary("2/2", in: f) })
        try await f.barrier()
        let completed = try bitmap()
        #expect(try pixels(completed, changedRegion) == stable)
        #expect(try pixels(completed, stableRegion) == stable)
        let folder = try #require(f.currentTree.first)
        f.service.collectionTree = [
          PhotoCollectionDescriptor(
            id: folder.id, localIdentifier: folder.localIdentifier, title: folder.title,
            kind: .folder,
            pathComponents: folder.pathComponents,
            children: folder.children.map { child in
              guard child.localIdentifier == "target" else { return child }
              return PhotoCollectionDescriptor(
                id: child.id, localIdentifier: child.localIdentifier,
                title: "Renamed", kind: .album, pathComponents: child.pathComponents, children: [])
            })
        ]
        f.library.invalidateCache(changedThumbnailAssetIDs: [])
        f.library.libraryRefresh.flush()
        try #require(await observe(in: f.window) { folderSummary("1/2", in: f) })
        try await f.barrier()
        let renamed = try bitmap()
        #expect(try pixels(renamed, changedRegion) == missing)
        #expect(try pixels(renamed, stableRegion) == stable)
      } cleanup: {
        f.close()
        await images.releaseAll()
      }
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
        let supersededKey =
          surface == .folderPane ? "folder-counts-superseded" : "sidebar-folder-count-superseded"
        let displayed: (Int) -> Bool = { count in
          surface == .folderPane
            ? folderSummary("0/\(count)", in: f)
            : badge(String(count), id: "folder:folder", in: f)
        }
        // Exactly one view loads the folder's counts, so 'stable' fetches map to its loads.
        // The sidebar folder starts collapsed, so its album rows don't fetch 'stable' too.
        f.useLiveCounts()
        f.show(sidebar: surface == .sidebarBadge, folderPane: surface == .folderPane)
        let loaded = await observe { displayed(2) }
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
        let refreshed = await observe { displayed(3) }
        try #require(refreshed)

        let supersededBefore = f.counter.count(for: supersededKey)
        await older.release()
        let settled = await observe {
          f.counter.count(for: supersededKey) > supersededBefore
            || !displayed(3)
        }
        #expect(settled)
        #expect(displayed(3))
      } cleanup: {
        await older.releaseAll()
        await newer.releaseAll()
      }
    }
  }
#endif
