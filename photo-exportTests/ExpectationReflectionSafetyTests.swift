import AppKit
import SwiftUI
import Testing

@testable import Photo_Export

/// A failing expectation whose captured value has reference cycles must record an issue, not
/// overflow the stack while Swift Testing reflects it (#277). swift-testing 6.0.3 (Xcode 16.2) did,
/// and needed leaf mirrors on the cyclic types; 6.1+ bounds reflection itself (#302).
#if DEBUG
  @MainActor
  @Suite(.timeLimit(.minutes(1)))
  struct ExpectationReflectionSafetyTests {
    private struct SubscribingView: View {
      @Environment(ExportManager.self) var manager
      @Environment(PhotoLibraryManager.self) var library
      @Environment(ExportRecordStore.self) var store
      @Environment(CollectionExportRecordStore.self) var collections
      @Environment(ExportProgressState.self) var progress
      let counts: TimelineSidebarCounts
      var body: some View {
        Text(
          "\(manager.queueCount) \(library.libraryRevision) \(store.state) \(progress.totalJobsCompleted)"
        )
      }
    }

    /// Mirrors the shape of the hosted fixtures that tests capture as `f` or `fixture`.
    @MainActor
    private final class HostedFixture {
      let root = TestScratch.directory("ExpectationReflectionSafety")
      let suite = TestScratch.suiteName("ExpectationReflectionSafety")
      let defaults: UserDefaults
      let service = FakePhotoLibraryService()
      let destination = FakeExportDestination()
      let library: PhotoLibraryManager
      let timeline: ExportRecordStore
      let collections: CollectionExportRecordStore
      let manager: ExportManager
      let counts: TimelineSidebarCounts
      let monthViewModel: MonthViewModel
      let counter = BodyInvalidationCounter()
      let hostingView: NSView
      let window: NSWindow
      var isLoaded = false

      init() {
        defaults = TestScratch.defaults(suiteName: suite)
        library = PhotoLibraryManager(overrideService: service)
        timeline = ExportRecordStore(baseDirectoryURL: root)
        collections = CollectionExportRecordStore(baseDirectoryURL: root)
        timeline.configure(for: "A")
        collections.configure(for: "A")
        manager = ExportManager(
          photoLibraryService: service, exportDestination: destination,
          exportRecordStore: timeline, collectionExportRecordStore: collections,
          assetResourceWriter: FakeAssetResourceWriter(), fileSystem: FakeFileSystem(),
          userDefaults: defaults)
        counts = TimelineSidebarCounts(service: service)
        monthViewModel = MonthViewModel(photoLibraryService: service)
        let content = SubscribingView(counts: counts)
          .environment(library).environment(timeline).environment(collections)
          .environment(manager).environment(manager.progressState)
          .environment(\.bodyInvalidationCounter, counter).defaultAppStorage(defaults)
        hostingView = NSHostingView(rootView: content)
        window = NSWindow(
          contentRect: NSRect(x: -10_000, y: -10_000, width: 200, height: 100),
          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.orderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
      }

      func close() async {
        manager.cancelAndClear()
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        try? await timeline.flush()
        try? await collections.flush()
        destination.cleanup()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
      }
    }

    /// Counts the issues a known-issue block matched. The matcher is `@Sendable`.
    private final class IssueCount: @unchecked Sendable {
      private let lock = NSLock()
      private var count = 0
      var value: Int { lock.withLock { count } }
      func increment() { lock.withLock { count += 1 } }
    }

    /// End-to-end on the real library: each failing expectation captures a receiver whose graph
    /// has reference cycles (Combine subscriptions, collaborator back-references, SwiftUI hosting
    /// internals). Both must be recorded as failed expectations; a crash ends the test run.
    @Test func failingExpectationsOnCycleRootsRecordInsteadOfCrashing() async {
      let f = HostedFixture()
      let failures = IssueCount()
      withKnownIssue("Deliberate failures capture cyclic receivers") {
        #expect(f.manager.isRunning)
        #expect(f.isLoaded)
      } matching: { issue in
        guard case .expectationFailed = issue.kind else { return false }
        failures.increment()
        return true
      }
      #expect(failures.value == 2)
      await f.close()
    }
  }
#endif
