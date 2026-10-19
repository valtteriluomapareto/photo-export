import Foundation

@testable import Photo_Export

@MainActor
final class FakeExportDestination: ExportDestination {
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

  func urlForRelativeDirectory(_ relativePath: String, createIfNeeded: Bool) throws -> URL {
    if let error = urlForRelativeDirectoryError { throw error }
    var dir = rootURL
    let trimmed =
      relativePath.hasSuffix("/") ? String(relativePath.dropLast()) : relativePath
    for component in trimmed.split(separator: "/", omittingEmptySubsequences: false) {
      dir = dir.appendingPathComponent(String(component), isDirectory: true)
    }
    if createIfNeeded {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    return dir
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
