import AppKit
import SwiftUI
import Observation
import Testing

@testable import Photo_Export

#if DEBUG
  @MainActor
  @Suite(.serialized, .timeLimit(.minutes(1)))
  struct TimelineSidebarBadgeRefreshTests {
    @Observable
    final class RenderTick { var value = 0 }

    private struct TickProbe: View {
      let tick: RenderTick
      let counter: BodyInvalidationCounter
      var body: some View {
        // swiftlint:disable:next redundant_discardable_let
        let _ = counter.record("sidebar-barrier:\(tick.value)")
        Color.clear.frame(width: 1, height: 1)
      }
    }

    private struct Host: View {
      let service: FakePhotoLibraryService
      let manager: ExportManager
      let counter: BodyInvalidationCounter
      let tick: RenderTick
      @State private var selection: Set<LibrarySelection> = [.timelineMonth(year: 2026, month: 9)]

      var body: some View {
        TimelineSidebarView(selectionSet: $selection, photoLibraryService: service)
          .overlay(alignment: .topLeading) { ProgressProbe() }
          .overlay { TickProbe(tick: tick, counter: counter) }
          .overlay(alignment: .bottomLeading) {
            ExportManagerRenderProbe(manager: manager, counter: counter)
          }
      }
    }

    /// Renders for each per-asset progress change, so a test can wait for one to reach SwiftUI
    /// before checking that the month rows did not render for it.
    private struct ProgressProbe: View {
      @Environment(ExportProgressState.self) private var progress
      @Environment(\.bodyInvalidationCounter) private var counter
      var body: some View {
        // A declaration keeps the probe out of ViewBuilder's view expressions.
        // swiftlint:disable:next redundant_discardable_let
        let _ = counter?.record(
          "progress-probe:\(progress.currentAssetFilename ?? ""):\(progress.totalJobsCompleted)")
        Color.clear.frame(width: 1, height: 1)
      }
    }

    @MainActor
    private final class Fixture {
      let root = TestScratch.directory("TimelineSidebarBadgeRefresh")
      let suite = TestScratch.suiteName("TimelineBadgeRefresh")
      let defaults: UserDefaults
      let service = FakePhotoLibraryService()
      let library: PhotoLibraryManager
      let store: ExportRecordStore
      let manager: ExportManager
      let destination = FakeExportDestination()
      let writer = FakeAssetResourceWriter()
      let counter = BodyInvalidationCounter()
      let tick = RenderTick()
      let clock = TestClock()
      let window: NSWindow

      init(twoVisibleMonths: Bool = false) {
        defaults = TestScratch.defaults(suiteName: suite)
        service.yearCounts = [(2026, 2), (2025, 2)]
        service.cachedCountOverride = { scope, adjusted in
          switch scope {
          case .timeline(_, 9): adjusted ? 0 : 2
          case .timeline(2026, 8) where twoVisibleMonths: adjusted ? 0 : 2
          default: 0
          }
        }
        library = PhotoLibraryManager(overrideService: service)
        store = ExportRecordStore(baseDirectoryURL: root, notificationClock: clock)
        store.configure(for: "A")
        for year in [2026, 2025] {
          store.markVariantExported(
            assetId: "first-\(year)", variant: .original, year: year, month: 9,
            relPath: "\(year)/09/", filename: "first.jpg", exportedAt: Date())
        }
        store.flushPendingNotifications()
        let collections = CollectionExportRecordStore(baseDirectoryURL: root)
        collections.configure(for: "A")
        manager = ExportManager(
          photoLibraryService: service, exportDestination: destination, exportRecordStore: store,
          collectionExportRecordStore: collections,
          assetResourceWriter: writer, fileSystem: FakeFileSystem(),
          userDefaults: defaults)
        let content = Host(service: service, manager: manager, counter: counter, tick: tick)
          .environment(library).environment(store).environment(manager)
          .environment(manager.progressState)
          .environment(\.bodyInvalidationCounter, counter).defaultAppStorage(defaults)
        window = NSWindow(
          contentRect: NSRect(x: -10_000, y: -10_000, width: 300, height: 500),
          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        window.orderFront(nil)
      }

      func barrier() async throws {
        tick.value += 1
        let key = "sidebar-barrier:\(tick.value)"
        try #require(await observe(in: window) { counter.count(for: key) > 0 })
        window.contentView?.layoutSubtreeIfNeeded()
      }

      func close() async {
        manager.cancelAndClear()
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        try? await store.flush()
        destination.cleanup()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
      }

      var readinessDescription: String {
        let loads = counter.count(for: "timeline-counts-loaded")
        let years = counter.renderedText["timeline-sidebar-years"] ?? []
        let month = counter.renderedText["timeline-month:2026-9"] ?? []
        let expandedYear = counter.renderedText["timeline-year:2026"] ?? []
        let collapsedYear = counter.renderedText["timeline-year:2025"] ?? []
        return "loads=\(loads), tasks=\(counter.tasks.count), years=\(years), "
          + "month=\(month), expanded=\(expandedYear), collapsed=\(collapsedYear)"
      }
    }

    /// Fails before property-specific manager observation: pause and layout leave this badge unchanged.
    @Test(.timeLimit(.minutes(1)))
    func monthRowsSkipPauseAndVideoLayout() async throws {
      let f = Fixture()
      try await withCleanup {
        try #require(
          await observe(in: f.window) { f.counter.renderedText["timeline-month:2026-9"] == ["1/2"] }
        )
        for task in f.counter.tasks { _ = await finished(task) }
        f.window.contentView?.layoutSubtreeIfNeeded()
        try await ExportManagerRenderProbe.change(
          manager: f.manager, counter: f.counter, in: f.window
        ) {
          f.manager.queueCoordinator.enqueue([
            .init(
              assetLocalIdentifier: "queued", placement: .timeline(year: 2026, month: 9),
              selection: .edited)
          ])
        }
        let key = "timeline-month-body:2026-9"
        let before = f.counter.count(for: key)
        try #require(before > 0)
        try await ExportManagerRenderProbe.change(
          manager: f.manager, counter: f.counter, in: f.window
        ) {
          f.manager.pause()
        }
        let pause = f.counter.count(for: key) - before
        #expect(pause == 0)
        let paused = f.counter.count(for: key)
        try await ExportManagerRenderProbe.change(
          manager: f.manager, counter: f.counter, in: f.window
        ) {
          f.manager.videoLayout = .subfolder
        }
        let layout = f.counter.count(for: key) - paused
        #expect(layout == 0)
      } cleanup: {
        await f.close()
      }
    }

    @Test(.timeLimit(.minutes(1)))
    func heldRefreshRetainsRenderedBadgesAndExportProgressStillUpdates() async throws {
      let f = Fixture()
      let gate = AsyncCheckpoint()
      var failure: Error?
      do {
        let initiallyReady = await observe(in: f.window) {
          f.counter.count(for: "timeline-counts-loaded") > 0
            && f.counter.renderedText["timeline-month:2026-9"] == ["1/2"]
            && f.counter.renderedText["timeline-year:2026"] == ["50%"]
            && f.counter.renderedText["timeline-year:2025"] == ["50%"]
        }
        let initialDiagnostics = f.readinessDescription
        try #require(initiallyReady, "Initial sidebar: \(initialDiagnostics)")
        // Complete every initial appearance load before changing fake responses.
        for task in f.counter.tasks { _ = await finished(task) }
        f.service.cachedCountOverride = { scope, adjusted in
          if scope == .timeline(year: 2026, month: 9) { await gate.enter() }
          switch scope {
          case .timeline(_, 9): return adjusted ? 0 : 2
          default: return 0
          }
        }
        let tasksBeforeRefresh = f.counter.tasks.count
        let completionsBeforeRefresh = f.counter.count(for: "timeline-counts-loaded")
        f.library.invalidateCache()
        f.library.libraryRefresh.flush()
        let refreshStarted = await gate.waitForEnter(count: 2)
        try #require(refreshStarted)
        let refreshTasks = Array(f.counter.tasks.dropFirst(tasksBeforeRefresh))
        let capturedRefresh = !refreshTasks.isEmpty
        try #require(capturedRefresh)
        // Force real row evaluation while counts are held, as another file completes.
        f.store.markVariantExported(
          assetId: "second-2026", variant: .original, year: 2026, month: 9,
          relPath: "2026/09/", filename: "second.jpg", exportedAt: Date())
        f.store.flushPendingNotifications()
        let badgesStayVisible = await observe(in: f.window) {
          f.counter.renderedText["timeline-month:2026-9"] == ["complete"]
            && f.counter.renderedText["timeline-year:2026"] == ["complete"]
            && f.counter.renderedText["timeline-year:2025"] == ["50%"]
        }
        let heldDiagnostics = f.readinessDescription
        #expect(badgesStayVisible, "Held refresh: \(heldDiagnostics)")
        await gate.releaseAll()
        for task in refreshTasks { _ = await finished(task) }
        for task in f.counter.tasks { _ = await finished(task) }
        let refreshed = f.counter.count(for: "timeline-counts-loaded") > completionsBeforeRefresh
        try #require(refreshed)
        f.service.cachedCountOverride = { scope, adjusted in
          if scope == .timeline(year: 2026, month: 9), adjusted {
            throw CocoaError(.fileReadUnknown)
          }
          switch scope {
          case .timeline(_, 9): return adjusted ? 0 : 2
          default: return 0
          }
        }
        let completionsBeforeFailure = f.counter.count(for: "timeline-counts-loaded")
        f.library.invalidateCache()
        f.library.libraryRefresh.flush()
        let failedCoverageClears = await observe(in: f.window) {
          f.counter.count(for: "timeline-counts-loaded") > completionsBeforeFailure
            && f.counter.renderedText["timeline-month:2026-9"] == ["…"]
            && f.counter.renderedText["timeline-year:2026"] == []
            && f.counter.renderedText["timeline-year:2025"] == ["50%"]
        }
        let failedDiagnostics = f.readinessDescription
        #expect(failedCoverageClears, "Failed coverage: \(failedDiagnostics)")
      } catch { failure = error }
      await gate.releaseAll()
      for task in f.counter.tasks { _ = await finished(task) }
      await f.close()
      if let failure { throw failure }
    }

    /// Month rows read only the in-flight placement from the progress state, so the per-asset
    /// filename and counter writes of a run must not re-render them; a new in-flight placement
    /// must.
    @Test(.timeLimit(.minutes(1)))
    func monthRowsSkipPerAssetProgressButFollowTheInFlightPlacement() async throws {
      let f = Fixture()
      try await withCleanup {
        try #require(
          await observe(in: f.window) {
            f.counter.renderedText["timeline-month:2026-9"] == ["1/2"]
          })
        for task in f.counter.tasks { _ = await finished(task) }
        f.window.contentView?.layoutSubtreeIfNeeded()
        let key = "timeline-month-body:2026-9"
        let rows = f.counter.count(for: key)
        try #require(rows > 0)
        let progress = f.manager.progressState
        for step in 1...3 {
          progress.currentAssetFilename = "IMG_000\(step).JPG"
          progress.totalJobsCompleted = step
          let probe = "progress-probe:IMG_000\(step).JPG:\(step)"
          try #require(await observe(in: f.window) { f.counter.count(for: probe) > 0 })
        }
        #expect(
          f.counter.count(for: key) == rows,
          "Per-asset progress re-rendered the month row: \(rows) → \(f.counter.count(for: key))")
        f.manager.setCurrentJob(
          .init(
            assetLocalIdentifier: "active",
            placement: .timeline(year: 2026, month: 9), selection: .edited))
        #expect(await observe(in: f.window) { f.counter.count(for: key) > rows })
      } cleanup: {
        await f.close()
      }
    }

    @Test
    func queueStepsOnlyInvalidateTheOwningMonth() async throws {
      let f = Fixture(twoVisibleMonths: true)
      let gate = AsyncCheckpoint()
      try await withCleanup {
        try #require(
          await observe(in: f.window) {
            f.counter.renderedText["timeline-month:2026-9"] == ["1/2"]
              && f.counter.renderedText["timeline-month:2026-8"] == ["2"]
          })
        for task in f.counter.tasks { _ = await finished(task) }
        f.store.flushPendingNotifications()
        try await f.barrier()
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 15))!
        let ids = ["isolation-a", "isolation-b", "isolation-c"]
        f.service.assetsByYearMonth["2026-9"] = ids.map {
          TestAssetFactory.makeAsset(id: $0, creationDate: date)
        }
        for id in ids {
          f.service.resourcesByAssetId[id] = [
            ResourceDescriptor(type: .photo, originalFilename: "\(id).JPG")
          ]
        }
        f.writer.checkpoint = gate
        let unrelated = ObservationProbe { _ = f.manager.queuedCount(year: 2026, month: 8) }
        let before = f.counter.count(for: "timeline-month-body:2026-8")
        f.manager.queueCoordinator.enqueue(
          ids.map {
            .init(
              assetLocalIdentifier: $0, placement: .timeline(year: 2026, month: 9),
              selection: .edited)
          })
        try #require(
          await observe(in: f.window) {
            f.counter.renderedText["timeline-month:2026-9"] == ["3 left"]
          })
        try await f.barrier()
        #expect(f.counter.count(for: "timeline-month-body:2026-8") - before == 0)
        #expect(unrelated.changeCount == 0)
        let placement = ObservationProbe { _ = f.manager.progressState.currentJobPlacement }
        for step in 1...2 {
          let before = f.counter.count(for: "timeline-month-body:2026-8")
          let writes = unrelated.changeCount
          if step == 1 {
            f.manager.queueCoordinator.processQueueIfNeeded()
          } else {
            await gate.release()
          }
          try #require(await gate.waitForEnter(count: step))
          try #require(
            await observe(in: f.window) {
              f.counter.renderedText["timeline-month:2026-9"] == ["\(3 - step) left"]
            })
          f.store.flushPendingNotifications()
          try await f.barrier()
          #expect(f.counter.count(for: "timeline-month-body:2026-8") - before == 0)
          #expect(unrelated.changeCount - writes == 0)
          #expect(placement.changeCount == 1)
        }
        f.manager.pause()
        await gate.release()
        try #require(await observe(in: f.window) { !f.manager.isRunning })
        try await f.barrier()
        #expect(f.manager.currentJobPlacement == nil)
        #expect(placement.changeCount == 2)
        placement.stop()
        unrelated.stop()
      } cleanup: {
        let held = f.manager.currentTask
        f.manager.cancelAndClear()
        await gate.releaseAll()
        if let held { _ = await finished(held) }
        for task in f.counter.tasks { _ = await finished(task) }
        await f.close()
      }
    }

    @Test
    func cancellationFromMonthPublicationCannotDispatchOrRestoreTheOldJob() async throws {
      let f = Fixture()
      try await withCleanup {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 15))!
        f.service.assetsByYearMonth["2026-9"] = [
          TestAssetFactory.makeAsset(id: "cancelled-before-dispatch", creationDate: date)
        ]
        f.service.resourcesByAssetId["cancelled-before-dispatch"] = [
          ResourceDescriptor(type: .photo, originalFilename: "cancelled.JPG")
        ]
        let placement = ExportPlacement.timeline(year: 2026, month: 9)
        f.manager.queueCoordinator.enqueue([
          .init(
            assetLocalIdentifier: "cancelled-before-dispatch", placement: placement,
            selection: .edited)
        ])
        let state = f.manager.queueCoordinator.monthState(placementId: placement.id)
        var cancelled = false
        let probe = ObservationProbe(
          { _ = f.manager.queuedCount(year: 2026, month: 9) },
          onChange: {
            guard !cancelled else { return }
            cancelled = true
            f.manager.cancelAndClear()
          })
        f.manager.queueCoordinator.processQueueIfNeeded()
        let task = f.manager.currentTask
        #expect(cancelled)
        #expect(task == nil)
        #expect(f.manager.currentJobAssetId == nil)
        #expect(f.manager.currentJobPlacement == nil)
        #expect(state.snapshot == .init())
        #expect(!f.manager.isRunning)
        #expect(!f.manager.isProcessing)
        #expect(f.manager.pendingJobs.isEmpty)
        #expect(f.manager.queueCount == 0)
        if let task { _ = await finished(task) }
        #expect(f.writer.writeCalls.isEmpty)
        #expect(f.manager.currentJobAssetId == nil)
        #expect(f.manager.currentJobPlacement == nil)
        #expect(state.snapshot == .init())
        probe.stop()
      } cleanup: {
        await f.close()
      }
    }

    @Test
    func recordPublicationOnlyInvalidatesChangedMonths() async throws {
      let f = Fixture(twoVisibleMonths: true)
      try await withCleanup {
        try #require(
          await observe(in: f.window) {
            f.counter.renderedText["timeline-month:2026-9"] == ["1/2"]
              && f.counter.renderedText["timeline-month:2026-8"] == ["2"]
          })
        for task in f.counter.tasks { _ = await finished(task) }
        f.store.flushPendingNotifications()
        try await f.barrier()
        let a = ObservationProbe {
          _ = f.store.sidebarSummary(
            year: 2026, month: 9, totalCount: 2, adjustedCount: 0,
            selection: .edited, livePhotosPaired: false)
        }
        let b = ObservationProbe {
          _ = f.store.sidebarSummary(
            year: 2026, month: 8, totalCount: 2, adjustedCount: 0,
            selection: .edited, livePhotosPaired: false)
        }
        let bodiesA = f.counter.count(for: "timeline-month-body:2026-9")
        let bodiesB = f.counter.count(for: "timeline-month-body:2026-8")
        f.store.markVariantExported(
          assetId: "publication-a", variant: .original,
          year: 2026, month: 9, relPath: "2026/09/", filename: "publication.jpg",
          exportedAt: f.clock.now())
        f.store.flushPendingNotifications()
        try #require(
          await observe(in: f.window) {
            f.counter.renderedText["timeline-month:2026-9"] == ["complete"]
          })
        try await f.barrier()
        #expect(a.changeCount == 1)
        #expect(b.changeCount == 0)
        // Each changed month receives one snapshot publication; the other month receives none.
        #expect(f.counter.count(for: "timeline-month-body:2026-9") - bodiesA <= 1)
        #expect(f.counter.count(for: "timeline-month-body:2026-8") - bodiesB == 0)
        a.stop()
        b.stop()
      } cleanup: {
        await f.close()
      }
    }

    @Test(.timeLimit(.minutes(1)))
    func monthQueueBadgeFollowsEnqueueAndFirstDequeue() async throws {
      let f = Fixture()
      let gate = AsyncCheckpoint()
      try await withCleanup {
        try #require(
          await observe(in: f.window) {
            f.counter.renderedText["timeline-month:2026-9"] == ["1/2"]
          })
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 15))!
        let ids = ["queued-a", "queued-b"]
        f.service.assetsByYearMonth["2026-9"] = ids.map {
          TestAssetFactory.makeAsset(id: $0, creationDate: date)
        }
        for id in ids {
          f.service.resourcesByAssetId[id] = [
            ResourceDescriptor(type: .photo, originalFilename: "\(id).JPG")
          ]
        }
        f.writer.checkpoint = gate
        f.manager.queueCoordinator.enqueue(
          ids.map {
            .init(
              assetLocalIdentifier: $0, placement: .timeline(year: 2026, month: 9),
              selection: .edited)
          })
        #expect(
          await observe(in: f.window) {
            f.counter.renderedText["timeline-month:2026-9"] == ["2 left"]
          })
        f.manager.queueCoordinator.processQueueIfNeeded()
        try #require(await gate.waitForEnter(count: 1))
        #expect(
          await observe(in: f.window) {
            f.counter.renderedText["timeline-month:2026-9"] == ["1 left"]
          })
      } cleanup: {
        let held = f.manager.currentTask
        f.manager.cancelAndClear()
        await gate.releaseAll()
        if let held { _ = await finished(held) }
        for task in f.counter.tasks { _ = await finished(task) }
        await f.close()
      }
    }
  }
#endif
