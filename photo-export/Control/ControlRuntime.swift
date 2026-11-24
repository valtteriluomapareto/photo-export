#if DEBUG
  import AppKit
  import Combine
  import Foundation
  import Observation
  import SwiftUI

  /// Main-actor ownership keeps command admission and snapshot publication ordered.
  @MainActor
  final class ControlRuntime {
    static var launch: ControlRuntime?

    let options: ControlLaunch.Options
    let fixture: ControlFixture
    let core: AppCore
    private var revision = 0
    private var seq: Int?
    private var settledSeq: Int?
    private var windowNumber: Int?
    private var started = false
    private var publicationScheduled = false
    private var mailbox: ControlMailbox?
    private var subscriptions: Set<AnyCancellable> = []

    init(options: ControlLaunch.Options) throws {
      self.options = options
      fixture = try ControlFixture.prepare(runDirectory: options.runDirectory)
      core = AppCore(composition: try .fixture(fixture, surface: options.surface))
    }

    func start() async {
      guard !started else { return }
      started = true
      do {
        try await fixture.start(core)
        if let snapshot = options.snapshot {
          try await ControlSnapshot.capture(
            core: core, options: options, to: fixture.root.appending(path: snapshot))
          try write(snapshotState())
          publishDirectory()
          exit(EXIT_SUCCESS)
        }
        seq = 0
        settledSeq = 0
        mailbox = try ControlMailbox(
          directory: fixture.root, run: fixture.run, actions: ControlActions(core: core),
          publish: { [weak self] seq, settled in
            guard let self else { return }
            self.seq = seq
            self.settledSeq = settled
            try write(snapshotState())
          }, fail: { Self.fail($0) })
        subscribeToCombine()
        try observe()
        publishDirectory()
        mailbox?.check()
      } catch {
        Self.fail(error)
      }
    }

    func attach(_ window: NSWindow?, publishesWindowNumber: Bool) {
      if let window {
        window.isRestorable = false
        window.setFrameAutosaveName("")
      }
      guard publishesWindowNumber else { return }
      windowNumber = window.flatMap { $0.windowNumber > 0 ? $0.windowNumber : nil }
      if mailbox != nil { schedulePublication() }
    }

    private func subscribeToCombine() {
      // Combine delivers before mutation. Project on the next main-actor turn.
      for publisher in [
        core.exportDestinationManager.controlStateChanges, core.autoSyncManager.controlStateChanges,
        core.lifecycleCoordinator.migrationConflictPublisher.map { _ in () }.eraseToAnyPublisher(),
        core.destinationSafetyMonitor.verdictPublisher.map { _ in () }
          .eraseToAnyPublisher(),
      ] {
        publisher.sink { [weak self] in self?.schedulePublication() }.store(in: &subscriptions)
      }
    }

    private func schedulePublication() {
      guard !publicationScheduled else { return }
      publicationScheduled = true
      Task { @MainActor [weak self] in
        guard let self else { return }
        publicationScheduled = false
        do { try observe() } catch { Self.fail(error) }
      }
    }

    private func observe() throws {
      let state = withObservationTracking {
        snapshotState()
      } onChange: { [weak self] in
        Task { @MainActor in self?.schedulePublication() }
      }
      try write(state)
    }

    private func snapshotState() -> [String: Any] {
      ControlState.project(core, fixture: fixture).merging([
        "snapshotVersion": 1, "run": fixture.run, "pid": getpid(), "fixture": "v1",
        "seq": seq as Any? ?? NSNull(), "settledSeq": settledSeq as Any? ?? NSNull(),
        "windowNumber": windowNumber as Any? ?? NSNull(), "surface": options.surface.rawValue,
        "appearance": options.dark ? "dark" : "light",
      ]) { _, metadata in metadata }
    }

    private func write(_ state: [String: Any]) throws {
      revision += 1
      var snapshot = state
      snapshot["revision"] = revision
      let data = try JSONSerialization.data(
        withJSONObject: snapshot, options: [.sortedKeys, .prettyPrinted])
      try data.write(to: fixture.root.appending(path: "state.json"), options: .atomic)
    }

    private func publishDirectory() {
      FileHandle.standardOutput.write(Data((fixture.root.path + "\n").utf8))
    }

    static func fail(_ error: any Error) -> Never {
      FileHandle.standardError.write(Data("Photo Export control failed: \(error)\n".utf8))
      exit(74)
    }
  }

  struct ControlWindowReader: NSViewRepresentable {
    let runtime: ControlRuntime
    var publishesWindowNumber = true

    final class WindowView: NSView {
      weak var runtime: ControlRuntime?
      var publishesWindowNumber = true
      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        runtime?.attach(window, publishesWindowNumber: publishesWindowNumber)
      }
    }

    func makeNSView(context: Context) -> WindowView {
      let view = WindowView()
      view.runtime = runtime
      view.publishesWindowNumber = publishesWindowNumber
      return view
    }

    func updateNSView(_ view: WindowView, context: Context) {
      if let window = view.window, !window.frameAutosaveName.isEmpty {
        runtime.attach(window, publishesWindowNumber: publishesWindowNumber)
      }
    }
  }
#endif
