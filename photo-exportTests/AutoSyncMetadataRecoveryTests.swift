import Foundation
import Testing

@testable import Photo_Export

@MainActor
struct AutoSyncMetadataRecoveryTests {
  private func root() throws -> URL {
    let url = TestScratch.directory("MetadataRecovery")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func source(_ root: URL, name: String) throws -> URL {
    let directory = root.appendingPathComponent("A")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent(name)
  }

  @Test(arguments: ["dirtyState.json", "retryState.json"])
  func corruptReplacementPreservesExactOriginalBytes(name: String) throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try source(root, name: name)
    let original = Data("{\"truncated\":".utf8)
    try original.write(to: url)

    if name == "dirtyState.json" {
      let store = FileBackedAutoSyncDirtyStateStore(baseDirectoryURL: root)
      _ = try? store.load(destinationId: "A")
      try store.save(.empty, destinationId: "A")
    } else {
      let store = FileBackedAutoSyncRetryStateStore(baseDirectoryURL: root)
      _ = try? store.load(destinationId: "A")
      try store.save(.empty, destinationId: "A")
    }

    let siblings = try FileManager.default.contentsOfDirectory(
      at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
    #expect(siblings.contains { $0 != url && (try? Data(contentsOf: $0)) == original })
    #expect(try Data(contentsOf: url) != original)
  }

  private func environment(
    _ builder: FakeAutoSyncEnvironmentBuilder,
    dirty: any AutoSyncDirtyStateStore, retry: any AutoSyncRetryStateStore
  ) -> AutoSyncEnvironment {
    AutoSyncEnvironment(
      exportRunner: builder.exportRunner, destination: builder.destination,
      scopes: builder.scopes, photos: builder.photos, importing: builder.importing,
      dirtyStateStore: dirty, retryStateStore: retry,
      runSummaryStore: builder.runSummaryStore,
      perDestinationTokenStore: builder.perDestinationTokenStore,
      currentRunStore: builder.currentRunStore, clock: builder.clock,
      photosAuthorization: builder.photosAuthorization,
      userDefaults: builder.userDefaults)
  }

  @Test(arguments: [false, true])
  func onlyUncertainDirtyHistoryRequiresFullReconciliation(corrupt: Bool) throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try source(root, name: "dirtyState.json")
    if corrupt { try Data("broken".utf8).write(to: url) }
    let dirty = FileBackedAutoSyncDirtyStateStore(baseDirectoryURL: root)
    let builder = FakeAutoSyncEnvironmentBuilder()
    builder.userDefaults.set(true, forKey: AutoSyncManager.enabledDefaultsKey)
    builder.destination.subject.send(
      DestinationSnapshot(stableId: "A", fingerprint: nil, isAvailable: true, safety: .safe))
    builder.scopes.subject.send(AutoExportScopeSelection(timeline: true))
    let manager = AutoSyncManager()
    manager.attach(to: environment(builder, dirty: dirty, retry: builder.retryStore))
    defer { manager.setEnabled(false) }

    builder.photos.push(
      PhotoLibraryPersistentChangeEvent(
        insertedLocalIdentifiers: ["new"], observedAt: builder.clock.now()))

    let saved = try dirty.load(destinationId: "A")
    for scope in AutoExportLibraryScope.allCases {
      #expect(saved.scope(scope).pendingFullReconciliation == corrupt)
    }
  }

  private func save(_ root: URL, name: String, io: any AutoSyncMetadataFileIO) throws {
    if name == "dirtyState.json" {
      try FileBackedAutoSyncDirtyStateStore(baseDirectoryURL: root, io: io).save(
        .empty, destinationId: "A")
    } else {
      try FileBackedAutoSyncRetryStateStore(baseDirectoryURL: root, io: io).save(
        .empty, destinationId: "A")
    }
  }

  @Test(arguments: ["dirtyState.json", "retryState.json"])
  func unreadableSourceAndFailedPreservationCannotAuthorizeReplacement(name: String) throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try source(root, name: name)
    let bytes = Data("invalid original bytes".utf8)
    try bytes.write(to: url)
    let io = FailingMetadataIO()
    io.failRead = true
    if name == "dirtyState.json" {
      #expect(throws: InMemoryAutoSyncStoreError.self) {
        try FileBackedAutoSyncDirtyStateStore(baseDirectoryURL: root, io: io).load(
          destinationId: "A")
      }
    } else {
      #expect(throws: InMemoryAutoSyncStoreError.self) {
        try FileBackedAutoSyncRetryStateStore(baseDirectoryURL: root, io: io).load(
          destinationId: "A")
      }
    }
    #expect(throws: InMemoryAutoSyncStoreError.self) { try save(root, name: name, io: io) }
    #expect(try Data(contentsOf: url) == bytes)
    io.failRead = false
    io.failPreservation = true
    #expect(throws: InMemoryAutoSyncStoreError.self) { try save(root, name: name, io: io) }
    #expect(try Data(contentsOf: url) == bytes)
    io.failPreservation = false
    try save(root, name: name, io: io)
    #expect(try Data(contentsOf: url) != bytes)
  }

  @Test func failedRecoveryWriteLeavesCorruptionDiscoverableAfterRelaunch() throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try source(root, name: "dirtyState.json")
    let original = Data("broken".utf8)
    try original.write(to: url)
    let io = FailingMetadataIO()
    io.failWrite = true
    let first = FileBackedAutoSyncDirtyStateStore(baseDirectoryURL: root, io: io)
    #expect(throws: InMemoryAutoSyncStoreError.self) { try first.save(.empty, destinationId: "A") }
    #expect(try Data(contentsOf: url) == original)
    let restarted = FileBackedAutoSyncDirtyStateStore(baseDirectoryURL: root)
    #expect(throws: AutoSyncMetadataCorruption.self) { try restarted.load(destinationId: "A") }
    let siblings = try FileManager.default.contentsOfDirectory(
      at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
    #expect(siblings.contains { $0 != url && (try? Data(contentsOf: $0)) == original })
  }

  private func attach(
    _ builder: FakeAutoSyncEnvironmentBuilder, retry: any AutoSyncRetryStateStore,
    dirty: (any AutoSyncDirtyStateStore)? = nil
  ) -> AutoSyncManager {
    builder.userDefaults.set(true, forKey: AutoSyncManager.enabledDefaultsKey)
    builder.destination.subject.send(
      DestinationSnapshot(stableId: "A", fingerprint: nil, isAvailable: true, safety: .safe))
    builder.scopes.subject.send(AutoExportScopeSelection(timeline: true))
    let manager = AutoSyncManager()
    manager.attach(to: environment(builder, dirty: dirty ?? builder.dirtyStore, retry: retry))
    return manager
  }

  private func failure(
    _ manager: AutoSyncManager, builder: FakeAutoSyncEnvironmentBuilder, asset: String,
    destinationId: String = "A"
  ) {
    let context = ExportRunContext(
      source: .autoSync, visibility: .background, scope: .timelineFullLibrary, selection: .edited)
    manager.dispatch(.exportRunStarted(context, destinationId: destinationId))
    manager.dispatch(
      .autoSyncRunCompleted(
        ExportRunSummary(
          context: context, endedAt: builder.clock.now(), enqueuedCount: 1, completedCount: 0,
          failedCount: 1, skippedCount: 0, cancelReason: nil, result: .failed,
          failures: [
            ExportRunFailureDetail(
              assetId: asset, placement: .timeline(year: 2026, month: 10), variant: .original,
              category: .photoKitTransient, errorSignature: "same",
              localizedDescription: "Unavailable",
              failedAt: builder.clock.now())
          ]), destinationId: destinationId))
  }

  @Test(arguments: [false, true])
  func retryAccessRestorationPreservesSavedCountsNewFailuresAndUnknownKeys(switchDestination: Bool)
    throws
  {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let io = FailingMetadataIO()
    let retry = FileBackedAutoSyncRetryStateStore(baseDirectoryURL: root, io: io)
    let builder = FakeAutoSyncEnvironmentBuilder()
    let older = builder.clock.now().addingTimeInterval(-100)
    var old = AutoSyncRetryState.empty
    for _ in 0..<3 {
      old.recordFailure(
        scope: .timeline, assetId: "same", variant: .original, category: .photoKitTransient,
        errorSignature: "same", at: older, nextEligibleAt: older.addingTimeInterval(600))
    }
    old.entriesByPlacement["future:scope"] = [
      "future-asset": [
        "future-variant": old.entry(scope: .timeline, assetId: "same", variant: .original)!
      ]
    ]
    try retry.save(old, destinationId: "A")
    io.failRead = true
    let manager = attach(builder, retry: retry)
    defer { manager.setEnabled(false) }
    failure(manager, builder: builder, asset: "same")
    failure(manager, builder: builder, asset: "new")
    #expect(
      manager.currentRetryState.entry(scope: .timeline, assetId: "new", variant: .original) != nil)

    io.failRead = false
    if switchDestination {
      builder.destination.subject.send(
        DestinationSnapshot(stableId: "B", fingerprint: nil, isAvailable: true, safety: .safe))
      failure(manager, builder: builder, asset: "only-B", destinationId: "B")
      builder.destination.subject.send(
        DestinationSnapshot(stableId: "A", fingerprint: nil, isAvailable: true, safety: .safe))
      let savedB = try retry.load(destinationId: "B")
      #expect(savedB.entry(scope: .timeline, assetId: "only-B", variant: .original) != nil)
      #expect(savedB.entry(scope: .timeline, assetId: "same", variant: .original) == nil)
    } else {
      builder.destination.subject.send(
        DestinationSnapshot(stableId: "A", fingerprint: nil, isAvailable: false, safety: .safe))
      builder.destination.subject.send(
        DestinationSnapshot(stableId: "A", fingerprint: nil, isAvailable: true, safety: .safe))
    }
    let saved = try retry.load(destinationId: "A")
    #expect(saved.entry(scope: .timeline, assetId: "same", variant: .original)?.attemptCount == 3)
    #expect(
      saved.entry(scope: .timeline, assetId: "same", variant: .original)?.nextEligibleAt
        == builder.clock.now().addingTimeInterval(600))
    #expect(saved.entry(scope: .timeline, assetId: "new", variant: .original)?.attemptCount == 1)
    #expect(saved.entriesByPlacement["future:scope"] == old.entriesByPlacement["future:scope"])
    let fresh = FileBackedAutoSyncRetryStateStore(baseDirectoryURL: root)
    #expect(try fresh.load(destinationId: "A") == saved)
  }

  @Test func completionPrunesResolvedHistoryWithoutErasingItsNewFailures() throws {
    let builder = FakeAutoSyncEnvironmentBuilder()
    var old = AutoSyncRetryState.empty
    old.recordFailure(
      scope: .timeline, assetId: "resolved", variant: .original,
      category: .photoKitTransient, errorSignature: "same", at: builder.clock.now(),
      nextEligibleAt: nil)
    try builder.retryStore.save(old, destinationId: "A")
    let manager = attach(builder, retry: builder.retryStore)
    defer { manager.setEnabled(false) }
    builder.exportRunner.retryVariantDone = { _, asset, _ in asset == "resolved" }

    failure(manager, builder: builder, asset: "new")

    let saved = builder.retryStore.load(destinationId: "A")
    #expect(saved.entry(scope: .timeline, assetId: "resolved", variant: .original) == nil)
    #expect(saved.entry(scope: .timeline, assetId: "new", variant: .original) != nil)
    #expect(manager.currentRetryState == saved)
  }

  @Test func failedRetryCleanupKeepsPublishedEntriesUntilSaveSucceeds() {
    let builder = FakeAutoSyncEnvironmentBuilder()
    let manager = attach(builder, retry: builder.retryStore)
    defer { manager.setEnabled(false) }
    failure(manager, builder: builder, asset: "done")
    builder.exportRunner.retryVariantDone = { _, _, _ in true }
    builder.retryStore.nextSaveError = InMemoryAutoSyncStoreError("full")
    let manual = ExportRunState(activeContext: nil, isManualActive: true, isAutoSyncActive: false)
    builder.exportRunner.subject.send(manual)
    builder.exportRunner.subject.send(.idle)
    #expect(
      manager.currentRetryState.entry(scope: .timeline, assetId: "done", variant: .original) != nil)
    builder.exportRunner.subject.send(manual)
    builder.exportRunner.subject.send(.idle)
    #expect(manager.currentRetryState.isEmpty)
    builder.destination.subject.send(.none)
    builder.destination.subject.send(
      DestinationSnapshot(stableId: "A", fingerprint: nil, isAvailable: true, safety: .safe))
    #expect(manager.currentRetryState.isEmpty)
  }
}

/// Uses real temporary files while injecting privilege-independent IO failures.
private final class FailingMetadataIO: AutoSyncMetadataFileIO, @unchecked Sendable {
  var failRead = false
  var failPreservation = false
  var failWrite = false
  private let production = ProductionAutoSyncMetadataFileIO()

  func readIfPresent(at url: URL) throws -> Data? {
    if failRead { throw InMemoryAutoSyncStoreError("permission") }
    return try production.readIfPresent(at: url)
  }
  func preserve(_ data: Data, at url: URL) throws {
    if failPreservation { throw InMemoryAutoSyncStoreError("preserve") }
    try production.preserve(data, at: url)
  }
  func writeAtomically(_ data: Data, to url: URL) throws {
    if failWrite { throw InMemoryAutoSyncStoreError("write") }
    try production.writeAtomically(data, to: url)
  }
}
