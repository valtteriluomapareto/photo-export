import Foundation
import os

/// Retains one root and its physical directory cache while admitted IO owns that scope.
final class DestinationDirectoryAccess: ExportDirectoryResolving, @unchecked Sendable {
  private typealias ExportDestinationError = ExportDestinationManager.ExportDestinationError
  private let root: URL
  private let fileSystem: any FileSystemService
  private let lock = NSLock()
  private let logger = Logger.app(.exportDestination)
  private struct ResolvedDirectory {
    let url: URL
    let handle: any FileDirectoryHandle
    let physicalRoot: String
  }
  private static let maximumDirectoryHandles = 16
  private var directoryResolutions: [String: ResolvedDirectory] = [:]
  private var previouslyResolvedDirectories: Set<String> = []

  init(root: URL, fileSystem: any FileSystemService = FileIOService()) {
    self.root = root
    self.fileSystem = fileSystem
  }

  private func inspectDirectory(at url: URL) throws -> FileItemIdentity? {
    do { return try fileSystem.directoryIdentity(at: url) } catch let error as NSError
      where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOTDIR)
    {
      throw ExportDestinationError.notDirectory(url)
    }
  }

  func revalidateDirectory(_ relativePath: String) throws {
    try lock.withLock {
      let key = relativePath.hasSuffix("/") ? String(relativePath.dropLast()) : relativePath
      directoryResolutions.removeValue(forKey: key)
      previouslyResolvedDirectories.insert(key)
      _ = try resolve(relativePath, createIfNeeded: false)
    }
  }

  func urlForRelativeDirectory(_ relativePath: String, createIfNeeded: Bool) throws -> URL {
    try lock.withLock { try resolve(relativePath, createIfNeeded: createIfNeeded) }
  }

  private func resolve(_ relativePath: String, createIfNeeded: Bool) throws -> URL {
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

    if let cached = directoryResolutions[trimmed] {
      if try inspectDirectory(at: cached.url) == cached.handle.identity {
        let physicalPath = try fileSystem.directoryPhysicalPath(cached.handle).path
        guard Self.contains(physicalPath, under: cached.physicalRoot) else {
          directoryResolutions.removeValue(forKey: trimmed)
          previouslyResolvedDirectories.insert(trimmed)
          throw ExportDestinationError.invalidRelativePath(
            "path resolves outside the export root: \(relativePath)")
        }
        return cached.url
      }
      directoryResolutions.removeValue(forKey: trimmed)
      previouslyResolvedDirectories.insert(trimmed)
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
    let rootCanonical = fileSystem.resolvingSymlinks(at: root).path
    let targetCanonical = try canonicalizeExistingPrefix(of: target).path
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
    var probe = root
    for component in components {
      probe = probe.appendingPathComponent(component, isDirectory: true)
      if try inspectDirectory(at: probe) == nil { break }
    }

    var identity = try inspectDirectory(at: target)
    if identity == nil, previouslyResolvedDirectories.contains(trimmed) {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
    }
    if createIfNeeded, identity == nil {
      try ensureDirectoryExists(at: target)
      identity = try inspectDirectory(at: target)
    }
    if identity != nil {
      // Bound retained descriptors independently of the number of folders in a run.
      if directoryResolutions.count >= Self.maximumDirectoryHandles {
        directoryResolutions.removeAll(keepingCapacity: true)
      }
      // Obtain both physical spellings from the kernel. Foundation can shorten
      // system aliases such as /private/var even after resolving their symlinks.
      let rootHandle = try fileSystem.openDirectory(at: root)
      let physicalRoot = try fileSystem.directoryPhysicalPath(rootHandle).path
      let handle = try fileSystem.openDirectory(at: target)
      guard Self.contains(try fileSystem.directoryPhysicalPath(handle).path, under: physicalRoot)
      else {
        throw ExportDestinationError.invalidRelativePath(
          "path resolves outside the export root: \(relativePath)")
      }
      directoryResolutions[trimmed] = ResolvedDirectory(
        url: target, handle: handle, physicalRoot: physicalRoot)
      previouslyResolvedDirectories.insert(trimmed)
    }

    return target
  }

  private static func contains(_ path: String, under root: String) -> Bool {
    path == root || path.hasPrefix(root + "/")
  }

  /// Walks `url` upward until it finds an ancestor that exists on disk, then resolves
  /// symlinks on that ancestor to get a canonical path. The non-existing tail is
  /// re-appended so the result is still the requested URL — but with the symlink-resolved
  /// existing prefix substituted in. Used by `urlForRelativeDirectory` to detect
  /// symlink-escape attacks where a parent component is a symlink pointing outside the
  /// root.
  private func canonicalizeExistingPrefix(of url: URL) throws -> URL {
    var components: [String] = []
    var current = url
    while try inspectDirectory(at: current) == nil {
      components.insert(current.lastPathComponent, at: 0)
      let parent = current.deletingLastPathComponent()
      // Stop at the filesystem root to avoid infinite loops on malformed input.
      if parent.path == current.path { break }
      current = parent
    }
    var result = fileSystem.resolvingSymlinks(at: current)
    for component in components {
      result = result.appendingPathComponent(component, isDirectory: true)
    }
    return result
  }

  /// Ensures the directory exists at the given URL, creating with intermediates.
  private func ensureDirectoryExists(at url: URL) throws {
    if try inspectDirectory(at: url) != nil { return }
    do {
      try fileSystem.createDirectory(at: url, withIntermediateDirectories: true)
      logger.info("Ensured directory: \(url.path, privacy: .public)")
    } catch {
      logger.error(
        "Failed to create directory: \(url.path, privacy: .public) error: \(String(describing: error), privacy: .public)"
      )
      throw ExportDestinationError.failedToCreateFolder(url, underlying: error)
    }
  }

}
