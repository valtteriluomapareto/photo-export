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

    func queueReadThroughProbes() -> [ObservationProbe] {
      [
        ObservationProbe { _ = self.manager.queuedCount(year: 2001, month: 1) },
        ObservationProbe { _ = self.manager.queuedCountsByPlacementId },
        ObservationProbe { _ = self.manager.pendingJobs },
        ObservationProbe { _ = self.manager.currentTask },
        ObservationProbe { _ = self.manager.isProcessing },
      ]
    }

    func bridgedProbes() -> [ObservationProbe] {
      [
        ObservationProbe { _ = self.manager.isRunning },
        ObservationProbe { _ = self.manager.queueCount },
        ObservationProbe { _ = self.manager.activeRunContext },
        ObservationProbe { _ = self.manager.isEnqueueingAll },
        ObservationProbe { _ = self.manager.versionSelection },
        ObservationProbe { _ = self.manager.convertHEICToJPEG },
        ObservationProbe { _ = self.manager.livePhotosPairedExport },
        ObservationProbe { _ = self.manager.isImporting },
        ObservationProbe { _ = self.manager.importStage },
        ObservationProbe { _ = self.manager.previousBackupMissing },
      ]
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

  enum Setting: CaseIterable, Sendable {
    case versions, heic, paired
    var index: Int {
      switch self {
      case .versions: 4
      case .heic: 5
      case .paired: 6
      }
    }
    @MainActor func write(_ manager: ExportManager) {
      switch self {
      case .versions: manager.versionSelection = .editedWithOriginals
      case .heic: manager.convertHEICToJPEG = true
      case .paired: manager.livePhotosPairedExport = true
      }
    }
  }

  /// Changing writes already notify only themselves; repeating a value must stay silent.
  @Test(arguments: Setting.allCases)
  func settingsBridgesNotifyOnlyTheirOwnProperty(setting: Setting) async {
    let f = Fixture()
    await withCleanup {
      let probes = f.bridgedProbes()
      setting.write(f.manager)
      var expected = Array(repeating: 0, count: 10)
      expected[setting.index] = 1
      #expect(probes.map(\.changeCount) == expected)
      setting.write(f.manager)
      #expect(probes.map(\.changeCount) == expected)
    } cleanup: {
      await f.close()
    }
  }

  /// Import transitions already notify their own probes; equal missing-flag writes must stay silent.
  @Test func importBridgesNotifyTheirOwnProperties() async {
    let f = Fixture()
    await withCleanup {
      let probes = f.bridgedProbes()
      f.manager.startImport()
      f.manager.cancelImport()
      #expect(probes.prefix(9).map(\.changeCount) == [0, 0, 0, 0, 0, 0, 0, 2, 2])
      #expect(probes[9].changeCount == 0)
    } cleanup: {
      await f.close()
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

  /// Without a dependency on queue contents, every probe remains at zero.
  @Test func queueReadThroughsRegisterDependencies() async {
    let f = Fixture()
    await withCleanup {
      let probes = f.queueReadThroughProbes()
      f.enqueueOne()
      #expect(probes.map(\.changeCount) == [1, 1, 1, 1, 1])
      f.manager.queueCoordinator.enqueue([])
      #expect(probes.map(\.changeCount) == [1, 1, 1, 1, 1])
      f.manager.queueCoordinator.processQueueIfNeeded()
      #expect(probes.map(\.changeCount) == [2, 2, 2, 2, 2])
      f.manager.cancelAndClear()
      #expect(probes.map(\.changeCount) == [3, 3, 3, 3, 3])
    } cleanup: {
      await f.close()
    }
  }

  /// Unrelated writes are silent even without queue dependencies; the final enqueue
  /// proves the probes are active once those dependencies are registered.
  @Test func queueReadThroughsStaySilentWithoutQueueChanges() async {
    let f = Fixture()
    await withCleanup {
      let probes = f.queueReadThroughProbes()
      f.manager.cancelAndClear()
      #expect(probes.map(\.changeCount) == [0, 0, 0, 0, 0])
      f.manager.clearPending()
      #expect(probes.map(\.changeCount) == [0, 0, 0, 0, 0])
      f.manager.queueCoordinator.pause()
      #expect(f.manager.isPaused)
      #expect(probes.map(\.changeCount) == [0, 0, 0, 0, 0])
      f.manager.versionSelection = .editedWithOriginals
      #expect(probes.map(\.changeCount) == [0, 0, 0, 0, 0])
      f.manager.progressState.currentAssetFilename = "UNRELATED.HEIC"
      #expect(probes.map(\.changeCount) == [0, 0, 0, 0, 0])
      f.enqueueOne()
      #expect(probes.map(\.changeCount) == [1, 1, 1, 1, 1])
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
        // A declaration keeps the probe out of ViewBuilder's view expressions.
        // swiftlint:disable:next redundant_discardable_let
        let _ = counter.record(
          "run-state:\(manager.hasActiveExportWork):\(manager.queueCount)")
        Color.clear.frame(width: 1, height: 1)
      }
    }

    /// A plain holder can refresh only through the month query's Observation dependency.
    @MainActor
    private struct MonthQueueReader: View {
      let manager: ExportManager
      let counter: BodyInvalidationCounter
      var body: some View {
        let text = "queued:\(manager.queuedCount(year: 2001, month: 1))"
        // swiftlint:disable:next redundant_discardable_let
        let _ = counter.record(text)
        Text(text)
      }
    }

    /// The publication barrier stays live independently of the plain reader's dependencies.
    @MainActor
    private struct QueuePublicationProbe: View {
      @ObservedObject var manager: ExportManager
      let counter: BodyInvalidationCounter
      var body: some View {
        // swiftlint:disable:next redundant_discardable_let
        let _ = counter.record("queue-publication:\(manager.queueCount)")
        Color.clear.frame(width: 1, height: 1)
      }
    }

    @Test func viewHoldingThePlainManagerFollowsMonthQueueCounts() async throws {
      let f = Fixture()
      let counter = BodyInvalidationCounter()
      let window = HostedViewHarness.makeWindow(
        contentRect: NSRect(x: -10_000, y: -10_000, width: 100, height: 40),
        styleMask: [.borderless])
      window.contentView = NSHostingView(
        rootView: HStack {
          MonthQueueReader(manager: f.manager, counter: counter)
          QueuePublicationProbe(manager: f.manager, counter: counter)
        })
      window.orderFront(nil)
      try await withCleanup {
        try #require(
          await observe(in: window) {
            counter.count(for: "queued:0") > 0
              && counter.count(for: "queue-publication:0") > 0
          })
        window.contentView?.layoutSubtreeIfNeeded()
        let readerZero = counter.count(for: "queued:0")
        let publicationZero = counter.count(for: "queue-publication:0")

        f.manager.queueCoordinator.enqueue(
          (0..<2).map { index in
            .init(
              assetLocalIdentifier: "queued-\(index)",
              placement: .timeline(year: 2001, month: 1), selection: .edited)
          })
        try #require(
          await observe(in: window) { counter.count(for: "queue-publication:2") > 0 })
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(counter.count(for: "queued:2") > 0)

        f.manager.clearPending()
        try #require(
          await observe(in: window) {
            counter.count(for: "queue-publication:0") > publicationZero
          })
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(counter.count(for: "queued:0") > readerZero)
      } cleanup: {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        await f.close()
      }
    }

    /// Re-runs on every manager publication, so its key shows a publication has rendered.
    @MainActor
    private struct PublicationProbe: View {
      @ObservedObject var manager: ExportManager
      let counter: BodyInvalidationCounter
      var body: some View {
        // A declaration keeps the probe out of ViewBuilder's view expressions.
        // swiftlint:disable:next redundant_discardable_let
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
