import Foundation
import Testing

@testable import Photo_Export

/// Phase 3.1 of the collections-export plan adds `urlForRelativeDirectory` to
/// `ExportDestination` with destination-side escape protection. Per
/// `docs/project/archive/collections-export-plan.md` §"Export Destination", rejected
/// inputs include absolute paths, `..` segments, paths whose canonical resolution lands
/// outside the export root, paths where a non-directory exists at an intermediate
/// component, and paths exceeding the platform path length.
@MainActor
struct ExportDestinationEscapeProtectionTests {

  // MARK: - Helpers

  private func makeManagerAndRoot() throws -> (ExportDestinationManager, URL) {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ExportDestEscape-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let mgr = ExportDestinationManager(skipRestore: true)
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
    let parent = FileManager.default.temporaryDirectory
      .appendingPathComponent("EscapePrefix-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }

    let root = parent.appendingPathComponent("Backup", isDirectory: true)
    let sibling = parent.appendingPathComponent("Backup-old", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)

    let mgr = ExportDestinationManager(skipRestore: true)
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
    let outside = FileManager.default.temporaryDirectory
      .appendingPathComponent("Outside-\(UUID().uuidString)", isDirectory: true)
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
