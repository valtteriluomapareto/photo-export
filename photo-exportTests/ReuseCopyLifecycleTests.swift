import Foundation
import Testing

@testable import Photo_Export

@MainActor
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
      guard releaseSignal.wait(timeout: .now() + 15) == .success else {
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
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let timeline: ExportRecordStore
    let collections: CollectionExportRecordStore
    let manager: ExportManager
    let defaultsName = "ReuseCopyLifecycle-\(UUID().uuidString)"
    let defaults: UserDefaults
    let asset = TestAssetFactory.makeAsset(id: "shared", hasAdjustments: false)

    init() throws {
      defaults = UserDefaults(suiteName: defaultsName)!
      timeline = ExportRecordStore(baseDirectoryURL: root)
      collections = CollectionExportRecordStore(baseDirectoryURL: root)
      timeline.configure(for: "A")
      collections.configure(for: "A")
      manager = ExportManager(
        photoLibraryService: photos, exportDestination: destination,
        exportRecordStore: timeline, collectionExportRecordStore: collections,
        assetResourceWriter: writer, fileSystem: files, userDefaults: defaults)
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
      timeline.flushForTesting()
      collections.flushForTesting()
      destination.cleanup()
      try? FileManager.default.removeItem(at: root)
      defaults.removePersistentDomain(forName: defaultsName)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func mainActorRespondsBeforeBlockedReuseCopyFinishes() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let observation = Observation()
    fixture.files.copyHook = { _, _ in
      let heartbeat = DispatchSemaphore(value: 0)
      Task { @MainActor in heartbeat.signal() }
      // Independent bounded release: old code blocks MainActor, then fails this
      // observation instead of deadlocking the test runner indefinitely.
      observation.record(heartbeat.wait(timeout: .now() + 2) == .success)
    }
    fixture.manager.startExportFavorites()
    await fixture.manager.waitForQueueDrained()
    #expect(fixture.files.copyCalls.count == 1)
    #expect(observation.observed, "MainActor must respond while the physical copy is held")
    #expect(fixture.writer.writeCalls.isEmpty)
    #expect(
      fixture.collections.exportInfo(assetId: fixture.asset.id, placement: .favorites())?
        .variants[.original]?.status == .done)
  }

  @Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true])
  func cancelledCopyCannotCommitOrFallback(switchDestination: Bool, sourceError: Bool) async throws
  {
    let fixture = try Fixture()
    let gate = CopyGate()
    defer {
      gate.release()
      Task { await gate.started.releaseAll() }
      fixture.cleanup()
    }
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
      fixture.timeline.configure(for: "B")
      fixture.collections.configure(for: "B")
      fixture.collections.upsertPlacement(.favorites())
      fixture.collections.markVariantExported(
        assetId: "B-only", placement: .favorites(), variant: .original,
        filename: "B.JPG", exportedAt: Date())
      _ = fixture.destination.beginScopedAccess()
    } else {
      fixture.manager.cancelAndClear()
    }
    #expect(fixture.manager.renderActivity == nil, "Owning teardown clears activity synchronously")
    #expect(fixture.destination.closedScopeURLs.isEmpty, "Physical IO still owns A's scope")
    gate.release()
    await old.value
    #expect(fixture.manager.renderActivity == nil)
    #expect(fixture.files.moveCalls.isEmpty)
    #expect(fixture.writer.writeCalls.isEmpty, "A stale source error must not fall back to Photos")
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
    let directory = try fixture.destination.urlForRelativeDirectory(
      "Collections/Favorites/", createIfNeeded: false)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
  }

  @Test(.timeLimit(.minutes(1)))
  func oldCopyCleanupCannotDamageSamePathReplacement() async throws {
    let fixture = try Fixture()
    let gate = CopyGate()
    let replacementWritten = AsyncCheckpoint()
    defer {
      gate.release()
      Task {
        await gate.started.releaseAll()
        await replacementWritten.releaseAll()
      }
      fixture.cleanup()
    }
    fixture.files.copyHook = { _, _ in try gate.hold() }
    fixture.manager.startExportFavorites()
    await gate.started.waitForEnter(count: 1)
    let old = try #require(fixture.manager.currentTask)
    fixture.manager.cancelAndClear()
    fixture.timeline.remove(assetId: fixture.asset.id)
    fixture.writer.afterWriteCheckpoint = replacementWritten
    fixture.manager.startExportFavorites()
    await replacementWritten.waitForEnter(count: 1)
    let replacement = try #require(fixture.manager.currentTask)
    let output = try #require(fixture.writer.writeCalls.last?.url)
    let expectedBytes = try Data(contentsOf: output)
    fixture.manager.progressState.renderActivity = .rendering
    gate.release()
    await old.value
    #expect(try Data(contentsOf: output) == expectedBytes)
    #expect(fixture.manager.currentJobAssetId == fixture.asset.id)
    #expect(fixture.manager.currentJobVariant == .original)
    #expect(fixture.manager.currentAssetFilename == "IMG.JPG")
    #expect(fixture.manager.renderActivity == .rendering)
    #expect(
      fixture.collections.exportInfo(assetId: fixture.asset.id, placement: .favorites())?.variants[
        .original]?.status == .inProgress)
    await replacementWritten.releaseAll()
    await replacement.value
    let final = output.deletingPathExtension()
    #expect(try Data(contentsOf: final) == expectedBytes)
    #expect(
      fixture.collections.exportInfo(assetId: fixture.asset.id, placement: .favorites())?.variants[
        .original]?.status == .done)
  }

  @Test func partialSourceCopyIsRemovedBeforePhotoKitFallback() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    fixture.files.copyHook = { _, output in
      try Data("partial".utf8).write(to: output)
      throw CocoaError(.fileReadNoSuchFile)
    }
    fixture.writer.requiresUnusedDestination = true
    fixture.manager.startExportFavorites()
    await fixture.manager.waitForQueueDrained()
    #expect(fixture.writer.writeCalls.count == 1)
    #expect(
      fixture.collections.exportInfo(assetId: fixture.asset.id, placement: .favorites())?.variants[
        .original]?.status == .done)
  }
}
