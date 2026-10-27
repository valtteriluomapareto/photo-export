import AppKit
import Combine
import Foundation
import Testing

@testable import Photo_Export

private final class TrackingNotificationCenter: NotificationCenter, @unchecked Sendable {
  private(set) var removals = 0
  override func removeObserver(_ observer: Any) {
    removals += 1
    super.removeObserver(observer)
  }
}

@MainActor
struct VolumeNotificationTests {
  @Test func deinitRemovesBothTokensFromTheRegisteringCenter() {
    let center = TrackingNotificationCenter()
    let suite = TestScratch.suiteName("VolumeCleanup")
    let defaults = TestScratch.defaults(suiteName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    var manager: ExportDestinationManager? = ExportDestinationManager(
      skipRestore: true, userDefaults: defaults, volumeNotificationCenter: center)
    weak var weakManager = manager
    #expect(manager != nil)
    manager = nil
    #expect(weakManager == nil)
    #expect(center.removals == 2)
  }

  @Test func failedScopeAcquisitionDoesNotReleaseOrProbeTheDestination() async {
    let suite = TestScratch.suiteName("VolumeDenied")
    let defaults = TestScratch.defaults(suiteName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    var releases = 0
    var fingerprints = 0
    let manager = ExportDestinationManager(
      skipRestore: true, userDefaults: defaults,
      fingerprintProvider: { _ in
        fingerprints += 1
        return nil
      },
      volumeNotificationCenter: NotificationCenter(),
      validationScopeAcquirer: { _ in false },
      validationScopeReleaser: { _ in releases += 1 })
    manager.setSelectedFolderForTesting(URL(fileURLWithPath: "/unreachable-test-volume"))
    await manager.revalidateAndWait()
    #expect(!manager.isAvailable && !manager.isWritable)
    #expect(manager.destinationId == nil)
    #expect(releases == 0 && fingerprints == 0)
  }

  @Test func realMountNotificationsReconfigureStoresWithoutLosingStableDestinationRecords()
    async throws
  {
    let root = TestScratch.directory("VolumeNotification")
    let folder = root.appendingPathComponent("Volume")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = TestScratch.suiteName("VolumeLifecycle")
    let defaults = TestScratch.defaults(suiteName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let center = NotificationCenter()
    let completed = AsyncStream<Void>.makeStream()
    var validationIterator = completed.stream.makeAsyncIterator()
    var acquisitions = 0
    var releases = 0
    let manager = ExportDestinationManager(
      skipRestore: true, userDefaults: defaults,
      volumeNotificationCenter: center,
      validationScopeAcquirer: { _ in
        acquisitions += 1
        return true
      },
      validationScopeReleaser: { _ in
        releases += 1
        completed.continuation.yield(())
      })
    manager.setSelectedFolderForTesting(folder)
    await manager.revalidateAndWait()
    _ = await validationIterator.next()
    let stableId = try #require(manager.destinationId)
    let timeline = ExportRecordStore(baseDirectoryURL: root.appendingPathComponent("Records"))
    let collections = CollectionExportRecordStore(
      baseDirectoryURL: root.appendingPathComponent("Records"))
    defer {
      timeline.drainSynchronously()
      collections.drainSynchronously()
    }
    var configurations: [String?] = []
    var interruptions = 0
    let lifecycle = AppLifecycleCoordinator(
      cancelActiveWork: {}, interruptForDestinationUnavailable: { interruptions += 1 },
      configureRecordStores: { id in
        configurations.append(id)
        timeline.configure(for: id)
        collections.configure(for: id)
        return .success
      })
    lifecycle.attach(
      initial: DestinationIdentitySnapshot(identity: manager.identity),
      identityPublisher: manager.identityPublisher)
    timeline.markVariantExported(
      assetId: "kept", variant: .original, year: 2025, month: 1,
      relPath: "2025/01/", filename: "kept.jpg", exportedAt: Date())
    let placement = ExportPlacement.favorites()
    collections.upsertPlacement(placement)
    collections.markVariantExported(
      assetId: "kept", placement: placement, variant: .original,
      filename: "kept.jpg", exportedAt: Date())
    timeline.drainSynchronously()
    collections.drainSynchronously()
    let initialConfigurations = configurations.count
    center.post(name: NSWorkspace.didMountNotification, object: nil)
    _ = await validationIterator.next()
    #expect(configurations.count == initialConfigurations)
    try FileManager.default.removeItem(at: folder)
    center.post(name: NSWorkspace.didUnmountNotification, object: nil)
    _ = await validationIterator.next()
    #expect(!manager.isAvailable && !manager.isWritable)
    #expect(manager.destinationId == nil)
    #expect(lifecycle.lastConfiguredDestinationId == nil)
    #expect(interruptions == 1)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    center.post(name: NSWorkspace.didMountNotification, object: nil)
    _ = await validationIterator.next()
    #expect(manager.isAvailable && manager.isWritable)
    #expect(manager.destinationId == stableId)
    #expect(lifecycle.lastConfiguredDestinationId == stableId)
    #expect(configurations == [stableId, nil, stableId])
    #expect(timeline.exportInfo(assetId: "kept")?.variants[.original]?.status == .done)
    #expect(
      collections.exportInfo(assetId: "kept", placement: placement)?.variants[.original]?.status
        == .done)
    #expect(acquisitions == releases && releases == 4)
  }
}
