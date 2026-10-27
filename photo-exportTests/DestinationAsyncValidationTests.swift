import AppKit
import Combine
import Foundation
import Testing

@testable import Photo_Export

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct DestinationAsyncValidationTests {
  private final class Probe: DestinationValidationProbing, @unchecked Sendable {
    let entered = AsyncCheckpoint()
    let calls = LockedBox<[Bool]>([])
    private let gate = DispatchSemaphore(value: 0)
    let heldPath: String
    init(heldPath: String) { self.heldPath = heldPath }
    func inspect(_ url: URL) -> DestinationValidationResult {
      calls.mutate { $0.append(pthread_main_np() == 0) }
      if url.lastPathComponent == heldPath {
        Task { await entered.enter() }
        gate.wait()
      }
      let fingerprint = DestinationFingerprint.makeLow(
        volumeRootPath: nil, relativePathFromVolumeRoot: url.path, standardizedPath: url.path)
      return DestinationValidationResult(
        isAvailable: true, isWritable: true, status: .ready, fingerprint: fingerprint)
    }
    func release() { gate.signal() }
  }

  @Test func newerRootClosesAdmissionAndSupersedesHeldValidation() async throws {
    let root = TestScratch.directory("AsyncValidation")
    let a = root.appendingPathComponent("A")
    let b = root.appendingPathComponent("B")
    try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
    let probe = Probe(heldPath: "A")
    let opened = LockedBox<[URL]>([])
    let closed = LockedBox<[URL]>([])
    let manager = ExportDestinationManager(
      skipRestore: true, userDefaults: TestScratch.defaults("AsyncValidation"),
      bookmarkSaver: { _ in true }, volumeNotificationCenter: NotificationCenter(),
      validationScopeAcquirer: { url in
        opened.mutate { $0.append(url) }
        return true
      },
      validationScopeReleaser: { url in closed.mutate { $0.append(url) } }, validationProbe: probe)
    defer {
      probe.release()
      manager.clearSelection()
    }
    var publishedPaths: [String] = []
    let sink = manager.identityPublisher.sink {
      if let path = $0.fingerprint?.standardizedPath { publishedPaths.append(path) }
    }
    defer { sink.cancel() }
    #expect(manager.applyFolderSelection(a, decision: .newDestination))
    try #require(await probe.entered.waitForEnter(count: 1))
    #expect(!manager.canExportNow)
    #expect(!manager.canImportNow)
    #expect(manager.applyFolderSelection(b, decision: .newDestination))
    #expect(manager.selectedFolderURL == b)
    #expect(manager.identity == .unavailable)
    #expect(!manager.canExportNow)
    probe.release()
    await manager.waitForValidation()
    #expect(manager.selectedFolderURL == b)
    #expect(manager.canExportNow)
    #expect(manager.identity.fingerprint?.standardizedPath == b.path)
    #expect(publishedPaths == [b.path])
    #expect(probe.calls.value == [true, true])
    #expect(opened.value.map(\.path).sorted() == closed.value.map(\.path).sorted())
  }

  /// Real selection/validation and directory access, with scratch paths requiring no sandbox grant.
  private final class ScratchDestination: ExportDestination {
    let manager: ExportDestinationManager
    init(_ manager: ExportDestinationManager) { self.manager = manager }
    var selectedFolderURL: URL? { manager.selectedFolderURL }
    var canExportNow: Bool { manager.canExportNow }
    var canImportNow: Bool { manager.canImportNow }
    func beginScopedAccess() -> URL? { selectedFolderURL }
    func endScopedAccess(for url: URL) {}
    func waitForValidation() async { await manager.waitForValidation() }
    func urlForRelativeDirectory(_ path: String, createIfNeeded: Bool) throws -> URL {
      try manager.urlForRelativeDirectory(path, createIfNeeded: createIfNeeded)
    }
    func urlForMonth(year: Int, month: Int, createIfNeeded: Bool) throws -> URL {
      try manager.urlForMonth(year: year, month: month, createIfNeeded: createIfNeeded)
    }
  }

  @Test(arguments: [false, true])
  func asyncFolderSelectionDuringExportPreservesOnlyTheSameDestination(differentFolder: Bool)
    async throws
  {
    let root = TestScratch.directory("SelectionDuringExport")
    let a = root.appendingPathComponent("A")
    let b = root.appendingPathComponent("B")
    for folder in [a, b] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    let destination = ExportDestinationManager(
      skipRestore: true, userDefaults: TestScratch.defaults("SelectionDuringExport"),
      bookmarkSaver: { _ in true }, volumeNotificationCenter: NotificationCenter(),
      validationScopeAcquirer: { _ in true }, validationScopeReleaser: { _ in },
      validationProbe: Probe(heldPath: "never"))
    #expect(destination.applyFolderSelection(a, decision: .newDestination))
    await destination.waitForValidation()
    let initialId = try #require(destination.destinationId)
    let storeRoot = TestScratch.directory("SelectionDuringExportHistory")
    let timeline = ExportRecordStore(baseDirectoryURL: storeRoot)
    let collections = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    let library = FakePhotoLibraryService()
    let asset = TestAssetFactory.makeAsset(id: "held", creationDate: makeDate(2025, 1, 1))
    library.yearCounts = [(2025, 1)]
    library.assetsByYearMonth["2025-1"] = [asset]
    library.resourcesByAssetId[asset.id] = [
      TestAssetFactory.makeResource(originalFilename: "held.JPG")
    ]
    let writer = FakeAssetResourceWriter()
    let gate = AsyncCheckpoint()
    writer.checkpoint = gate
    let manager = ExportManager(
      photoLibraryService: library, exportDestination: ScratchDestination(destination),
      exportRecordStore: timeline, collectionExportRecordStore: collections,
      assetResourceWriter: writer, fileSystem: FakeFileSystem(),
      userDefaults: TestScratch.defaults("SelectionDuringExportManager"))
    var configurations: [String?] = []
    let lifecycle = AppLifecycleCoordinator(
      cancelActiveWork: { manager.cancelAndClear() },
      interruptForDestinationUnavailable: { manager.interruptForDestinationUnavailable() },
      configureRecordStores: { id in
        configurations.append(id)
        timeline.configure(for: id)
        collections.configure(for: id)
        return .success
      })
    lifecycle.attach(
      initial: DestinationIdentitySnapshot(identity: destination.identity),
      identityPublisher: destination.identityPublisher)
    let context = ExportRunContext(
      source: .manual, visibility: .userVisible, scope: .timelineFullLibrary, selection: .edited)
    var completions: [ExportRunSummary] = []
    let subscription = manager.completedRunsPublisher.sink { completions.append($0) }
    let run = Task { await manager.runExport(context: context) }
    try await withCleanup {
      try #require(await gate.waitForEnter(count: 1))
      #expect(manager.activeRunContext == context)
      configurations.removeAll()
      let generation = manager.generation

      #expect(
        destination.applyFolderSelection(
          differentFolder ? b : a, decision: differentFolder ? .newDestination : .sameDestination))
      #expect(!destination.canExportNow)
      #expect(!destination.canImportNow)
      await destination.waitForValidation()

      if differentFolder {
        #expect(destination.destinationId != initialId)
        #expect(configurations == [destination.destinationId])
        #expect(manager.activeRunContext == nil)
      } else {
        #expect(destination.destinationId == initialId)
        #expect(configurations.isEmpty)
        #expect(manager.activeRunContext == context)
        #expect(manager.generation == generation)
        #expect(completions.isEmpty)
      }
      await gate.releaseAll()
      try #require(await finished(run))
      let summary = await run.value
      #expect(summary.context == context)
      #expect(summary.result == (differentFolder ? .cancelled : .completed))
      #expect(summary.cancelReason == (differentFolder ? .userCancelled : nil))
      #expect(summary.completedCount == (differentFolder ? 0 : 1))
    } cleanup: {
      subscription.cancel()
      await gate.releaseAll()
      let worker = manager.currentTask
      manager.cancelAndClear()
      _ = await finished(run)
      if let worker { _ = await finished(worker) }
      try? await timeline.flush()
      try? await collections.flush()
      destination.clearSelection()
    }
  }

  @Test func clearFromAvailabilitySubscriberCannotRestoreObsoleteResult() async throws {
    let root = TestScratch.directory("ReentrantValidation")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let probe = Probe(heldPath: "never")
    let closed = LockedBox(0)
    let manager = ExportDestinationManager(
      skipRestore: true, userDefaults: TestScratch.defaults("ReentrantValidation"),
      bookmarkSaver: { _ in true }, volumeNotificationCenter: NotificationCenter(),
      validationScopeAcquirer: { _ in true },
      validationScopeReleaser: { _ in closed.mutate { $0 += 1 } }, validationProbe: probe)
    var cleared = false
    let sink = manager.isAvailablePublisher.sink { available in
      guard available, !cleared else { return }
      cleared = true
      manager.clearSelection()
    }
    defer { sink.cancel() }
    #expect(manager.applyFolderSelection(root, decision: .newDestination))
    await manager.waitForValidation()
    #expect(cleared)
    #expect(manager.selectedFolderURL == nil)
    #expect(!manager.isAvailable)
    #expect(!manager.isWritable)
    #expect(manager.identity == .unavailable)
    #expect(manager.status == .noSelection)
    #expect(closed.value == 1)
  }
}
