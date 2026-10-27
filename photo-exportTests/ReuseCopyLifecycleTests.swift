import Foundation
import Testing

@testable import Photo_Export

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct ReuseCopyLifecycleTests {
  private final class Observation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func record(_ value: Bool) { lock.withLock { self.value = value } }
    var observed: Bool { lock.withLock { value } }
  }

  private final class CopyGate: @unchecked Sendable {
    let started = AsyncCheckpoint()
    private let releaseSignal = DispatchSemaphore(value: 0)

    func hold() throws {
      Task { await started.enter() }
      // Teardown always signals; the bound only keeps a broken test from stranding the worker.
      guard releaseSignal.wait(timeout: .now() + 150) == .success else {
        throw NSError(domain: "CopyGateTimeout", code: 1)
      }
    }

    func release() { releaseSignal.signal() }
  }

  @MainActor
  private final class Fixture {
    let photos = FakePhotoLibraryService()
    let destination = FakeExportDestination()
    let writer = FakeAssetResourceWriter()
    let files = FakeFileSystem()
    let root = TestScratch.directory("ReuseCopyLifecycle")
    let timeline: ExportRecordStore
    let collections: CollectionExportRecordStore
    let manager: ExportManager
    let defaultsName = TestScratch.suiteName("ReuseCopyLifecycle")
    let defaults: UserDefaults
    let asset = TestAssetFactory.makeAsset(id: "shared", hasAdjustments: false)

    init(destinationIO: (any DestinationIOExecuting)? = nil) async throws {
      defaults = TestScratch.defaults(suiteName: defaultsName)
      timeline = ExportRecordStore(baseDirectoryURL: root)
      collections = CollectionExportRecordStore(baseDirectoryURL: root)
      await timeline.configureAndWait(for: "A")
      await collections.configureAndWait(for: "A")
      manager = ExportManager(
        photoLibraryService: photos, exportDestination: destination,
        exportRecordStore: timeline, collectionExportRecordStore: collections,
        assetResourceWriter: writer,
        localHEICStorage: LocalHEICStorage(root: TestScratch.directory("ExportHEIC")),
        fileSystem: files,
        destinationIOFactory: { _ in destinationIO ?? DestinationIO() }, userDefaults: defaults)
      photos.favoritesAssets = [asset]
      photos.resourcesByAssetId[asset.id] = [
        ResourceDescriptor(type: .photo, originalFilename: "IMG.JPG")
      ]
      let directory = try destination.urlForRelativeDirectory("2025/01/", createIfNeeded: true)
      try Data("source".utf8).write(to: directory.appendingPathComponent("IMG.JPG"))
      timeline.markVariantExported(
        assetId: asset.id, variant: .original, year: 2025, month: 1, relPath: "2025/01/",
        filename: "IMG.JPG", exportedAt: Date())
    }

    func cleanup() {
      manager.cancelAndClear()
      timeline.drainSynchronously()
      collections.drainSynchronously()
      destination.cleanup()
      try? FileManager.default.removeItem(at: root)
      defaults.removePersistentDomain(forName: defaultsName)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func mainActorRespondsBeforeBlockedReuseCopyFinishes() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanup() }
    let observation = Observation()
    let offMain = Observation()
    fixture.files.copyHook = { _, _ in
      offMain.record(!Thread.isMainThread)
      let heartbeat = DispatchSemaphore(value: 0)
      Task { @MainActor in heartbeat.signal() }
      // The bound only keeps old main-thread copies from deadlocking the runner; how
      // quickly a congested MainActor answers is not the oracle.
      observation.record(heartbeat.wait(timeout: .now() + 30) == .success)
    }
    fixture.manager.startExportFavorites()
    await fixture.manager.waitForQueueDrained()
    #expect(fixture.files.copyCalls.count == 1)
    #expect(offMain.observed, "The physical copy must not run on the main thread")
    #expect(observation.observed, "MainActor must respond while the physical copy is held")
    #expect(fixture.writer.writeCalls.isEmpty)
    #expect(
      fixture.collections.exportInfo(assetId: fixture.asset.id, placement: .favorites())?
        .variants[.original]?.status == .done)
  }

  @Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true])
  func cancelledCopyCannotCommitOrFallback(switchDestination: Bool, sourceError: Bool) async throws
  {
    let fixture = try await Fixture()
    let gate = CopyGate()
    try await withCleanup {
      fixture.files.copyHook = { _, output in
        try gate.hold()
        if sourceError {
          try Data("partial".utf8).write(to: output)
          throw CocoaError(.fileReadNoSuchFile)
        }
      }
      fixture.manager.startExportFavorites()
      await gate.started.waitForEnter(count: 1)
      let old = try #require(fixture.manager.currentTask)
      #expect(fixture.destination.closedScopeURLs.isEmpty)
      fixture.manager.progressState.renderActivity = .rendering
      if switchDestination {
        fixture.manager.interruptForDestinationUnavailable()
        fixture.destination.selectedFolderURL = fixture.destination.rootURL.appendingPathComponent(
          "B")
        await fixture.timeline.configureAndWait(for: "B")
        await fixture.collections.configureAndWait(for: "B")
        fixture.collections.upsertPlacement(.favorites())
        fixture.collections.markVariantExported(
          assetId: "B-only", placement: .favorites(), variant: .original,
          filename: "B.JPG", exportedAt: Date())
        _ = fixture.destination.beginScopedAccess()
      } else {
        fixture.manager.cancelAndClear()
      }
      #expect(
        fixture.manager.renderActivity == nil, "Owning teardown clears activity synchronously")
      #expect(fixture.destination.closedScopeURLs.isEmpty, "Physical IO still owns A's scope")
      gate.release()
      await old.value
      #expect(fixture.manager.renderActivity == nil)
      #expect(fixture.files.moveCalls.isEmpty)
      #expect(
        fixture.writer.writeCalls.isEmpty, "A stale source error must not fall back to Photos")
      #expect(fixture.destination.closedScopeURLs == [fixture.destination.rootURL])
      #expect(
        fixture.collections.exportInfo(assetId: fixture.asset.id, placement: .favorites()) == nil)
      if switchDestination {
        #expect(
          fixture.collections.exportInfo(assetId: "B-only", placement: .favorites())?.variants[
            .original]?.status == .done)
        let newScope = try #require(fixture.destination.selectedFolderURL)
        fixture.destination.endScopedAccess(for: newScope)
      }
      let directory = fixture.destination.rootURL.appendingPathComponent("Collections/Favorites/")
      #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    } cleanup: {
      gate.release()
      fixture.cleanup()
      await gate.started.releaseAll()
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func replacementWaitsForOldCopyAndKeepsItsOwnStage() async throws {
    let io = RecordingDestinationIO()
    let fixture = try await Fixture(destinationIO: io)
    let gate = CopyGate()
    let replacementWritten = AsyncCheckpoint()
    try await withCleanup {
      fixture.files.copyHook = { _, _ in try gate.hold() }
      fixture.manager.startExportFavorites()
      await gate.started.waitForEnter(count: 1)
      let old = try #require(fixture.manager.currentTask)
      fixture.manager.cancelAndClear()
      let variants =
        fixture.timeline.exportInfo(assetId: fixture.asset.id).map { Array($0.variants.keys) } ?? []
      for variant in variants {
        fixture.timeline.removeVariant(assetId: fixture.asset.id, variant: variant)
      }
      fixture.writer.afterWriteCheckpoint = replacementWritten
      let oldSubmissions = io.submissions.value
      fixture.manager.startExportFavorites()
      try #require(
        await eventually("replacement preparation admitted") {
          io.submissions.value > oldSubmissions
        })
      #expect(fixture.writer.writeCalls.isEmpty)
      gate.release()
      await replacementWritten.waitForEnter(count: 1)
      let replacement = try #require(fixture.manager.currentTask)
      let output = try #require(fixture.writer.writeCalls.last?.url)
      let expectedBytes = try Data(contentsOf: output)
      fixture.manager.progressState.renderActivity = .rendering
      await old.value
      #expect(try Data(contentsOf: output) == expectedBytes)
      #expect(fixture.manager.currentJobAssetId == fixture.asset.id)
      #expect(fixture.manager.currentJobVariant == .original)
      #expect(fixture.manager.currentAssetFilename == "IMG.JPG")
      #expect(fixture.manager.renderActivity == .rendering)
      #expect(
        fixture.collections.exportInfo(assetId: fixture.asset.id, placement: .favorites())?
          .variants[.original]?.status == .inProgress)
      await replacementWritten.releaseAll()
      await replacement.value
      let filename = try #require(
        fixture.collections.exportInfo(assetId: fixture.asset.id, placement: .favorites())?
          .variants[.original]?.filename)
      #expect(filename == "IMG.JPG")
      let final = try fixture.destination.urlForRelativeDirectory(
        "Collections/Favorites/", createIfNeeded: false
      ).appendingPathComponent(filename)
      #expect(try Data(contentsOf: final) == expectedBytes)
      #expect(
        fixture.collections.exportInfo(assetId: fixture.asset.id, placement: .favorites())?
          .variants[.original]?.status == .done)
      #expect(fixture.destination.beginScopedAccessCount == 2)
      #expect(fixture.destination.endScopedAccessCount == 2)
    } cleanup: {
      gate.release()
      fixture.cleanup()
      await gate.started.releaseAll()
      await replacementWritten.releaseAll()
    }
  }

  @Test func partialSourceCopyIsRemovedBeforePhotoKitFallback() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanup() }
    fixture.files.copyHook = { _, output in
      try Data("partial".utf8).write(to: output)
      throw CocoaError(.fileReadNoSuchFile)
    }
    fixture.manager.startExportFavorites()
    await fixture.manager.waitForQueueDrained()
    #expect(fixture.writer.writeCalls.count == 1)
    #expect(
      fixture.collections.exportInfo(assetId: fixture.asset.id, placement: .favorites())?.variants[
        .original]?.status == .done)
  }
}
