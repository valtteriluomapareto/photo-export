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
@Suite(.timeLimit(.minutes(2)), .serialized)
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

  // The derived reads views make (toolbar, Settings, Import, sidebars) follow each bridged
  // input they combine, so a getter that read a bridge's value directly would fail here.

  @Test func derivedReadsFollowQueueDepth() async {
    let f = Fixture()
    await withCleanup {
      let activeWork = ObservationProbe { _ = f.manager.hasActiveExportWork }
      let canPause = ObservationProbe { _ = f.manager.canTogglePause }
      f.enqueueOne()
      #expect(activeWork.changeCount == 1)
      #expect(canPause.changeCount == 1)
    } cleanup: {
      await f.close()
    }
  }

  @Test func derivedReadsFollowRunningFlag() async {
    let f = Fixture()
    await withCleanup {
      f.enqueueOne()
      let activeWork = ObservationProbe { _ = f.manager.hasActiveExportWork }
      let canPause = ObservationProbe { _ = f.manager.canTogglePause }
      let queueCount = ObservationProbe { _ = f.manager.queueCount }
      f.manager.queueCoordinator.processQueueIfNeeded()
      // Only `isRunning` changes: the depth stays 1 as the job moves to in flight.
      #expect(queueCount.changeCount == 0)
      #expect(activeWork.changeCount == 1)
      #expect(canPause.changeCount == 1)
    } cleanup: {
      await f.close()
    }
  }

  @Test func derivedReadsFollowBulkFlag() async {
    let f = Fixture()
    await withCleanup {
      let activeWork = ObservationProbe { _ = f.manager.hasActiveExportWork }
      let canPause = ObservationProbe { _ = f.manager.canTogglePause }
      // Sets `isEnqueueingAll` before its first await; nothing else it reads changes yet.
      let enqueue = f.manager.startExportAll()
      #expect(activeWork.changeCount == 1)
      #expect(canPause.changeCount == 0)
      if let enqueue { _ = await finished(enqueue) }
    } cleanup: {
      await f.close()
    }
  }

  @Test func supersedeReadFollowsRunContext() async {
    let f = Fixture()
    await withCleanup {
      let supersede = ObservationProbe { _ = f.manager.manualExportShouldConfirmSupersede }
      f.enqueueOne()
      #expect(supersede.changeCount == 0)
      f.manager.cancelAndClear()
      let run = ExportRunContext(
        source: .autoSync, visibility: .background, scope: .timelineFullLibrary,
        selection: .edited)
      _ = await f.manager.runExport(context: run)
      #expect(supersede.changeCount == 2)
    } cleanup: {
      await f.close()
    }
  }

  /// Tearing down an idle queue writes every run-state input with the value it already holds.
  /// Observation is not notified, as for an equal write to an `@Observable` property, while
  /// `objectWillChange` fires once per write, as it does for `@Published`, and before the
  /// bridged delivery.
  @Test func unchangedRunStateWritesDoNotNotifyObservation() async {
    let f = Fixture()
    await withCleanup {
      let runState = ObservationProbe {
        _ = f.manager.activeRunContext
        _ = f.manager.isRunning
        _ = f.manager.queueCount
        _ = f.manager.isEnqueueingAll
      }
      var events: [String] = []
      let subscriptions = [
        f.manager.objectWillChange.sink { events.append("will") },
        f.manager.isEnqueueingAllPublisher.sink { events.append("enqueueing \($0)") },
      ]
      defer { subscriptions.forEach { $0.cancel() } }
      f.manager.cancelAndClear()
      #expect(runState.changeCount == 0)
      // In order: previousBackupMissing (cleared by cancelAndClear); isRunning, isPaused and
      // queueCount (the queue teardown's mirrors); then isEnqueueingAll, whose bridge
      // delivers right after its own objectWillChange.
      #expect(
        events == [
          "enqueueing false", "will", "will", "will", "will", "will", "enqueueing false",
        ])
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
        window.contentView?.layoutSubtreeIfNeeded()
        let readerBodies = counter.count(for: "run-state:false:0")

        // Not evidence that Observation is wired: an unbridged manager passes this too. It pins
        // that the reader does not start re-running for a publication it does not read.
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
