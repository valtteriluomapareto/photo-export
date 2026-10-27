import Foundation
import Testing

@testable import Photo_Export

/// Phase 3.1 of the collections-export plan adds `urlForRelativeDirectory` to
/// `ExportDestination` with destination-side escape protection. Per
/// `docs/project/archive/collections-export-plan.md` §"Export Destination", rejected
/// inputs include absolute paths, `..` segments, paths whose canonical resolution lands
/// outside the export root, paths where a non-directory exists at an intermediate
/// component, and paths exceeding the platform path length.
@Suite(.timeLimit(.minutes(2)))
@MainActor
struct ExportDestinationEscapeProtectionTests {

  // MARK: - Helpers

  private func makeManagerAndRoot(fileSystem: any FileSystemService = FileIOService()) throws -> (
    ExportDestinationManager, URL
  ) {
    let dir = TestScratch.directory("ExportDestEscape")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let mgr = ExportDestinationManager(
      skipRestore: true, userDefaults: TestScratch.defaults("DestinationManager"),
      fileSystem: fileSystem)
    mgr.setSelectedFolderForTesting(dir)
    return (mgr, dir)
  }

  // MARK: - Happy path

  @Test func validRelativePathCreatesDirectory() throws {
    let (mgr, root) = try makeManagerAndRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try mgr.urlForRelativeDirectory("Collections/Albums/Trip/", createIfNeeded: true)
    #expect(url.path.hasPrefix(root.path))
    var isDir: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir))
    #expect(isDir.boolValue)
  }

  @Test(arguments: [false, true])
  func disappearedDirectoryIsNotSilentlyRecreated(rename: Bool) throws {
    let (manager, root) = try makeManagerAndRoot()
    let directory = try manager.urlForRelativeDirectory("2025/02/", createIfNeeded: true)
    if rename {
      try FileManager.default.moveItem(at: directory, to: root.appendingPathComponent("moved"))
    } else {
      try FileManager.default.removeItem(at: directory)
    }
    #expect(throws: (any Error).self) {
      _ = try manager.urlForRelativeDirectory("2025/02/", createIfNeeded: true)
    }
    #expect(!FileManager.default.fileExists(atPath: directory.path))
  }

  @Test func generationAndRootChangesResolveAgain() throws {
    let files = FakeFileSystem()
    let (manager, root) = try makeManagerAndRoot(fileSystem: files)
    manager.prepareDirectoryResolution(generation: 1)
    let first = try manager.urlForRelativeDirectory("2025/02/", createIfNeeded: true)
    let warm = files.calls.count
    #expect(try manager.urlForRelativeDirectory("2025/02/", createIfNeeded: true) == first)
    #expect(files.calls.count - warm <= 2)
    manager.prepareDirectoryResolution(generation: 2)
    let cold = files.calls.count
    _ = try manager.urlForRelativeDirectory("2025/02/", createIfNeeded: true)
    #expect(files.calls[cold...].contains { $0.operation == "resolvingSymlinks" })
    let other = root.appendingPathComponent("other")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    manager.setSelectedFolderForTesting(other)
    let changed = try manager.urlForRelativeDirectory("2025/02/", createIfNeeded: true)
    #expect(changed.path.hasPrefix(other.path + "/"))
  }

  @Test func unavailableDestinationDropsCachedResolution() throws {
    let root = TestScratch.directory("UnavailableDirectoryCache")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let manager = ExportDestinationManager(
      skipRestore: true, userDefaults: TestScratch.defaults("UnavailableDirectoryCache"),
      validationScopeAcquirer: { _ in false }, validationScopeReleaser: { _ in })
    manager.setSelectedFolderForTesting(root)
    let directory = try manager.urlForRelativeDirectory("2025/02/", createIfNeeded: true)
    manager.revalidateForTesting()
    #expect(throws: ExportDestinationManager.ExportDestinationError.notAvailable) {
      _ = try manager.urlForRelativeDirectory("2025/02/", createIfNeeded: true)
    }
    try FileManager.default.removeItem(at: directory)
    let outside = TestScratch.directory("UnavailableDirectoryOutside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside)
    manager.setSelectedFolderForTesting(root)
    #expect(throws: ExportDestinationManager.ExportDestinationError.self) {
      _ = try manager.urlForRelativeDirectory("2025/02/", createIfNeeded: true)
    }
  }

  @Test func replacedCachedDirectoryChecksSymlinkEscapeAgain() throws {
    let (manager, _) = try makeManagerAndRoot()
    let directory = try manager.urlForRelativeDirectory("2025/02/", createIfNeeded: true)
    let outside = TestScratch.directory("OutsideCachedDestination")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.removeItem(at: directory)
    try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside)
    #expect(throws: ExportDestinationManager.ExportDestinationError.self) {
      _ = try manager.urlForRelativeDirectory("2025/02/", createIfNeeded: true)
    }
  }

  @Test(arguments: [false, true])
  func sameInodeReparentCannotEscapeThroughCachedLeafOrAncestor(ancestor: Bool) throws {
    let (manager, _) = try makeManagerAndRoot()
    let directory = try manager.urlForRelativeDirectory("2025/02/", createIfNeeded: true)
    let originalIdentity = try FileIOService().directoryIdentity(at: directory)
    let moved = TestScratch.directory("ReparentedDirectory")
    let source = ancestor ? directory.deletingLastPathComponent() : directory
    try FileManager.default.moveItem(at: source, to: moved)
    let movedDirectory = ancestor ? moved.appendingPathComponent("02", isDirectory: true) : moved
    #expect(try FileIOService().directoryIdentity(at: movedDirectory) == originalIdentity)
    try FileManager.default.createSymbolicLink(at: source, withDestinationURL: moved)
    #expect(try FileIOService().directoryIdentity(at: directory) == originalIdentity)
    #expect(throws: ExportDestinationManager.ExportDestinationError.self) {
      _ = try manager.urlForRelativeDirectory("2025/02/", createIfNeeded: true)
    }
  }

  enum EarlierDirectoryChange: CaseIterable { case deletion, leafReparent, ancestorReparent }

  @Test(arguments: EarlierDirectoryChange.allCases)
  func earlierDirectoryStaysProtectedAfterCacheEviction(change: EarlierDirectoryChange) throws {
    let files = FakeFileSystem()
    files.directoryHandleLimit = 32
    let (manager, _) = try makeManagerAndRoot(fileSystem: files)
    let directory = try manager.urlForRelativeDirectory("2025/02/", createIfNeeded: true)
    // More paths than the injected descriptor supply must still resolve. Previously
    // visited paths retain their safety checks after their live handles are evicted.
    for index in 0..<40 {
      _ = try manager.urlForRelativeDirectory("cache-\(index)/", createIfNeeded: true)
    }
    switch change {
    case .deletion:
      try FileManager.default.removeItem(at: directory)
    case .leafReparent, .ancestorReparent:
      let source = change == .ancestorReparent ? directory.deletingLastPathComponent() : directory
      let moved = TestScratch.directory("EvictedReparent")
      let original = try FileIOService().directoryIdentity(at: directory)
      try FileManager.default.moveItem(at: source, to: moved)
      try FileManager.default.createSymbolicLink(at: source, withDestinationURL: moved)
      #expect(try FileIOService().directoryIdentity(at: directory) == original)
    }
    #expect(throws: (any Error).self) {
      _ = try manager.urlForRelativeDirectory("2025/02/", createIfNeeded: true)
    }
    if change == .deletion {
      #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
  }

  /// Keeps resolution on the real manager while scratch URLs need no security bookmark.
  private final class ScratchDestination: ExportDestination {
    let manager: ExportDestinationManager
    init(_ manager: ExportDestinationManager) { self.manager = manager }
    var selectedFolderURL: URL? { manager.selectedFolderURL }
    var canExportNow: Bool { manager.canExportNow }
    var canImportNow: Bool { manager.canImportNow }
    func beginScopedAccess() -> URL? { selectedFolderURL }
    func endScopedAccess(for url: URL) {}
    func waitForValidation() async { await manager.waitForValidation() }
    func resetDirectoryResolution() { manager.resetDirectoryResolution() }
    func prepareDirectoryResolution(generation: Int) {
      manager.prepareDirectoryResolution(generation: generation)
    }
    func revalidateDirectory(_ path: String) throws { try manager.revalidateDirectory(path) }
    func captureDirectoryAccess(generation: Int) throws -> any ExportDirectoryResolving {
      try manager.captureDirectoryAccess(generation: generation)
    }
    func urlForRelativeDirectory(_ path: String, createIfNeeded: Bool) throws -> URL {
      try manager.urlForRelativeDirectory(path, createIfNeeded: createIfNeeded)
    }
    func urlForMonth(year: Int, month: Int, createIfNeeded: Bool) throws -> URL {
      try manager.urlForMonth(year: year, month: month, createIfNeeded: createIfNeeded)
    }
  }

  @Test func steadyExportUsesAtMostThreeMainThreadFilesystemCallsPerAsset() async throws {
    let files = FakeFileSystem()
    let (destination, _) = try makeManagerAndRoot(fileSystem: files)
    let photos = FakePhotoLibraryService()
    let writer = FakeAssetResourceWriter()
    let checkpoint = AsyncCheckpoint()
    writer.checkpoint = checkpoint
    let records = ExportRecordStore(
      baseDirectoryURL: TestScratch.directory("DirectoryCountRecords"))
    await records.configureAndWait(for: "count")
    let manager = ExportManager(
      photoLibraryService: photos, exportDestination: ScratchDestination(destination),
      exportRecordStore: records,
      collectionExportRecordStore: CollectionExportRecordStore(
        baseDirectoryURL: TestScratch.directory("DirectoryCountCollections")),
      assetResourceWriter: writer, fileSystem: files,
      userDefaults: TestScratch.defaults("DirectoryCount"))
    let assets = (0..<3).map {
      TestAssetFactory.makeAsset(
        id: "directory-count-\($0)",
        creationDate: Calendar.current.date(from: DateComponents(year: 2025, month: 2, day: 1)))
    }
    photos.assetsByYearMonth["2025-2"] = assets
    for asset in assets {
      photos.resourcesByAssetId[asset.id] = [
        TestAssetFactory.makeResource(originalFilename: "\(asset.id).JPG")
      ]
    }
    manager.startExportMonth(year: 2025, month: 2)
    await checkpoint.waitForEnter(count: 1)
    // The first asset warms the directory cache. Each next checkpoint brackets one
    // commit/cleanup and the next asset's identity, physical-path and filename probes.
    var start = files.calls.count
    for index in 2...3 {
      await checkpoint.release()
      await checkpoint.waitForEnter(count: index)
      let phase = Array(files.calls.dropFirst(start))
      #expect(phase.filter(\.onMainThread).count <= 3)
      #expect(phase.contains { !$0.onMainThread })
      start = files.calls.count
    }
    await checkpoint.releaseAll()
    await manager.waitForQueueDrained()
    #expect(
      assets.allSatisfy { records.exportInfo(assetId: $0.id)?.variants[.original]?.status == .done }
    )
  }

  @Test func directoryDeletedDuringStageWriteIsNotRecreated() async throws {
    let files = FakeFileSystem()
    let (destination, _) = try makeManagerAndRoot(fileSystem: files)
    let photos = FakePhotoLibraryService()
    let writer = FakeAssetResourceWriter()
    let records = ExportRecordStore(baseDirectoryURL: TestScratch.directory("DeletedStageRecords"))
    await records.configureAndWait(for: "deleted")
    let manager = ExportManager(
      photoLibraryService: photos, exportDestination: ScratchDestination(destination),
      exportRecordStore: records,
      collectionExportRecordStore: CollectionExportRecordStore(
        baseDirectoryURL: TestScratch.directory("DeletedStageCollections")),
      assetResourceWriter: writer, fileSystem: files,
      userDefaults: TestScratch.defaults("DeletedStage"))
    let asset = TestAssetFactory.makeAsset(
      id: "deleted-stage",
      creationDate: Calendar.current.date(from: DateComponents(year: 2025, month: 2, day: 1)))
    photos.assetsByYearMonth["2025-2"] = [asset]
    photos.resourcesByAssetId[asset.id] = [TestAssetFactory.makeResource()]
    writer.writeHook = { url in
      try FileManager.default.removeItem(at: url.deletingLastPathComponent())
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
    }
    manager.startExportMonth(year: 2025, month: 2)
    await manager.waitForQueueDrained()
    #expect(writer.writeCalls.count == 1)
    let stage = try #require(writer.writeCalls.first?.url)
    #expect(!FileManager.default.fileExists(atPath: stage.deletingLastPathComponent().path))
    #expect(records.exportInfo(assetId: asset.id)?.variants[.original]?.status == .failed)
  }

  @Test(arguments: [ENOENT, ENOTDIR], [false, true])
  func missingDirectoryProducerIsRetriedOnlyOnce(code: Int32, succeedsOnRetry: Bool) async throws {
    let harness = ExportManagerHarness(label: "DirectoryRetry")
    let asset = TestAssetFactory.makeAsset(
      id: "retry",
      creationDate: Calendar.current.date(from: DateComponents(year: 2025, month: 2, day: 1)))
    harness.photoLib.assetsByYearMonth["2025-2"] = [asset]
    harness.photoLib.resourcesByAssetId[asset.id] = [TestAssetFactory.makeResource()]
    let writer = harness.writer
    writer.writeHook = { _ in
      if !succeedsOnRetry || writer.writeCalls.count == 1 {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
      }
    }
    harness.manager.startExportMonth(year: 2025, month: 2)
    await harness.manager.waitForQueueDrained()
    #expect(harness.writer.writeCalls.count == 2)
    #expect(harness.dest.revalidationCount == 1)
    #expect(
      harness.store.exportInfo(assetId: asset.id)?.variants[.original]?.status
        == (succeedsOnRetry ? .done : .failed))
  }

  private final class CleanupGate: @unchecked Sendable {
    let entered = AsyncCheckpoint()
    private let releaseSignal = DispatchSemaphore(value: 0)
    func hold() {
      Task { await entered.enter() }
      releaseSignal.wait()
    }
    func release() { releaseSignal.signal() }
  }

  enum CleanupOutcome: CaseIterable { case success, failure, cancellation }

  @Test(arguments: CleanupOutcome.allCases)
  func stageCleanupFinishesBeforeDestinationScopeCloses(outcome: CleanupOutcome) async throws {
    let harness = ExportManagerHarness(label: "DirectoryCleanup")
    let asset = TestAssetFactory.makeAsset(
      id: "cleanup",
      creationDate: Calendar.current.date(from: DateComponents(year: 2025, month: 2, day: 1)))
    harness.photoLib.assetsByYearMonth["2025-2"] = [asset]
    harness.photoLib.resourcesByAssetId[asset.id] = [TestAssetFactory.makeResource()]
    let writerGate = AsyncCheckpoint()
    harness.writer.checkpoint = writerGate
    let cleanup = CleanupGate()
    harness.fileSystem.existsHook = { path in
      if URL(fileURLWithPath: path).lastPathComponent.hasPrefix(".photo-export-") {
        if pthread_main_np() != 0 {
          Issue.record("Stage cleanup must run off the main thread")
          Task { await cleanup.entered.enter() }
        } else {
          cleanup.hold()
        }
      }
    }
    defer { cleanup.release() }
    harness.manager.startExportMonth(year: 2025, month: 2)
    await writerGate.waitForEnter(count: 1)
    let running = try #require(harness.manager.currentTask)
    if outcome == .failure { harness.writer.writeError = CocoaError(.fileWriteNoPermission) }
    if outcome == .cancellation { harness.manager.cancelAndClear() }
    await writerGate.releaseAll()
    await cleanup.entered.waitForEnter(count: 1)
    #expect(harness.dest.endScopedAccessCount == 0)
    cleanup.release()
    await cleanup.entered.releaseAll()
    _ = await running.value
    #expect(harness.dest.beginScopedAccessCount == harness.dest.endScopedAccessCount)
  }

  // MARK: - Rejected inputs

  @Test func absolutePathIsRejected() throws {
    let (mgr, root) = try makeManagerAndRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: ExportDestinationManager.ExportDestinationError.self) {
      _ = try mgr.urlForRelativeDirectory("/etc/passwd", createIfNeeded: false)
    }
  }

  @Test func dotDotSegmentRejected() throws {
    let (mgr, root) = try makeManagerAndRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: ExportDestinationManager.ExportDestinationError.self) {
      _ = try mgr.urlForRelativeDirectory("Collections/../../etc", createIfNeeded: false)
    }
  }

  @Test func bareDotSegmentRejected() throws {
    let (mgr, root) = try makeManagerAndRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: ExportDestinationManager.ExportDestinationError.self) {
      _ = try mgr.urlForRelativeDirectory("Collections/./Albums", createIfNeeded: false)
    }
  }

  @Test func emptyPathRejected() throws {
    let (mgr, root) = try makeManagerAndRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: ExportDestinationManager.ExportDestinationError.self) {
      _ = try mgr.urlForRelativeDirectory("", createIfNeeded: false)
    }
  }

  @Test func doubleSlashRejected() throws {
    let (mgr, root) = try makeManagerAndRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: ExportDestinationManager.ExportDestinationError.self) {
      _ = try mgr.urlForRelativeDirectory("Collections//Albums", createIfNeeded: false)
    }
  }

  // MARK: - Symlink escape

  /// Regression: the prefix check used to be bare `hasPrefix(rootCanonical)`, which let
  /// a sibling directory whose name *starts with* the root path (e.g. root `/tmp/Foo`
  /// and target `/tmp/Foo-old/Trip`) bypass the escape check. The boundary-safe check
  /// uses `root + "/"` (or equality with root) so the prefix only matches at a path
  /// component boundary.
  @Test func siblingDirectoryWithSimilarPrefixIsRejected() throws {
    let parent = TestScratch.directory("EscapePrefix")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }

    let root = parent.appendingPathComponent("Backup", isDirectory: true)
    let sibling = parent.appendingPathComponent("Backup-old", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)

    let mgr = ExportDestinationManager(
      skipRestore: true, userDefaults: TestScratch.defaults("DestinationManager"))
    mgr.setSelectedFolderForTesting(root)

    // A symlink inside the root pointing at the sibling whose name happens to share a
    // prefix with the root path. Without the boundary check, the resolver would accept
    // any path under `escape/` as still being under root.
    let escapeLink = root.appendingPathComponent("escape", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: escapeLink, withDestinationURL: sibling)

    #expect(throws: ExportDestinationManager.ExportDestinationError.self) {
      _ = try mgr.urlForRelativeDirectory("escape/Trip", createIfNeeded: false)
    }
  }

  /// If a parent directory is a symlink pointing outside the export root, the resolver
  /// must catch it and refuse — otherwise a Finder-placed symlink could trick the app
  /// into writing exports outside the selected folder.
  @Test func symlinkEscapeIsRejected() throws {
    let (mgr, root) = try makeManagerAndRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // Create an external folder and a symlink inside the root pointing to it.
    let outside = TestScratch.directory("Outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outside) }
    let escapeLink = root.appendingPathComponent("escape", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: escapeLink, withDestinationURL: outside)

    #expect(throws: ExportDestinationManager.ExportDestinationError.self) {
      _ = try mgr.urlForRelativeDirectory("escape/Trip", createIfNeeded: false)
    }
  }

  // MARK: - Non-directory intermediate

  /// If a regular file exists where the resolver expects an intermediate directory,
  /// reject rather than silently fail later when `createDirectory` throws.
  @Test func nonDirectoryIntermediateIsRejected() throws {
    let (mgr, root) = try makeManagerAndRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // Place a regular file at root/Collections.
    let intruder = root.appendingPathComponent("Collections")
    try Data("oops".utf8).write(to: intruder)

    #expect(throws: ExportDestinationManager.ExportDestinationError.self) {
      _ = try mgr.urlForRelativeDirectory("Collections/Albums/Trip", createIfNeeded: false)
    }
  }

  // MARK: - Path length

  @Test func excessivelyLongPathIsRejected() throws {
    let (mgr, root) = try makeManagerAndRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let longComponent = String(repeating: "x", count: 600)
    let longPath = "\(longComponent)/\(longComponent)/leaf"
    #expect(throws: ExportDestinationManager.ExportDestinationError.pathTooLong) {
      _ = try mgr.urlForRelativeDirectory(longPath, createIfNeeded: false)
    }
  }

  // MARK: - urlForMonth still works as a wrapper

  @Test func urlForMonthDelegatesToUrlForRelativeDirectory() throws {
    let (mgr, root) = try makeManagerAndRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try mgr.urlForMonth(year: 2025, month: 6)
    #expect(url.lastPathComponent == "06")
    #expect(url.deletingLastPathComponent().lastPathComponent == "2025")
    #expect(url.path.hasPrefix(root.path))
  }
}
