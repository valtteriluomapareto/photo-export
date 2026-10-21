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
  /// The relative path is sanitized at construction time (`ExportPathPolicy` for collection
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

  func beginScopedAccess() -> URL?
  func endScopedAccess(for url: URL)
}
