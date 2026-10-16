import AppKit
import Foundation
import Testing

@testable import Photo_Export

@MainActor
struct ScreenshotSessionTests {
  @Test func readinessRequiresContentWindowAndCompletedWork() {
    var state = ScreenshotReadinessState()
    let first = state.begin("thumbnail")
    state.windowID = 123
    #expect(!state.canLayout)
    state.contentReady = true
    #expect(!state.canLayout)
    state.finish(first)
    #expect(state.canLayout)
    let generation = state.generation
    let replacement = state.begin("thumbnail")
    state.finish(first)  // A late prior completion must not clear its replacement.
    #expect(!state.canLayout)
    #expect(state.generation != generation)
    state.finish(replacement)
    #expect(state.canLayout)
  }

  @Test func productionDoesNotCreateCaptureSession() throws {
    #expect(try ScreenshotSession.requested(arguments: ["app"]) == nil)
    #expect(
      try ScreenshotSession.requested(arguments: ["app", "--screenshot-surface=dev-empty"]) == nil)
  }

  @Test func bundledCatalogPreservesDefaultsAndRejectsUnknown() throws {
    let states = try ScreenshotSession.catalog()
    #expect(
      states.filter(\.isDefault).map(\.filename) == [
        "01-timeline", "02-timeline-multi-select", "03-collections-favorites",
        "04-collections-album-family", "05-collections-album-porvoo", "06-collections-folder-trips",
        "07-collections-multi-select", "08-collections-album-london",
        "09-collections-shared-album-family-stream",
      ])
    #expect(throws: (any Error).self) {
      try ScreenshotSession.requested(arguments: [
        "app", "--screenshot-mode", "--screenshot-surface=unknown",
      ])
    }
  }

  @Test func compositionUsesScratchDataAndLeavesExistingPreferencesAndRecordsAlone() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let existing = root.appendingPathComponent("existing-records.json")
    let bytes = Data("existing export state".utf8)
    try bytes.write(to: existing)
    let sentinel = "NSSplitView Subview Frames CaptureTest-\(UUID().uuidString)"
    UserDefaults.standard.set("preserve this divider", forKey: sentinel)
    defer { UserDefaults.standard.removeObject(forKey: sentinel) }
    let onboardingBefore =
      UserDefaults.standard.object(forKey: "hasCompletedOnboarding") as? NSObject
    let state = try #require(ScreenshotSession.catalog().first { $0.key == "dev-paused" })
    let session = try ScreenshotSession(id: UUID(), state: state, parent: root)
    defer { UserDefaults.standard.removePersistentDomain(forName: session.defaultsName) }
    let services = session.makeServices()
    #expect(services.timeline.storeRootURL.path.hasPrefix(session.root.path + "/"))
    #expect(services.collections.storeRootURL == services.timeline.storeRootURL)
    #expect(services.destination.selectedFolderURL?.path.hasPrefix(session.root.path + "/") == true)
    #expect(services.export.isPaused)
    #expect(!services.export.isRunning)
    #expect(services.export.queueCount == 7)
    #expect(services.export.totalJobsCompleted == 3)
    #expect(services.export.totalJobsEnqueued == 10)
    #expect(try Data(contentsOf: existing) == bytes)
    #expect(UserDefaults.standard.string(forKey: sentinel) == "preserve this divider")
    #expect(
      (UserDefaults.standard.object(forKey: "hasCompletedOnboarding") as? NSObject)
        == onboardingBefore)
    #expect(session.defaults.bool(forKey: "hasCompletedOnboarding"))
  }

  @Test func emptyFixtureIsConsistentlyEmpty() async throws {
    let service = ScreenshotPhotoLibraryService(empty: true)
    #expect(try service.availableYears().isEmpty)
    #expect(try service.fetchCollectionTree().isEmpty)
    #expect(try await service.fetchAssets(year: 2026, month: 10).isEmpty)
    #expect(try await service.fetchAssets(in: .favorites, mediaType: nil).isEmpty)
    #expect(try await service.countAssets(in: .favorites) == 0)
    #expect(try service.countAssets(year: 2026) == 0)
    #expect(service.fetchAssetDescriptor(for: "family-0") == nil)
    #expect(service.resources(for: "family-0").isEmpty)
    #expect(service.assetDetails(for: "family-0") == nil)
    #expect(await service.loadThumbnail(for: "family-0") == nil)
    await #expect(throws: (any Error).self) { try await service.requestFullImage(for: "family-0") }
  }

  @Test func captureProducersRefuseAllProductionWork() async {
    let producers = ScreenshotExportProducers()
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    await #expect(throws: (any Error).self) {
      try await producers.writeResource(
        ResourceDescriptor(type: .photo, originalFilename: "x.heic", fileSize: 1),
        forAssetId: "personal", to: url)
    }
    await #expect(throws: (any Error).self) {
      try await producers.convertHEIC(at: url, to: url, quality: 0.85)
    }
    await #expect(throws: (any Error).self) {
      try await producers.render(
        request: MediaRenderRequest(
          assetId: "personal", originalFilename: "x.mov", fileType: .mov, kind: .video), to: url)
    }
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }
}

@MainActor
struct ScreenshotPublicationTests {
  @Test func failedInvalidationRemovesPreviouslyReadyEvidence() throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: parent) }
    var failWrites = false
    let state = try #require(ScreenshotSession.catalog().first)
    var failureCount = 0
    let session = try ScreenshotSession(
      id: UUID(), state: state, parent: parent,
      writeReport: { data, url in
        if failWrites { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: .atomic)
      }, publicationFailure: { _ in failureCount += 1 })
    defer { UserDefaults.standard.removePersistentDomain(forName: session.defaultsName) }
    let report = session.root.appendingPathComponent("readiness.json")
    try Data("{\"status\":\"ready\"}".utf8).write(to: report)
    failWrites = true
    _ = session.beginWork("new image")
    #expect(failureCount == 1)
    #expect(
      !FileManager.default.fileExists(atPath: report.path),
      "failed invalidation must remove stale ready evidence")
  }

  @Test func captureDestinationIgnoresHostVolumeNotifications() async throws {
    let center = NotificationCenter()
    let defaultsName = "capture-volume-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: defaultsName))
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let destination = ExportDestinationManager(
      skipRestore: true, observeVolumeChanges: false, volumeNotificationCenter: center,
      userDefaults: defaults)
    destination.configureForScreenshotMode()
    center.post(name: NSWorkspace.didMountNotification, object: nil)
    center.post(name: NSWorkspace.didUnmountNotification, object: nil)
    // Drain the notification callbacks' existing main-actor tasks, no real mount is performed.
    for _ in 0..<10 { await Task.yield() }
    #expect(destination.isAvailable)
    #expect(destination.isWritable)
  }
}
