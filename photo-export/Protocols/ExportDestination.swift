import Foundation

/// Abstracts the export destination folder management for testability.
/// ExportDestinationManager conforms in production; tests inject a fake.
@MainActor
protocol ExportDestination: AnyObject {
  var selectedFolderURL: URL? { get }
  var canExportNow: Bool { get }
  var canImportNow: Bool { get }

  /// Resolves a relative directory path under the export root, optionally creating it.
  ///
  /// The relative path is sanitized at construction time (`CollectionPathComponentPolicy` for collection
  /// placements; year/month formatting for timeline). This method enforces the
  /// destination-side invariant that no relative path may escape the export root after
  /// canonicalization. Rejected inputs:
  /// - absolute paths (leading `/`)
  /// - `..` segments
  /// - paths whose canonical resolution lands outside the export root
  /// - paths where a non-directory exists at one of the intermediate components
  /// - paths exceeding the platform's max path length (~1000 bytes UTF-8)
  func urlForRelativeDirectory(_ relativePath: String, createIfNeeded: Bool) throws -> URL

  /// Convenience for the timeline `<YYYY>/<MM>/` layout. Backed by
  /// `urlForRelativeDirectory` so timeline and collection paths share validation.
  func urlForMonth(year: Int, month: Int, createIfNeeded: Bool) throws -> URL

  /// Waits for the current physical validation before queued work captures readiness.
  func waitForValidation() async

  /// Captures the root and cache before a worker hop; selection changes cannot retarget it.
  func captureDirectoryAccess(generation: Int) throws -> any ExportDirectoryResolving

  /// Ends the current queue drain's cached directory resolutions.
  func resetDirectoryResolution()
  /// Starts a new cache lifetime when the queue generation changes.
  func prepareDirectoryResolution(generation: Int)
  /// Drops a failed staged write's resolution and verifies it again without creating a folder.
  func revalidateDirectory(_ relativePath: String) throws

  func beginScopedAccess() -> URL?
  func endScopedAccess(for url: URL)
}

/// Synchronous leaves used only under the caller's retained destination scope.
protocol ExportDirectoryResolving: Sendable {
  func urlForRelativeDirectory(_ relativePath: String, createIfNeeded: Bool) throws -> URL
  func revalidateDirectory(_ relativePath: String) throws
}

extension ExportDestination {
  func waitForValidation() async {}

  func captureDirectoryAccess(generation: Int) throws -> any ExportDirectoryResolving {
    guard let root = selectedFolderURL else {
      throw ExportDestinationManager.ExportDestinationError.noSelection
    }
    guard canExportNow else { throw ExportDestinationManager.ExportDestinationError.notAvailable }
    return DestinationDirectoryAccess(root: root)
  }

  func resetDirectoryResolution() {}
  func prepareDirectoryResolution(generation: Int) {}

  func revalidateDirectory(_ relativePath: String) throws {
    _ = try urlForRelativeDirectory(relativePath, createIfNeeded: false)
  }
}
