import AppKit
import SwiftUI
import Testing

@testable import Photo_Export

#if DEBUG
  @MainActor
  struct TimelineSidebarBadgeRefreshTests {
    private struct Host: View {
      let service: FakePhotoLibraryService
      @State private var selection: Set<LibrarySelection> = [.timelineMonth(year: 2026, month: 9)]

      var body: some View {
        TimelineSidebarView(selectionSet: $selection, photoLibraryService: service)
      }
    }

    @MainActor
    private final class Fixture {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let suite = "TimelineBadgeRefresh-\(UUID().uuidString)"
      let defaults: UserDefaults
      let service = FakePhotoLibraryService()
      let library: PhotoLibraryManager
      let store: ExportRecordStore
      let manager: ExportManager
      let destination = FakeExportDestination()
      let counter = BodyInvalidationCounter()
      let window: NSWindow

      init() {
        defaults = UserDefaults(suiteName: suite)!
        service.yearCounts = [(2026, 2), (2025, 2)]
        service.cachedCountOverride = { scope, adjusted in
          switch scope {
          case .timeline(_, 9): adjusted ? 0 : 2
          default: 0
          }
        }
        library = PhotoLibraryManager(overrideService: service)
        store = ExportRecordStore(baseDirectoryURL: root)
        store.configure(for: "A")
        for year in [2026, 2025] {
          store.markVariantExported(
            assetId: "first-\(year)", variant: .original, year: year, month: 9,
            relPath: "\(year)/09/", filename: "first.jpg", exportedAt: Date())
        }
        store.flushPendingNotifications()
        manager = ExportManager(
          photoLibraryService: service, exportDestination: destination, exportRecordStore: store,
          assetResourceWriter: FakeAssetResourceWriter(), fileSystem: FakeFileSystem(),
          userDefaults: defaults)
        let content = Host(service: service)
          .environmentObject(library).environmentObject(store).environmentObject(manager)
          .environmentObject(manager.progressState)
          .environment(\.bodyInvalidationCounter, counter).defaultAppStorage(defaults)
        window = NSWindow(
          contentRect: NSRect(x: -10_000, y: -10_000, width: 300, height: 500),
          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        window.orderFront(nil)
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

    private func observe(
      in window: NSWindow, _ condition: () -> Bool,
      sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
      await eventually("observed hosted condition", sourceLocation: sourceLocation) {
        window.contentView?.layoutSubtreeIfNeeded()
        return condition()
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
  }
#endif
