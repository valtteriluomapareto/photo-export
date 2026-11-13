import Foundation
import Testing

@testable import Photo_Export

/// `urlForRelativeDirectory` keeps directories inside the export root. It rejects absolute
/// paths, `.` and `..` segments, symlink or reparent escapes, a non-directory intermediate
/// component and paths exceeding the platform path length.
@Suite(.timeLimit(.minutes(2)))
@MainActor
struct ExportDestinationEscapeProtectionTests {

  // MARK: - Helpers

  private func makeManagerAndRoot(fileSystem: any FileSystemService = FileIOService()) async throws
    -> (
      ExportDestinationManager, URL
    )
  {
    let dir = TestScratch.directory("ExportDestEscape")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let mgr = ExportDestinationManager(
      skipRestore: true, userDefaults: TestScratch.defaults("DestinationManager"),
      bookmarkSaver: { _ in true }, validationScopeAcquirer: { _ in true },
      validationScopeReleaser: { _ in }, fileSystem: fileSystem)
    await mgr.persistSelectionAndWait(dir)
    return (mgr, dir)
  }

  // MARK: - Happy path

  @Test func validRelativePathCreatesDirectory() async throws {
    let (mgr, root) = try await makeManagerAndRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try mgr.urlForRelativeDirectory("Collections/Albums/Trip/", createIfNeeded: true)
    #expect(url.path.hasPrefix(root.path))
    var isDir: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir))
    #expect(isDir.boolValue)
  }

  @Test(arguments: [false, true])
  func disappearedDirectoryIsNotSilentlyRecreated(rename: Bool) async throws {
    let (manager, root) = try await makeManagerAndRoot()
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

  @Test func generationAndRootChangesResolveAgain() async throws {
    let files = FakeFileSystem()
    let (manager, root) = try await makeManagerAndRoot(fileSystem: files)
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
    await manager.persistSelectionAndWait(other)
    let changed = try manager.urlForRelativeDirectory("2025/02/", createIfNeeded: true)
    #expect(changed.path.hasPrefix(other.path + "/"))
  }

  @Test func unavailableDestinationDropsCachedResolution() async throws {
    let root = TestScratch.directory("UnavailableDirectoryCache")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var allowed = true
    let manager = ExportDestinationManager(
      skipRestore: true, userDefaults: TestScratch.defaults("UnavailableDirectoryCache"),
      bookmarkSaver: { _ in true },
      validationScopeAcquirer: { _ in allowed }, validationScopeReleaser: { _ in })
    await manager.persistSelectionAndWait(root)
    let directory = try manager.urlForRelativeDirectory("2025/02/", createIfNeeded: true)
    allowed = false
    await manager.revalidateAndWait()
    #expect(throws: ExportDestinationManager.ExportDestinationError.notAvailable) {
      _ = try manager.urlForRelativeDirectory("2025/02/", createIfNeeded: true)
    }
    try FileManager.default.removeItem(at: directory)
    let outside = TestScratch.directory("UnavailableDirectoryOutside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside)
    allowed = true
    await manager.persistSelectionAndWait(root)
    #expect(throws: ExportDestinationManager.ExportDestinationError.self) {
      _ = try manager.urlForRelativeDirectory("2025/02/", createIfNeeded: true)
    }
  }

  @Test func replacedCachedDirectoryChecksSymlinkEscapeAgain() async throws {
    let (manager, _) = try await makeManagerAndRoot()
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
  func sameInodeReparentCannotEscapeThroughCachedLeafOrAncestor(ancestor: Bool) async throws {
    let (manager, _) = try await makeManagerAndRoot()
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
  func earlierDirectoryStaysProtectedAfterCacheEviction(change: EarlierDirectoryChange) async throws
  {
    let files = FakeFileSystem()
    files.directoryHandleLimit = 32
    let (manager, _) = try await makeManagerAndRoot(fileSystem: files)
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

  // MARK: - Rejected inputs

  @Test func absolutePathIsRejected() async throws {
    let (mgr, root) = try await makeManagerAndRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: ExportDestinationManager.ExportDestinationError.self) {
      _ = try mgr.urlForRelativeDirectory("/etc/passwd", createIfNeeded: false)
    }
  }

  @Test func dotDotSegmentRejected() async throws {
    let (mgr, root) = try await makeManagerAndRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: ExportDestinationManager.ExportDestinationError.self) {
      _ = try mgr.urlForRelativeDirectory("Collections/../../etc", createIfNeeded: false)
    }
  }

  @Test func bareDotSegmentRejected() async throws {
    let (mgr, root) = try await makeManagerAndRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: ExportDestinationManager.ExportDestinationError.self) {
      _ = try mgr.urlForRelativeDirectory("Collections/./Albums", createIfNeeded: false)
    }
  }

  @Test func emptyPathRejected() async throws {
    let (mgr, root) = try await makeManagerAndRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: ExportDestinationManager.ExportDestinationError.self) {
      _ = try mgr.urlForRelativeDirectory("", createIfNeeded: false)
    }
  }

  @Test func doubleSlashRejected() async throws {
    let (mgr, root) = try await makeManagerAndRoot()
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
  @Test func siblingDirectoryWithSimilarPrefixIsRejected() async throws {
    let parent = TestScratch.directory("EscapePrefix")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }

    let root = parent.appendingPathComponent("Backup", isDirectory: true)
    let sibling = parent.appendingPathComponent("Backup-old", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)

    let mgr = ExportDestinationManager(
      skipRestore: true, userDefaults: TestScratch.defaults("DestinationManager"),
      bookmarkSaver: { _ in true }, validationScopeAcquirer: { _ in true },
      validationScopeReleaser: { _ in })
    await mgr.persistSelectionAndWait(root)

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
  @Test func symlinkEscapeIsRejected() async throws {
    let (mgr, root) = try await makeManagerAndRoot()
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
  @Test func nonDirectoryIntermediateIsRejected() async throws {
    let (mgr, root) = try await makeManagerAndRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // Place a regular file at root/Collections.
    let intruder = root.appendingPathComponent("Collections")
    try Data("oops".utf8).write(to: intruder)

    #expect(throws: ExportDestinationManager.ExportDestinationError.self) {
      _ = try mgr.urlForRelativeDirectory("Collections/Albums/Trip", createIfNeeded: false)
    }
  }

  // MARK: - Path length

  @Test func excessivelyLongPathIsRejected() async throws {
    let (mgr, root) = try await makeManagerAndRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let longComponent = String(repeating: "x", count: 600)
    let longPath = "\(longComponent)/\(longComponent)/leaf"
    #expect(throws: ExportDestinationManager.ExportDestinationError.pathTooLong) {
      _ = try mgr.urlForRelativeDirectory(longPath, createIfNeeded: false)
    }
  }

  // MARK: - urlForMonth still works as a wrapper

  @Test func urlForMonthDelegatesToUrlForRelativeDirectory() async throws {
    let (mgr, root) = try await makeManagerAndRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try mgr.urlForMonth(year: 2025, month: 6)
    #expect(url.lastPathComponent == "06")
    #expect(url.deletingLastPathComponent().lastPathComponent == "2025")
    #expect(url.path.hasPrefix(root.path))
  }
}
