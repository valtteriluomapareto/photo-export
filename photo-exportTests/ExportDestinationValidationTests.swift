import Foundation
import Testing

@testable import Photo_Export

@MainActor
struct ExportDestinationValidationTests {

  // MARK: - No folder selected

  @Test func urlForMonthThrowsNoSelectionWhenNoFolderSelected() {
    let mgr = ExportDestinationManager(skipRestore: true)
    #expect(throws: ExportDestinationManager.ExportDestinationError.noSelection) {
      try mgr.urlForMonth(year: 2025, month: 6)
    }
  }

  // MARK: - Invalid year/month (folder selected, available, writable)

  /// Helper that creates a manager pointing at a real temp directory so the
  /// noSelection / notAvailable / notWritable guards pass and we actually hit
  /// the year/month validation.
  private func managerWithFolder() throws -> (ExportDestinationManager, URL) {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ExportDestValidation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let mgr = ExportDestinationManager(skipRestore: true)
    mgr.setSelectedFolderForTesting(dir)
    return (mgr, dir)
  }

  @Test func urlForMonthThrowsInvalidYearForZero() throws {
    let (mgr, dir) = try managerWithFolder()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(throws: ExportDestinationManager.ExportDestinationError.invalidYear) {
      try mgr.urlForMonth(year: 0, month: 6)
    }
  }

  @Test func urlForMonthThrowsInvalidYearForNegative() throws {
    let (mgr, dir) = try managerWithFolder()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(throws: ExportDestinationManager.ExportDestinationError.invalidYear) {
      try mgr.urlForMonth(year: -1, month: 6)
    }
  }

  @Test func urlForMonthThrowsInvalidMonthForZero() throws {
    let (mgr, dir) = try managerWithFolder()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(throws: ExportDestinationManager.ExportDestinationError.invalidMonth) {
      try mgr.urlForMonth(year: 2025, month: 0)
    }
  }

  @Test func urlForMonthThrowsInvalidMonthForThirteen() throws {
    let (mgr, dir) = try managerWithFolder()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(throws: ExportDestinationManager.ExportDestinationError.invalidMonth) {
      try mgr.urlForMonth(year: 2025, month: 13)
    }
  }

  @Test func urlForMonthThrowsInvalidMonthForNegative() throws {
    let (mgr, dir) = try managerWithFolder()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(throws: ExportDestinationManager.ExportDestinationError.invalidMonth) {
      try mgr.urlForMonth(year: 2025, month: -1)
    }
  }

  // MARK: - Happy path (valid year/month creates directory)

  @Test func urlForMonthCreatesYearMonthDirectory() throws {
    let (mgr, dir) = try managerWithFolder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let result = try mgr.urlForMonth(year: 2025, month: 6)
    #expect(result.lastPathComponent == "06")
    #expect(result.deletingLastPathComponent().lastPathComponent == "2025")
    var isDir: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: result.path, isDirectory: &isDir))
    #expect(isDir.boolValue)
  }

  /// Regression: issue #92. In 1.4, a saved bookmark to an unreachable path
  /// blocked the launch sequence on synchronous I/O — first the
  /// stale-bookmark refresh's `url.bookmarkData(...)` call, then the
  /// resource-key reads inside `validate(url:)`. The fix defers the
  /// refresh until validation confirms the URL is reachable, and bails out
  /// of validation when scope acquisition fails.
  ///
  /// This test reproduces the launch path with a real bookmark whose target
  /// folder is removed before restore. The behavioural pin: restore reports
  /// the destination as unavailable, and the stored bookmark bytes are not
  /// rewritten (proving the synchronous refresh was deferred).
  @Test func restoringBookmarkForMissingFolderDoesNotRewriteBookmark() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ExportDest-Issue92-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let suiteName = "ExportDestinationTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let bookmarkKey = "ExportDestinationBookmark-\(UUID().uuidString)"
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let writer = ExportDestinationManager(
      skipRestore: true,
      userDefaults: defaults,
      bookmarkDefaultsKey: bookmarkKey
    )
    writer.persistSelectedFolderForTesting(dir)
    let bookmarkBytesBefore = defaults.data(forKey: bookmarkKey)
    #expect(bookmarkBytesBefore != nil)

    try FileManager.default.removeItem(at: dir)

    let restored = ExportDestinationManager(
      userDefaults: defaults,
      bookmarkDefaultsKey: bookmarkKey
    )

    #expect(restored.isAvailable == false)
    #expect(restored.isWritable == false)
    #expect(restored.destinationId == nil)
    let bookmarkBytesAfter = defaults.data(forKey: bookmarkKey)
    #expect(bookmarkBytesBefore == bookmarkBytesAfter)
  }

  @Test func persistedBookmarkRestoresFolderAcrossManagerInstances() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ExportDestBookmark-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let suiteName = "ExportDestinationTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let bookmarkKey = "ExportDestinationBookmark-\(UUID().uuidString)"
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let writer = ExportDestinationManager(
      skipRestore: true,
      userDefaults: defaults,
      bookmarkDefaultsKey: bookmarkKey
    )
    writer.persistSelectedFolderForTesting(dir)

    let restored = ExportDestinationManager(
      userDefaults: defaults,
      bookmarkDefaultsKey: bookmarkKey
    )

    #expect(restored.selectedFolderURL?.standardizedFileURL == dir.standardizedFileURL)
    #expect(restored.canExportNow)
    #expect(restored.destinationId == writer.destinationId)

    let scopedURL = restored.beginScopedAccess()
    #expect(scopedURL?.standardizedFileURL == dir.standardizedFileURL)
    if let scopedURL {
      restored.endScopedAccess(for: scopedURL)
    }
  }
}
