import AppKit
import Combine
import Observation
import SwiftUI
import Testing

@testable import Photo_Export

/// The run-state properties behind `exportRunStatePublisher` register Observation
/// dependencies, so a view reading them refreshes without holding the manager as an
/// `ObservableObject`, while `objectWillChange` keeps firing as `@Published` fires it.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct ExportManagerObservationTests {
  @MainActor
  private final class Fixture {
    let root = TestScratch.directory("ExportManagerObservation")
    let destination = FakeExportDestination()
    let timeline: ExportRecordStore
    let collections: CollectionExportRecordStore
    let manager: ExportManager

    init() {
      timeline = ExportRecordStore(baseDirectoryURL: root)
      collections = CollectionExportRecordStore(baseDirectoryURL: root)
      timeline.configure(for: "A")
      collections.configure(for: "A")
      manager = ExportManager(
        photoLibraryService: FakePhotoLibraryService(), exportDestination: destination,
        exportRecordStore: timeline, collectionExportRecordStore: collections,
        assetResourceWriter: FakeAssetResourceWriter(), fileSystem: FakeFileSystem(),
        userDefaults: TestScratch.defaults("ExportManagerObservation"))
    }

    func enqueueOne() {
      manager.queueCoordinator.enqueue([
        .init(
          assetLocalIdentifier: "observed", placement: .timeline(year: 2001, month: 1),
          selection: .edited)
      ])
    }

    func close() async {
      manager.cancelAndClear()
      try? await timeline.flush()
      try? await collections.flush()
      destination.cleanup()
      try? FileManager.default.removeItem(at: root)
    }
  }

  @Test func queueDepthAndRunningFlagRegisterDependencies() async {
    let f = Fixture()
    await withCleanup {
      let isRunning = ObservationProbe { _ = f.manager.isRunning }
      let queueCount = ObservationProbe { _ = f.manager.queueCount }
      let context = ObservationProbe { _ = f.manager.activeRunContext }
      let enqueueing = ObservationProbe { _ = f.manager.isEnqueueingAll }
      f.enqueueOne()
      #expect(queueCount.changeCount == 1)
      #expect(isRunning.changeCount == 0)
      f.manager.queueCoordinator.processQueueIfNeeded()
      #expect(isRunning.changeCount == 1)
      // Starting the job moves it from pending to in flight: the depth stays 1.
      #expect(queueCount.changeCount == 1)
      #expect(context.changeCount == 0)
      #expect(enqueueing.changeCount == 0)
    } cleanup: {
      await f.close()
    }
  }

  @Test func runContextAndBulkFlagRegisterDependencies() async {
    let f = Fixture()
    await withCleanup {
      let context = ObservationProbe { _ = f.manager.activeRunContext }
      let enqueueing = ObservationProbe { _ = f.manager.isEnqueueingAll }
      let run = ExportRunContext(
        source: .manual, visibility: .userVisible, scope: .timelineFullLibrary,
        selection: .edited)
      _ = await f.manager.runExport(context: run)
      // Each is set when the run starts and cleared when the empty library finishes it.
      #expect(context.changeCount == 2)
      #expect(enqueueing.changeCount == 2)
    } cleanup: {
      await f.close()
    }
  }

  /// The derived reads views make (toolbar, Settings, Import, sidebars) register through the
  /// bridged properties they combine.
  @Test func derivedRunStateReadsRegisterDependencies() async {
    let f = Fixture()
    await withCleanup {
      let activeWork = ObservationProbe { _ = f.manager.hasActiveExportWork }
      let canPause = ObservationProbe { _ = f.manager.canTogglePause }
      let supersede = ObservationProbe { _ = f.manager.manualExportShouldConfirmSupersede }
      f.enqueueOne()
      #expect(activeWork.changeCount == 1)
      #expect(canPause.changeCount == 1)
      #expect(supersede.changeCount == 0)
      let run = ExportRunContext(
        source: .autoSync, visibility: .background, scope: .timelineFullLibrary,
        selection: .edited)
      f.manager.cancelAndClear()
      _ = await f.manager.runExport(context: run)
      #expect(supersede.changeCount == 2)
    } cleanup: {
      await f.close()
    }
  }

  /// Tearing down an idle queue writes every run-state input with the value it already holds.
  /// Observation is not notified, as for an equal write to an `@Observable` property, while
  /// `objectWillChange` fires once per `@Published`-style write, as it does today.
  @Test func unchangedRunStateWritesDoNotNotifyObservation() async {
    let f = Fixture()
    await withCleanup {
      let runState = ObservationProbe {
        _ = f.manager.activeRunContext
        _ = f.manager.isRunning
        _ = f.manager.queueCount
        _ = f.manager.isEnqueueingAll
      }
      var willChange = 0
      let subscription = f.manager.objectWillChange.sink { willChange += 1 }
      defer { subscription.cancel() }
      f.manager.cancelAndClear()
      #expect(runState.changeCount == 0)
      // isRunning, isPaused, queueCount and isEnqueueingAll, written by the teardown, and
      // previousBackupMissing, cleared by cancelAndClear.
      #expect(willChange == 5)
    } cleanup: {
      await f.close()
    }
  }

  // MARK: - Hosted

  #if DEBUG
    /// Holds the manager as a plain reference, so only Observation can re-run this body.
    @MainActor
    private struct RunStateReader: View {
      let manager: ExportManager
      let counter: BodyInvalidationCounter
      var body: some View {
        let _ = counter.record(
          "run-state:\(manager.hasActiveExportWork):\(manager.queueCount)")
        Color.clear.frame(width: 1, height: 1)
      }
    }

    /// Re-runs on every manager publication, so its key shows a publication has rendered.
    @MainActor
    private struct PublicationProbe: View {
      @ObservedObject var manager: ExportManager
      let counter: BodyInvalidationCounter
      var body: some View {
        let _ = counter.record("published:\(manager.versionSelection.rawValue)")
        Color.clear.frame(width: 1, height: 1)
      }
    }

    @Test func viewHoldingThePlainManagerRefreshesOnlyForRunStateItReads() async throws {
      let f = Fixture()
      let counter = BodyInvalidationCounter()
      let window = NSWindow(
        contentRect: NSRect(x: -10_000, y: -10_000, width: 20, height: 20),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(
        rootView: HStack {
          RunStateReader(manager: f.manager, counter: counter)
          PublicationProbe(manager: f.manager, counter: counter)
        })
      window.orderFront(nil)
      try await withCleanup {
        try #require(
          await eventually("first render") {
            counter.count(for: "run-state:false:0") > 0
          })
        let readerBodies = counter.count(for: "run-state:false:0")

        // A publication the reader does not read must not re-run it.
        f.manager.versionSelection = .editedWithOriginals
        try #require(
          await eventually("unrelated publication rendered") {
            counter.count(for: "published:\(ExportVersionSelection.editedWithOriginals.rawValue)")
              > 0
          })
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(counter.count(for: "run-state:false:0") == readerBodies)

        f.enqueueOne()
        #expect(
          await eventually("queued work rendered") {
            counter.count(for: "run-state:true:1") > 0
          })
      } cleanup: {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        await f.close()
      }
    }
  #endif
}
