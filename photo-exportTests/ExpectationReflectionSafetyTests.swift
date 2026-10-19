import AppKit
import SwiftUI
import Testing

@testable import Photo_Export

/// Keeps values that failing expectations capture finitely reflectable under the CI toolchain's
/// Swift Testing (Xcode 16.2, swift-testing 6.0.3). See `ExpectationReflectionSafety.swift` and
/// issue #277.
#if DEBUG
  @MainActor
  @Suite(.timeLimit(.minutes(1)))
  struct ExpectationReflectionSafetyTests {
    /// Model of swift-testing 6.0.3's `__Expression.Value.init(_reflecting:label:seenObjects:)`:
    /// https://github.com/swiftlang/swift-testing/blob/18c42c19cac3fafd61cab1156d4088664b7424ae/Sources/Testing/SourceAttribution/Expression.swift#L193-L257
    /// (Apache License v2.0 with Runtime Library Exception, Copyright Apple Inc. and the Swift
    /// project authors). Only the child traversal and its `seenObjects` bookkeeping are kept,
    /// including the repeated-visit removal fixed upstream by swiftlang/swift-testing#787. A
    /// node budget is added so an unbounded traversal is reported instead of overflowing.
    private struct SwiftTesting603Reflection {
      let budget: Int
      private(set) var visited = 0
      private(set) var deepestPath: [String] = []
      private var path: [String] = []

      init(budget: Int = 10_000) { self.budget = budget }

      /// Returns `false` when the traversal exceeds the node budget.
      mutating func terminates(reflecting subject: Any) -> Bool {
        var seenObjects: [ObjectIdentifier: AnyObject] = [:]
        reflect(subject, label: nil, seenObjects: &seenObjects)
        return visited <= budget
      }

      private mutating func reflect(
        _ subject: Any, label: String?, seenObjects: inout [ObjectIdentifier: AnyObject]
      ) {
        visited += 1
        guard visited <= budget else { return }
        path.append("\(label ?? "_"): \(type(of: subject))")
        defer { path.removeLast() }
        if path.count > deepestPath.count { deepestPath = path }

        let mirror = Mirror(reflecting: subject)
        var objectIdentifierTeRemove: ObjectIdentifier?
        var shouldIncludeChildren = true
        if mirror.displayStyle == .class, type(of: subject) is AnyObject.Type {
          let object = subject as AnyObject
          let objectIdentifier = ObjectIdentifier(object)
          let oldValue = seenObjects.updateValue(object, forKey: objectIdentifier)
          if oldValue != nil {
            shouldIncludeChildren = false
          }
          objectIdentifierTeRemove = objectIdentifier
        }
        defer {
          if let objectIdentifierTeRemove {
            seenObjects[objectIdentifierTeRemove] = nil
          }
        }
        if shouldIncludeChildren {
          for child in mirror.children {
            reflect(child.value, label: child.label, seenObjects: &seenObjects)
            if visited > budget { return }
          }
        }
      }
    }

    private func expectFinite(
      _ name: String, _ subject: Any, sourceLocation: SourceLocation = #_sourceLocation
    ) {
      var model = SwiftTesting603Reflection()
      let finite = model.terminates(reflecting: subject)
      let cycle = model.deepestPath.suffix(12).joined(separator: " > ")
      #expect(
        finite,
        "\(name) is not finitely reflectable by swift-testing 6.0.3; deepest path: … \(cycle)",
        sourceLocation: sourceLocation)
    }

    private final class Node {
      var first: Node?
      var second: Node?
    }

    /// Two objects that each reference the other twice re-enter forever in 6.0.3. This proves the
    /// model still reproduces the defect, so the checks below cannot pass vacuously.
    @Test func modelReproducesTheRepeatedVisitDefect() {
      let a = Node()
      let b = Node()
      a.first = b
      a.second = b
      b.first = a
      b.second = a
      defer {
        a.first = nil
        a.second = nil
      }
      var model = SwiftTesting603Reflection()
      let finite = model.terminates(reflecting: a)
      #expect(!finite)
    }

    private struct SubscribingView: View {
      @EnvironmentObject var manager: ExportManager
      @EnvironmentObject var library: PhotoLibraryManager
      @EnvironmentObject var store: ExportRecordStore
      @EnvironmentObject var collections: CollectionExportRecordStore
      @EnvironmentObject var progress: ExportProgressState
      @ObservedObject var counts: TimelineSidebarCounts
      var body: some View {
        Text(
          "\(manager.queueCount) \(library.libraryRevision) \(store.state) \(progress.totalJobsCompleted)"
        )
      }
    }

    /// Mirrors the shape of the hosted fixtures that tests capture as `f` or `fixture`.
    @MainActor
    private final class HostedFixture {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let suite = "ExpectationReflectionSafety-\(UUID().uuidString)"
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
        defaults = UserDefaults(suiteName: suite)!
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
          .environmentObject(library).environmentObject(timeline).environmentObject(collections)
          .environmentObject(manager).environmentObject(manager.progressState)
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

    /// Roots chosen by the types that expectations capture as receivers or operands
    /// (`f`, `fixture`, `h.manager`, `manager`, stores, `vm`, `loader`, `builder`).
    @Test func capturedTestValuesAreFinitelyReflectable() async {
      let f = HostedFixture()
      let destinationManager = ExportDestinationManager(
        skipRestore: true, userDefaults: TestScratch.defaults("DestinationManager"))
      let autoSync = AutoSyncManager()
      let builder = FakeAutoSyncEnvironmentBuilder()
      autoSync.attach(to: builder.environment)
      let lifecycle = AppLifecycleCoordinator(
        cancelActiveWork: {}, interruptForDestinationUnavailable: {},
        configureRecordStores: { _ in .success })

      expectFinite("hosted fixture", f)
      expectFinite("NSHostingView", f.hostingView)
      expectFinite("ExportManager", f.manager)
      expectFinite(
        "ExportQueueCoordinator", f.manager.queueCoordinator as ExportQueueCoordinator)
      expectFinite("ExportProgressState", f.manager.progressState)
      expectFinite("ExportRecordStore", f.timeline)
      expectFinite("CollectionExportRecordStore", f.collections)
      expectFinite("PhotoLibraryManager", f.library)
      expectFinite("TimelineSidebarCounts", f.counts)
      expectFinite("MonthViewModel", f.monthViewModel)
      expectFinite("ExportDestinationManager", destinationManager)
      expectFinite("AutoSyncManager", autoSync)
      expectFinite("FakeAutoSyncEnvironmentBuilder", builder)
      expectFinite("AppLifecycleCoordinator", lifecycle)

      await f.close()
    }

    /// End-to-end on the real library: each failing expectation captures a receiver whose graph
    /// contains the cycles above. On swift-testing 6.0.3 without the leaf mirrors this overflows
    /// the main thread's stack; newer toolchains bound reflection and pass regardless.
    @Test func failingExpectationsOnCycleRootsRecordInsteadOfCrashing() async {
      let f = HostedFixture()
      withKnownIssue("Deliberate failures capture cyclic receivers") {
        #expect(f.manager.isRunning)
        #expect(f.isLoaded)
      }
      await f.close()
    }
  }
#endif
