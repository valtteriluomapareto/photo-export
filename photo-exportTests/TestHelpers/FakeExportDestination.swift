import Foundation

@testable import Photo_Export

@MainActor
final class FakeExportDestination: ExportDestination {
  private typealias ExportDestinationError = ExportDestinationManager.ExportDestinationError
  var selectedFolderURL: URL?
  var canExportNow: Bool = true
  var canImportNow: Bool = true

  // The root temp directory for test exports
  let rootURL: URL

  // Call tracking
  var beginScopedAccessCount = 0
  var endScopedAccessCount = 0
  var openedScopeURLs: [URL] = []
  var closedScopeURLs: [URL] = []

  // Error injection
  var scopedAccessAvailable = true
  var urlForMonthError: Error?
  var urlForRelativeDirectoryError: Error?

  init() {
    rootURL = TestScratch.directory("FakeExportDest")
    try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    selectedFolderURL = rootURL
  }

  var revalidationCount = 0
  func revalidateDirectory(_ relativePath: String) throws {
    revalidationCount += 1
    _ = try urlForRelativeDirectory(relativePath, createIfNeeded: false)
  }

  func urlForRelativeDirectory(_ relativePath: String, createIfNeeded: Bool) throws -> URL {
    if let error = urlForRelativeDirectoryError { throw error }
    let root = rootURL
    guard !relativePath.isEmpty else {
      throw ExportDestinationError.invalidRelativePath("path is empty")
    }
    guard !relativePath.hasPrefix("/") else {
      throw ExportDestinationError.invalidRelativePath("absolute path: \(relativePath)")
    }

    // Split on forward slash. Trailing slash is allowed (collection placements include it
    // by convention); empty interior components are not (would be a `//` segment).
    let trimmed =
      relativePath.hasSuffix("/")
      ? String(relativePath.dropLast()) : relativePath
    let components = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(
      String.init)
    for component in components {
      if component.isEmpty {
        throw ExportDestinationError.invalidRelativePath(
          "empty component in path: \(relativePath)")
      }
      if component == ".." {
        throw ExportDestinationError.invalidRelativePath(
          ".. segment in path: \(relativePath)")
      }
      if component == "." {
        throw ExportDestinationError.invalidRelativePath(
          ". segment in path: \(relativePath)")
      }
    }

    // Build the target URL by appending components.
    var target = root
    for component in components {
      target = target.appendingPathComponent(component, isDirectory: true)
    }

    // Path-length guard (PATH_MAX is 1024 on macOS; reserve some headroom for the
    // filename that will be appended later).
    if target.path.utf8.count >= 1000 { throw ExportDestinationError.pathTooLong }

    // Symlink-escape protection: resolve symlinks on the deepest existing prefix and
    // verify it still lies under the root's canonical path. If the user has placed a
    // symlink at `<root>/Collections/Albums/Trip` pointing outside the destination, the
    // resolved path would not have the root as a prefix.
    let rootCanonical = root.standardizedFileURL.resolvingSymlinksInPath().path
    let targetCanonical = Self.canonicalizeExistingPrefix(of: target).path
    // Boundary-safe prefix check: a bare `hasPrefix(rootCanonical)` would let
    // `/tmp/Backup-old/Trip` slip past a root of `/tmp/Backup`. Accept either equal-to-
    // root (zero-length tail) or root-followed-by-slash. `rootCanonical` itself never
    // ends with `/` (FileManager's standardized paths drop the trailing slash) so we
    // append it explicitly here.
    let rootBoundary = rootCanonical + "/"
    if targetCanonical != rootCanonical && !targetCanonical.hasPrefix(rootBoundary) {
      throw ExportDestinationError.invalidRelativePath(
        "path resolves outside the export root: \(relativePath)")
    }

    // Verify each existing intermediate component is a directory (or doesn't exist yet,
    // in which case `ensureDirectoryExists` will create it).
    let fileManager = FileManager.default
    var probe = root
    for component in components {
      probe = probe.appendingPathComponent(component, isDirectory: true)
      var isDir: ObjCBool = false
      if fileManager.fileExists(atPath: probe.path, isDirectory: &isDir) {
        if !isDir.boolValue {
          throw ExportDestinationError.notDirectory(probe)
        }
      } else {
        // Stop probing; remaining segments don't exist yet.
        break
      }
    }

    if createIfNeeded {
      try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    } else {
      var isDir: ObjCBool = false
      if fileManager.fileExists(atPath: target.path, isDirectory: &isDir) {
        if !isDir.boolValue { throw ExportDestinationError.notDirectory(target) }
      }
    }

    return target
  }

  private static func canonicalizeExistingPrefix(of url: URL) -> URL {
    let fileManager = FileManager.default
    var components: [String] = []
    var current = url
    while !fileManager.fileExists(atPath: current.path) {
      components.insert(current.lastPathComponent, at: 0)
      let parent = current.deletingLastPathComponent()
      // Stop at the filesystem root to avoid infinite loops on malformed input.
      if parent.path == current.path { break }
      current = parent
    }
    var result = current.standardizedFileURL.resolvingSymlinksInPath()
    for component in components {
      result = result.appendingPathComponent(component, isDirectory: true)
    }
    return result
  }

  func urlForMonth(year: Int, month: Int, createIfNeeded: Bool) throws -> URL {
    if let error = urlForMonthError { throw error }
    let relPath = "\(year)/\(String(format: "%02d", month))/"
    return try urlForRelativeDirectory(relPath, createIfNeeded: createIfNeeded)
  }

  func beginScopedAccess() -> URL? {
    beginScopedAccessCount += 1
    guard scopedAccessAvailable else { return nil }
    if let selectedFolderURL { openedScopeURLs.append(selectedFolderURL) }
    return selectedFolderURL
  }

  func endScopedAccess(for url: URL) {
    endScopedAccessCount += 1
    closedScopeURLs.append(url)
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}
