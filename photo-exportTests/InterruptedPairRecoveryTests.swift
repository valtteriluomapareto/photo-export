import Foundation
import Testing

@testable import Photo_Export

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct InterruptedPairRecoveryTests {
  private final class Gate: @unchecked Sendable {
    let entered = AsyncCheckpoint()
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var used = false

    func holdOnce() {
      guard
        lock.withLock({
          if used { return false }
          used = true
          return true
        })
      else { return }
      Task { await entered.enter() }
      // Teardown always releases; the bound only keeps a broken test from stranding the worker.
      if semaphore.wait(timeout: .now() + 150) != .success {
        Issue.record("Interrupted recovery gate timed out")
      }
    }

    func release() { semaphore.signal() }
  }

  @MainActor
  private final class Destination: ExportDestination {
    let base = TestScratch.directory("InterruptedPairRecovery")
    var rootURL: URL { base.appendingPathComponent("A") }
    var selectedFolderURL: URL?
    var canExportNow: Bool { true }
    var canImportNow: Bool { true }
    var opened: [URL] = []
    var closed: [URL] = []

    init() { selectedFolderURL = rootURL }
    func beginScopedAccess() -> URL? {
      if let selectedFolderURL { opened.append(selectedFolderURL) }
      return selectedFolderURL
    }
    func endScopedAccess(for url: URL) { closed.append(url) }
    func urlForRelativeDirectory(_ path: String, createIfNeeded: Bool) throws -> URL {
      let url = try #require(selectedFolderURL).appendingPathComponent(path)
      if createIfNeeded {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      }
      return url
    }
    func urlForMonth(year: Int, month: Int, createIfNeeded: Bool) throws -> URL {
      try urlForRelativeDirectory(
        "\(year)/\(String(format: "%02d", month))/", createIfNeeded: createIfNeeded)
    }
    func cleanup() { try? FileManager.default.removeItem(at: base) }
  }

  enum Mismatch: CaseIterable {
    case ordinaryFailure, filename, path, subfolder, empty, size, directory, symlink
  }

  @MainActor
  private final class Fixture {
    let root: URL
    let destination: Destination
    let timeline: ExportRecordStore
    let collections: CollectionExportRecordStore
    let writer = FakeAssetResourceWriter()
    let files = FakeFileSystem()
    let photos = FakePhotoLibraryService()
    let placement: ExportPlacement
    let variant: ExportVariant
    let filename: String
    let manager: ExportManager
    let defaultsName: String
    var physicalTasks: [Task<Void, Never>] = []

    init(
      root: URL, destination: Destination, collection: Bool, companion: Bool,
      destinationIO: (any DestinationIOExecuting)? = nil
    ) async {
      self.root = root
      self.destination = destination
      placement = collection ? .favorites() : .timeline(year: 2025, month: 1)
      variant = companion ? .original : .originalPairedVideo
      filename = companion ? "FILE_orig.JPG" : "FILE.MOV"
      timeline = ExportRecordStore(baseDirectoryURL: root)
      collections = CollectionExportRecordStore(baseDirectoryURL: root)
      await timeline.configureAndWait(for: "A")
      await collections.configureAndWait(for: "A")
      defaultsName = TestScratch.suiteName("InterruptedPair")
      manager = ExportManager(
        photoLibraryService: photos, exportDestination: destination,
        exportRecordStore: timeline, collectionExportRecordStore: collections,
        assetResourceWriter: writer,
        localHEICStorage: LocalHEICStorage(root: TestScratch.directory("ExportHEIC")),
        fileSystem: files,
        destinationIO: destinationIO ?? DestinationIO(),
        userDefaults: TestScratch.defaults(suiteName: defaultsName))
      let asset = TestAssetFactory.makeAsset(
        id: "asset",
        creationDate: Calendar.current.date(from: DateComponents(year: 2025, month: 1, day: 15))!,
        hasAdjustments: companion, isLivePhoto: !companion)
      photos.assetsByYearMonth["2025-1"] = [asset]
      photos.resourcesByAssetId[asset.id] = [
        .init(type: .photo, originalFilename: "FILE.JPG", fileSize: companion ? 12 : nil),
        .init(type: .pairedVideo, originalFilename: "FILE.MOV", fileSize: 12),
        .init(type: .fullSizePhoto, originalFilename: "EDIT.JPG"),
      ]
    }

    var finalURL: URL {
      destination.rootURL.appendingPathComponent(placement.relativePath)
        .appendingPathComponent(filename)
    }

    func start() {
      manager.queueCoordinator.enqueue([
        .init(
          assetLocalIdentifier: "asset", placement: placement,
          selection: .editedWithOriginals, livePhotosPaired: true)
      ])
      manager.processQueueIfNeeded()
      if let task = manager.currentTask { physicalTasks.append(task) }
    }

    func variants() -> [ExportVariant: ExportVariantRecord] {
      if placement.kind == .favorites {
        return collections.exportInfo(assetId: "asset", placement: placement)?.variants ?? [:]
      }
      return timeline.exportInfo(assetId: "asset")?.variants ?? [:]
    }

    func select(_ id: String) async {
      destination.selectedFolderURL = destination.base.appendingPathComponent(id)
      timeline.beginConfigure(for: id)
      collections.beginConfigure(for: id)
      await timeline.waitUntilSettled()
      await collections.waitUntilSettled()
      if placement.kind == .favorites {
        try? await collections.withMutationAdmission { collections.upsertPlacement(placement) }
      }
    }

    func reloadVariants() async throws -> [ExportVariant: ExportVariantRecord] {
      try await timeline.checkpointHistory()
      try await collections.checkpointHistory()
      try await timeline.flush()
      try await collections.flush()
      if placement.kind == .favorites {
        let fresh = CollectionExportRecordStore(baseDirectoryURL: root)
        await fresh.configureAndWait(for: "A")
        return fresh.exportInfo(assetId: "asset", placement: placement)?.variants ?? [:]
      }
      let fresh = ExportRecordStore(baseDirectoryURL: root)
      await fresh.configureAndWait(for: "A")
      return fresh.exportInfo(assetId: "asset")?.variants ?? [:]
    }

    func cleanup() async {
      manager.cancelAndClear()
      for task in physicalTasks { await task.value }
      try? await timeline.checkpointHistory()
      try? await collections.checkpointHistory()
      try? await timeline.flush()
      try? await collections.flush()
      destination.cleanup()
      try? FileManager.default.removeItem(at: root)
    }
  }

  private func makeFixture(
    collection: Bool, companion: Bool = false, mismatch: Mismatch? = nil,
    destinationIO: (any DestinationIOExecuting)? = nil
  ) async throws -> Fixture {
    let root = TestScratch.directory("InterruptedPairRecovery")
    let destination = Destination()
    let placement: ExportPlacement = collection ? .favorites() : .timeline(year: 2025, month: 1)
    let variant: ExportVariant = companion ? .original : .originalPairedVideo
    let filename = companion ? "FILE_orig.JPG" : "FILE.MOV"
    let anchor: ExportVariant = companion ? .edited : .original
    let anchorFilename = "FILE.JPG"
    let timeline = ExportRecordStore(baseDirectoryURL: root)
    let collections = CollectionExportRecordStore(baseDirectoryURL: root)
    await timeline.configureAndWait(for: "A")
    await collections.configureAndWait(for: "A")
    let recordedFilename = mismatch == .filename ? "OTHER.MOV" : filename
    let subfolder = mismatch == .subfolder ? "videos" : nil
    if collection {
      let stored = ExportPlacement(
        kind: placement.kind, id: placement.id, displayName: placement.displayName,
        collectionLocalIdentifier: nil,
        relativePath: mismatch == .path ? "Collections/Old/" : placement.relativePath,
        createdAt: placement.createdAt)
      collections.upsertPlacement(stored)
      collections.markVariantExported(
        assetId: "asset", placement: stored, variant: anchor,
        filename: anchorFilename, exportedAt: Date())
      collections.markVariantInProgress(
        assetId: "asset", placement: stored, variant: variant,
        filename: recordedFilename, subfolder: subfolder)
      if mismatch == .ordinaryFailure {
        collections.markVariantFailed(
          assetId: "asset", placement: stored, variant: variant, error: "Other failure", at: Date())
      }
    } else {
      let year = mismatch == .path ? 2024 : 2025
      let path = mismatch == .path ? "2024/01/" : placement.relativePath
      timeline.markVariantExported(
        assetId: "asset", variant: anchor, year: year, month: 1,
        relPath: path, filename: anchorFilename, exportedAt: Date())
      timeline.markVariantInProgress(
        assetId: "asset", variant: variant, year: year, month: 1,
        relPath: path, filename: recordedFilename, subfolder: subfolder)
      if mismatch == .ordinaryFailure {
        timeline.markVariantFailed(
          assetId: "asset", variant: variant, error: "Other failure", at: Date())
      }
    }
    try await timeline.flush()
    try await collections.flush()
    let directory = try destination.urlForRelativeDirectory(
      placement.relativePath, createIfNeeded: true)
    try Data("still-bytes".utf8).write(to: directory.appendingPathComponent(anchorFilename))
    let candidate = directory.appendingPathComponent(filename)
    switch mismatch {
    case .directory:
      try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
    case .symlink:
      try FileManager.default.createSymbolicLink(
        at: candidate, withDestinationURL: directory.appendingPathComponent(anchorFilename))
    default:
      let bytes = mismatch == .empty ? Data() : Data("paired-bytes".utf8)
      try bytes.write(to: candidate)
    }
    let fixture = await Fixture(
      root: root, destination: destination, collection: collection, companion: companion,
      destinationIO: destinationIO)
    if mismatch == .size {
      fixture.photos.resourcesByAssetId["asset"] = [
        .init(type: .photo, originalFilename: "FILE.JPG"),
        .init(type: .pairedVideo, originalFilename: "FILE.MOV", fileSize: 100),
      ]
    }
    return fixture
  }

  @Test(arguments: [false, true], [false, true])
  func interruptedPairSurvivesFreshStoreReload(collection: Bool, companion: Bool) async throws {
    let fixture = try await makeFixture(collection: collection, companion: companion)
    #expect(fixture.variants()[fixture.variant]?.reason == .interrupted)
    let before = try Data(contentsOf: fixture.finalURL)
    fixture.start()
    await fixture.manager.waitForQueueDrained()
    let variants = try await fixture.reloadVariants()
    #expect(variants[fixture.variant]?.status == .done)
    #expect(variants[fixture.variant]?.filename == fixture.filename)
    #expect(variants[fixture.variant]?.subfolder == nil)
    #expect(try Data(contentsOf: fixture.finalURL) == before)
    #expect(fixture.writer.writeCalls.isEmpty)
    #expect(fixture.files.moveCalls.isEmpty)
    #expect(fixture.files.copyCalls.isEmpty)
    #expect(fixture.files.timestampCalls.map(\.url) == [fixture.finalURL])
    #expect(
      try FileManager.default.contentsOfDirectory(
        atPath: fixture.finalURL.deletingLastPathComponent().path
      ).sorted()
        == ["FILE.JPG", fixture.filename].sorted())
    await fixture.cleanup()
  }

  @Test(arguments: [false, true], [false, true])
  func interruptedAdoptionRefusesClaimCreatedDuringPreparation(
    collection: Bool, companion: Bool
  ) async throws {
    let gate = Gate()
    // Directory resolution and interrupted-file verification precede slot preparation.
    let io = RecordingDestinationIO(beforeLeaf: { if $0 == 3 { gate.holdOnce() } })
    let fixture = try await makeFixture(
      collection: collection, companion: companion, destinationIO: io)
    let before = try Data(contentsOf: fixture.finalURL)
    try await withCleanup {
      fixture.start()
      try #require(await gate.entered.waitForEnter(count: 1))
      if collection {
        fixture.collections.markVariantExported(
          assetId: "other", placement: fixture.placement, variant: fixture.variant,
          filename: fixture.filename, exportedAt: Date())
      } else {
        fixture.timeline.markVariantExported(
          assetId: "other", variant: fixture.variant, year: 2025, month: 1,
          relPath: fixture.placement.relativePath, filename: fixture.filename, exportedAt: Date())
      }
      gate.release()
      await fixture.manager.waitForQueueDrained()
      #expect(fixture.variants()[fixture.variant]?.status == .failed)
      #expect(try Data(contentsOf: fixture.finalURL) == before)
      #expect(fixture.writer.writeCalls.isEmpty)
      #expect(fixture.files.moveCalls.isEmpty)
      #expect(fixture.files.copyCalls.isEmpty)
      #expect(fixture.files.timestampCalls.isEmpty)
      let foreign =
        collection
        ? fixture.collections.exportInfo(assetId: "other", placement: fixture.placement)?.variants[
          fixture.variant]
        : fixture.timeline.exportInfo(assetId: "other")?.variants[fixture.variant]
      #expect(foreign?.status == .done)
      #expect(foreign?.filename == fixture.filename)
      #expect(fixture.destination.opened == fixture.destination.closed)
    } cleanup: {
      gate.release()
      await fixture.cleanup()
      await gate.entered.releaseAll()
    }
  }

  @Test(arguments: [false, true], [false, true])
  func interruptedAdoptionRechecksClaimsAfterMaintenanceAdmission(
    collection: Bool, companion: Bool
  ) async throws {
    let gate = Gate()
    let maintenance = AsyncCheckpoint()
    let io = RecordingDestinationIO(beforeLeaf: { if $0 == 3 { gate.holdOnce() } })
    let fixture = try await makeFixture(
      collection: collection, companion: companion, destinationIO: io)
    let before = try Data(contentsOf: fixture.finalURL)
    let admission =
      collection
      ? fixture.collections.mutationAdmission : fixture.timeline.mutationAdmission
    var operation: Task<Void, Never>?
    try await withCleanup {
      fixture.start()
      try #require(await gate.entered.waitForEnter(count: 1))
      operation = admission.requestCheckpoint {
        await maintenance.enter()
        admission.installAfterMaintenance {
          if collection {
            fixture.collections.markVariantExported(
              assetId: "other", placement: fixture.placement, variant: fixture.variant,
              filename: fixture.filename, exportedAt: Date())
          } else {
            fixture.timeline.markVariantExported(
              assetId: "other", variant: fixture.variant, year: 2025, month: 1,
              relPath: fixture.placement.relativePath, filename: fixture.filename,
              exportedAt: Date())
          }
        }
      }
      try #require(await maintenance.waitForEnter(count: 1))
      gate.release()
      try #require(
        await eventually("interrupted completion seeks admission") {
          admission.pendingWaiterCount > 0
        })
      #expect(fixture.files.timestampCalls.isEmpty)
      await maintenance.releaseAll()
      await operation?.value
      await fixture.manager.waitForQueueDrained()
      #expect(fixture.variants()[fixture.variant]?.status == .failed)
      #expect(try Data(contentsOf: fixture.finalURL) == before)
      #expect(fixture.files.timestampCalls.isEmpty)
      #expect(fixture.writer.writeCalls.isEmpty)
      #expect(fixture.files.moveCalls.isEmpty && fixture.files.copyCalls.isEmpty)
      let foreign =
        collection
        ? fixture.collections.exportInfo(assetId: "other", placement: fixture.placement)?.variants[
          fixture.variant]
        : fixture.timeline.exportInfo(assetId: "other")?.variants[fixture.variant]
      #expect(foreign?.status == .done && foreign?.filename == fixture.filename)
      #expect(fixture.destination.opened == fixture.destination.closed)
    } cleanup: {
      gate.release()
      await maintenance.releaseAll()
      await operation?.value
      await fixture.cleanup()
      await gate.entered.releaseAll()
    }
  }

  @Test(arguments: [false, true], Mismatch.allCases)
  func unrelatedOrInvalidFilesAreNeverAdopted(collection: Bool, mismatch: Mismatch) async throws {
    let fixture = try await makeFixture(collection: collection, mismatch: mismatch)
    fixture.start()
    await fixture.manager.waitForQueueDrained()
    #expect(fixture.variants()[fixture.variant]?.status == .failed)
    #expect(fixture.writer.writeCalls.isEmpty)
    #expect(fixture.files.moveCalls.isEmpty)
    #expect(fixture.files.timestampCalls.isEmpty)
    if mismatch != .directory && mismatch != .empty {
      let expected = mismatch == .symlink ? "still-bytes" : "paired-bytes"
      #expect(try Data(contentsOf: fixture.finalURL) == Data(expected.utf8))
    }
    await fixture.cleanup()
  }

  @Test(arguments: [false, true])
  func missingInterruptedFileIsExportedOnce(collection: Bool) async throws {
    let fixture = try await makeFixture(collection: collection)
    try FileManager.default.removeItem(at: fixture.finalURL)
    fixture.start()
    await fixture.manager.waitForQueueDrained()
    #expect(try await fixture.reloadVariants()[fixture.variant]?.status == .done)
    fixture.start()
    await fixture.manager.waitForQueueDrained()
    #expect(fixture.writer.writeCalls.count == 1)
    #expect(fixture.files.moveCalls.count == 1)
    await fixture.cleanup()
  }

  @Test(arguments: [nil, 0, -1] as [Int64?])
  func unknownReportedSizeStillRecoversNonemptyFile(reported: Int64?) async throws {
    let fixture = try await makeFixture(collection: false)
    fixture.photos.resourcesByAssetId["asset"] = [
      .init(type: .photo, originalFilename: "FILE.JPG"),
      .init(type: .pairedVideo, originalFilename: "FILE.MOV", fileSize: reported),
    ]
    fixture.start()
    await fixture.manager.waitForQueueDrained()
    #expect(try await fixture.reloadVariants()[fixture.variant]?.status == .done)
    #expect(fixture.writer.writeCalls.isEmpty)
    await fixture.cleanup()
  }

  @Test func inspectionErrorKeepsExistingFileUnadopted() async throws {
    let fixture = try await makeFixture(collection: false)
    fixture.files.inspectionHook = { _ in throw CocoaError(.fileReadNoPermission) }
    fixture.start()
    await fixture.manager.waitForQueueDrained()
    #expect(fixture.variants()[fixture.variant]?.status == .failed)
    #expect(fixture.writer.writeCalls.isEmpty)
    #expect(fixture.files.timestampCalls.isEmpty)
    #expect(try Data(contentsOf: fixture.finalURL) == Data("paired-bytes".utf8))
    await fixture.cleanup()
  }

  private func reached(
    _ condition: @MainActor () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation
  ) async -> Bool {
    await eventually("reached condition", sourceLocation: sourceLocation) { await condition() }
  }

  private func withGatedCleanup(
    _ fixture: Fixture, gate: Gate, replacement: AsyncCheckpoint,
    body: @MainActor () async throws -> Void
  ) async throws {
    var failure: Error?
    do { try await body() } catch { failure = error }
    fixture.manager.cancelAndClear()
    gate.release()
    await gate.entered.releaseAll()
    await replacement.releaseAll()
    fixture.manager.finalCommitWaitObserver = nil
    await fixture.cleanup()
    if let failure { throw failure }
  }

  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func staleProbeCannotAdoptIntoReplacementDestination(collection: Bool) async throws {
    let f = try await makeFixture(collection: collection)
    let probe = Gate()
    let replacement = AsyncCheckpoint()
    try await withGatedCleanup(f, gate: probe, replacement: replacement) {
      f.files.inspectionHook = { _ in probe.holdOnce() }
      f.start()
      try #require(await reached { await probe.entered.enteredSoFar > 0 })
      let old = f.manager.currentTask
      #expect(old != nil)
      #expect(f.destination.closed.isEmpty)
      f.manager.cancelAndClear()
      await f.select("B")
      f.writer.checkpoint = replacement
      f.start()
      // Selection remains responsive while admitted physical IO finishes on the serial worker.
      #expect(f.destination.selectedFolderURL?.lastPathComponent == "B")
      #expect(f.writer.writeCalls.isEmpty)
      probe.release()
      await old?.value
      try #require(await reached { await replacement.enteredSoFar > 0 })
      #expect(f.variants()[.original]?.status == .inProgress)
      #expect(f.variants()[.originalPairedVideo] == nil)
      #expect(f.files.timestampCalls.isEmpty)
      #expect(f.writer.writeCalls.count == 1)
      #expect(f.destination.closed.map(\.path) == [f.destination.rootURL.path])
      await replacement.releaseAll()
      await probe.entered.releaseAll()
      await f.manager.waitForQueueDrained()
      #expect(try await f.reloadVariants()[f.variant]?.reason == .interrupted)
      #expect(try Data(contentsOf: f.finalURL) == Data("paired-bytes".utf8))
      #expect(
        f.destination.opened.map(\.path).sorted() == f.destination.closed.map(\.path).sorted())
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func admittedRecoveryAcknowledgesCapturedDestinationBeforeReplacement(collection: Bool)
    async throws
  {
    let f = try await makeFixture(collection: collection)
    let timestamps = Gate()
    let replacement = AsyncCheckpoint()
    var didWaitForCommit = false
    try await withGatedCleanup(f, gate: timestamps, replacement: replacement) {
      f.files.afterTimestampsHook = { _ in timestamps.holdOnce() }
      f.start()
      try #require(await reached { await timestamps.entered.enteredSoFar > 0 })
      let old = f.manager.currentTask
      #expect(old != nil)
      f.manager.cancelAndClear()
      await f.select("B")
      f.manager.finalCommitWaitObserver = { didWaitForCommit = true }
      f.writer.checkpoint = replacement
      f.start()
      try #require(await reached { didWaitForCommit })
      #expect(f.writer.writeCalls.isEmpty)
      #expect(f.variants().isEmpty)
      #expect(f.destination.closed.isEmpty)
      timestamps.release()
      await old?.value
      try #require(await reached { await replacement.enteredSoFar > 0 })
      #expect(try await f.reloadVariants()[f.variant]?.status == .done)
      #expect(f.variants()[.originalPairedVideo] == nil)
      #expect(f.files.timestampCalls.map(\.url) == [f.finalURL])
      await replacement.releaseAll()
      await timestamps.entered.releaseAll()
      await f.manager.waitForQueueDrained()
      f.manager.finalCommitWaitObserver = nil
      #expect(try Data(contentsOf: f.finalURL) == Data("paired-bytes".utf8))
      #expect(
        f.destination.opened.map(\.path).sorted() == f.destination.closed.map(\.path).sorted())
    }
  }
}
