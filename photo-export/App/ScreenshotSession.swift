import AppKit
import QuartzCore
import SwiftUI
import os

struct ScreenshotState: Decodable {
  let key: String
  let filename: String
  let kind: String
  let isDefault: Bool
  enum CodingKeys: String, CodingKey {
    case key, filename, kind
    case isDefault = "default"
  }
}

/// Main-actor, capture-only composition and readiness. Ordinary launches create no session.
@MainActor
final class ScreenshotSession {
  struct Services {
    let destination: ExportDestinationManager
    let library: PhotoLibraryManager
    let timeline: ExportRecordStore
    let collections: CollectionExportRecordStore
    let export: ExportManager
  }

  let id: UUID
  let state: ScreenshotState
  let root: URL
  let defaults: UserDefaults
  let defaultsName: String
  private var readiness = ScreenshotReadinessState()
  private weak var window: NSWindow?
  private let writeReport: (Data, URL) throws -> Void
  private let publicationFailure: (Error) -> Void
  private var publicationFailed = false

  static func catalog() throws -> [ScreenshotState] {
    guard let url = Bundle.main.url(forResource: "screenshot-states", withExtension: "json") else {
      throw CaptureError.invalidConfiguration
    }
    return try JSONDecoder().decode([ScreenshotState].self, from: Data(contentsOf: url))
  }

  static func requested(arguments: [String] = ProcessInfo.processInfo.arguments) throws
    -> ScreenshotSession?
  {
    guard arguments.contains("--screenshot-mode") else { return nil }
    func value(_ prefix: String) -> String? {
      arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }
    let key = value("--screenshot-surface=") ?? "timeline"
    guard let state = try catalog().first(where: { $0.key == key }) else {
      throw CaptureError.invalidConfiguration
    }
    let id: UUID
    if let raw = value("--screenshot-session=") {
      guard let parsed = UUID(uuidString: raw) else { throw CaptureError.invalidConfiguration }
      id = parsed
    } else {
      id = UUID()
    }
    return try ScreenshotSession(id: id, state: state)
  }

  init(
    id: UUID, state: ScreenshotState, parent: URL = URL(fileURLWithPath: "/tmp"),
    writeReport: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) },
    publicationFailure: @escaping (Error) -> Void = { _ in exit(3) }
  ) throws {
    self.writeReport = writeReport
    self.publicationFailure = publicationFailure
    self.id = id
    self.state = state
    root = parent.appendingPathComponent("photo-export-capture-\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defaultsName = "com.valtteriluoma.photo-export.capture.\(id.uuidString)"
    guard let defaults = UserDefaults(suiteName: defaultsName) else {
      throw CaptureError.invalidConfiguration
    }
    self.defaults = defaults
    defaults.set(state.key != "dev-onboarding", forKey: "hasCompletedOnboarding")
    publish(status: "loading")
  }

  func makeServices() -> Services {
    let destination = ExportDestinationManager(
      skipRestore: true, observeVolumeChanges: false, userDefaults: defaults)
    if state.key != "dev-onboarding" {
      destination.configureForScreenshotMode(
        folderURL: root.appendingPathComponent("Backup Folder"),
        available: state.key != "dev-destination-unavailable")
    }
    let library = PhotoLibraryManager(
      overrideService: ScreenshotPhotoLibraryService(empty: state.key == "dev-empty"))
    let records = root.appendingPathComponent("ExportRecords")
    let timeline = ExportRecordStore(baseDirectoryURL: records)
    let collections = CollectionExportRecordStore(baseDirectoryURL: records)
    let producers = ScreenshotExportProducers()
    let export = ExportManager(
      photoLibraryService: library, exportDestination: destination, exportRecordStore: timeline,
      collectionExportRecordStore: collections, assetResourceWriter: producers,
      mediaRenderer: producers, imageConverter: producers, phAssetCacheControl: library,
      userDefaults: defaults)
    if state.key == "dev-paused" {
      let calendar = Calendar(identifier: .gregorian)
      let now = Date()
      let placement = ExportPlacement.timeline(
        year: calendar.component(.year, from: now), month: calendar.component(.month, from: now))
      export.queueCoordinator.pause()
      export.queueCoordinator.enqueue(
        (0..<7).map {
          ExportManager.ExportJob(
            assetLocalIdentifier: "capture-job-\($0)", placement: placement, selection: .edited)
        })
      export.progressState.totalJobsEnqueued = 10
      export.progressState.totalJobsCompleted = 3
      export.progressState.currentAssetFilename = "IMG_2048.HEIC"
    }
    return Services(
      destination: destination, library: library, timeline: timeline, collections: collections,
      export: export)
  }

  func beginWork(_ label: String) -> UUID {
    let token = readiness.begin(label)
    publish(status: "loading")
    return token
  }

  func finishWork(_ token: UUID?) {
    guard let token else { return }
    readiness.finish(token)
    settle()
  }

  func contentLoaded() {
    readiness.contentReady = true
    readiness.invalidateLayout()
    settle()
  }

  func attach(window: NSWindow) {
    self.window = window
    window.isRestorable = false
    window.setFrameAutosaveName("")
    disableSplitAutosave(in: window.contentView)
    let args = ProcessInfo.processInfo.arguments
    func dimension(_ prefix: String) -> CGFloat? {
      guard let raw = args.first(where: { $0.hasPrefix(prefix) }),
        let number = Double(raw.dropFirst(prefix.count)), number.isFinite, number > 0
      else { return nil }
      return CGFloat(number)
    }
    if let width = dimension("--screenshot-width="), let height = dimension("--screenshot-height=")
    {
      let frame = window.screen?.visibleFrame ?? window.frame
      let target = NSRect(
        x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height)
      if window.frame.size != target.size { window.setFrame(target, display: true) }
    }
    readiness.windowID = window.windowNumber
    layoutChanged()
  }

  func layoutChanged() {
    readiness.invalidateLayout()
    settle()
  }

  private func settle() {
    publish(status: "loading")
    guard readiness.canLayout else { return }
    let generation = readiness.generation
    Task { @MainActor [weak self] in
      await Task.yield()
      guard let self, self.readiness.generation == generation, let window = self.window else {
        return
      }
      self.disableSplitAutosave(in: window.contentView)
      window.contentView?.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      CATransaction.flush()
      await Task.yield()
      guard self.readiness.generation == generation, self.readiness.canLayout, window.isVisible
      else { return }
      self.publish(status: "ready")
    }
  }

  private func disableSplitAutosave(in view: NSView?) {
    if let split = view as? NSSplitView { split.autosaveName = nil }
    for child in view?.subviews ?? [] { disableSplitAutosave(in: child) }
  }

  private func publish(status: String) {
    guard !publicationFailed else { return }
    let report: [String: Any] = [
      "session": id.uuidString, "state": state.key,
      "pid": ProcessInfo.processInfo.processIdentifier,
      "windowID": readiness.windowID ?? 0, "status": status, "generation": readiness.generation,
      "contentReady": readiness.contentReady, "pending": readiness.pending.values.sorted(),
    ]
    do {
      try writeReport(
        JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
        root.appendingPathComponent("readiness.json"))
    } catch {
      publicationFailed = true
      try? FileManager.default.removeItem(at: root.appendingPathComponent("readiness.json"))
      // Fail-stop even if removal fails: an old ready report must never authorize capture.
      Logger(subsystem: "com.valtteriluoma.photo-export", category: "Screenshot").error(
        "Readiness write failed: \(error.localizedDescription)")
      publicationFailure(error)
    }
  }

  enum CaptureError: Error { case invalidConfiguration, disabledProducer }
}

/// Refusing seams ensure a synthetic identifier can never reach PhotoKit or conversion IO.
struct ScreenshotExportProducers: AssetResourceWriter, MediaRenderer, ImageConverter {
  func writeResource(_ resource: ResourceDescriptor, forAssetId assetId: String, to url: URL)
    async throws
  {
    throw ScreenshotSession.CaptureError.disabledProducer
  }
  func render(request: MediaRenderRequest, to url: URL) async throws {
    throw ScreenshotSession.CaptureError.disabledProducer
  }
  func convertHEIC(at sourceURL: URL, to destURL: URL, quality: Double) async throws {
    throw ScreenshotSession.CaptureError.disabledProducer
  }
}

private struct ScreenshotSessionKey: EnvironmentKey {
  static let defaultValue: ScreenshotSession? = nil
}

extension EnvironmentValues {
  var screenshotSession: ScreenshotSession? {
    get { self[ScreenshotSessionKey.self] }
    set { self[ScreenshotSessionKey.self] = newValue }
  }
}

struct ScreenshotWindowReporter: NSViewRepresentable {
  let session: ScreenshotSession
  func makeNSView(context: Context) -> CaptureWindowView { CaptureWindowView(session: session) }
  func updateNSView(_ nsView: CaptureWindowView, context: Context) { session.layoutChanged() }

  final class CaptureWindowView: NSView {
    let session: ScreenshotSession
    init(session: ScreenshotSession) {
      self.session = session
      super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let window { session.attach(window: window) }
    }
    override func resizeSubviews(withOldSize oldSize: NSSize) {
      super.resizeSubviews(withOldSize: oldSize)
      session.layoutChanged()
    }
  }
}
