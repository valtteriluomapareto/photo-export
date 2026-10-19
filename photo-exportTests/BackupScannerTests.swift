import Foundation
import Testing

@testable import Photo_Export

struct BackupScannerTests {

  // MARK: - Collision suffix stripping

  @Test func stripCollisionSuffix_noSuffix() {
    let (stripped, had) = BackupScanner.stripCollisionSuffix(from: "IMG_0001")
    #expect(stripped == "IMG_0001")
    #expect(had == false)
  }

  @Test func stripCollisionSuffix_singleDigit() {
    let (stripped, had) = BackupScanner.stripCollisionSuffix(from: "IMG_0001 (1)")
    #expect(stripped == "IMG_0001")
    #expect(had == true)
  }

  @Test func stripCollisionSuffix_multiDigit() {
    let (stripped, had) = BackupScanner.stripCollisionSuffix(from: "IMG_0001 (12)")
    #expect(stripped == "IMG_0001")
    #expect(had == true)
  }

  @Test func stripCollisionSuffix_parenthesesInMiddle() {
    // "(1)" in the middle is not the suffix pattern - must be at end
    let (stripped, had) = BackupScanner.stripCollisionSuffix(from: "Photo (1) edit")
    #expect(stripped == "Photo (1) edit")
    #expect(had == false)
  }

  @Test func stripCollisionSuffix_noSpaceBefore() {
    // Must have space before the parenthesis
    let (stripped, had) = BackupScanner.stripCollisionSuffix(from: "IMG_0001(1)")
    #expect(stripped == "IMG_0001(1)")
    #expect(had == false)
  }

  // MARK: - Media type inference

  @Test func mediaType_image() {
    #expect(BackupScanner.mediaType(for: "jpg") == .image)
    #expect(BackupScanner.mediaType(for: "JPG") == .image)
    #expect(BackupScanner.mediaType(for: "heic") == .image)
    #expect(BackupScanner.mediaType(for: "png") == .image)
    #expect(BackupScanner.mediaType(for: "dng") == .image)
  }

  @Test func mediaType_video() {
    #expect(BackupScanner.mediaType(for: "mov") == .video)
    #expect(BackupScanner.mediaType(for: "MOV") == .video)
    #expect(BackupScanner.mediaType(for: "mp4") == .video)
    #expect(BackupScanner.mediaType(for: "m4v") == .video)
  }

  @Test func mediaType_unknown() {
    #expect(BackupScanner.mediaType(for: "txt") == .unknown)
    #expect(BackupScanner.mediaType(for: "pdf") == .unknown)
    #expect(BackupScanner.mediaType(for: "") == .unknown)
  }

  // MARK: - Backup folder scanning

  @Test func scanBackupFolder_emptyFolder() throws {
    let root = makeTempDir()
    defer { cleanup(root) }

    let results = try BackupScanner.scanBackupFolder(at: root)
    #expect(results.isEmpty)
  }

  @Test func scanBackupFolder_validYYYYMMStructure() throws {
    let root = makeTempDir()
    defer { cleanup(root) }

    // Create YYYY/MM/ structure with files
    let monthDir = root.appendingPathComponent("2024/03", isDirectory: true)
    try FileManager.default.createDirectory(
      at: monthDir, withIntermediateDirectories: true)
    FileManager.default.createFile(
      atPath: monthDir.appendingPathComponent("IMG_0001.jpg").path, contents: Data([0xFF]))
    FileManager.default.createFile(
      atPath: monthDir.appendingPathComponent("IMG_0002 (1).heic").path, contents: Data([0xFF]))

    let results = try BackupScanner.scanBackupFolder(at: root)
    #expect(results.count == 2)

    let file1 = results.first { $0.filename == "IMG_0001.jpg" }
    #expect(file1 != nil)
    #expect(file1?.year == 2024)
    #expect(file1?.month == 3)
    #expect(file1?.baseFilename == "IMG_0001.jpg")
    #expect(file1?.hasCollisionSuffix == false)
    #expect(file1?.fileExtension == "jpg")

    let file2 = results.first { $0.filename == "IMG_0002 (1).heic" }
    #expect(file2 != nil)
    #expect(file2?.baseFilename == "IMG_0002.heic")
    #expect(file2?.hasCollisionSuffix == true)
  }

  @Test func scanBackupFolder_ignoresInvalidMonths() throws {
    let root = makeTempDir()
    defer { cleanup(root) }

    // Valid
    let validDir = root.appendingPathComponent("2024/06", isDirectory: true)
    try FileManager.default.createDirectory(at: validDir, withIntermediateDirectories: true)
    FileManager.default.createFile(
      atPath: validDir.appendingPathComponent("valid.jpg").path, contents: Data([0xFF]))

    // Invalid month: 13
    let invalidDir = root.appendingPathComponent("2024/13", isDirectory: true)
    try FileManager.default.createDirectory(at: invalidDir, withIntermediateDirectories: true)
    FileManager.default.createFile(
      atPath: invalidDir.appendingPathComponent("invalid.jpg").path, contents: Data([0xFF]))

    // Invalid month: 00
    let zeroDir = root.appendingPathComponent("2024/00", isDirectory: true)
    try FileManager.default.createDirectory(at: zeroDir, withIntermediateDirectories: true)
    FileManager.default.createFile(
      atPath: zeroDir.appendingPathComponent("zero.jpg").path, contents: Data([0xFF]))

    let results = try BackupScanner.scanBackupFolder(at: root)
    #expect(results.count == 1)
    #expect(results[0].filename == "valid.jpg")
  }

  @Test func scanBackupFolder_ignoresInvalidYears() throws {
    let root = makeTempDir()
    defer { cleanup(root) }

    // Invalid year: "abc"
    let invalidDir = root.appendingPathComponent("abc/01", isDirectory: true)
    try FileManager.default.createDirectory(at: invalidDir, withIntermediateDirectories: true)
    FileManager.default.createFile(
      atPath: invalidDir.appendingPathComponent("photo.jpg").path, contents: Data([0xFF]))

    // Invalid year: "20" (too short)
    let shortDir = root.appendingPathComponent("20/01", isDirectory: true)
    try FileManager.default.createDirectory(at: shortDir, withIntermediateDirectories: true)
    FileManager.default.createFile(
      atPath: shortDir.appendingPathComponent("photo.jpg").path, contents: Data([0xFF]))

    let results = try BackupScanner.scanBackupFolder(at: root)
    #expect(results.isEmpty)
  }

  @Test func scanBackupFolder_ignoresHiddenFiles() throws {
    let root = makeTempDir()
    defer { cleanup(root) }

    let monthDir = root.appendingPathComponent("2024/01", isDirectory: true)
    try FileManager.default.createDirectory(at: monthDir, withIntermediateDirectories: true)
    FileManager.default.createFile(
      atPath: monthDir.appendingPathComponent(".DS_Store").path, contents: Data([0xFF]))
    FileManager.default.createFile(
      atPath: monthDir.appendingPathComponent("visible.jpg").path, contents: Data([0xFF]))

    let results = try BackupScanner.scanBackupFolder(at: root)
    #expect(results.count == 1)
    #expect(results[0].filename == "visible.jpg")
  }

  @Test func scanBackupFolder_multipleYearsAndMonths() throws {
    let root = makeTempDir()
    defer { cleanup(root) }

    for (year, month, file) in [
      ("2023", "11", "a.jpg"), ("2023", "12", "b.mov"), ("2024", "01", "c.heic"),
    ] {
      let dir = root.appendingPathComponent("\(year)/\(month)", isDirectory: true)
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      FileManager.default.createFile(
        atPath: dir.appendingPathComponent(file).path, contents: Data([0xFF]))
    }

    let results = try BackupScanner.scanBackupFolder(at: root)
    #expect(results.count == 3)
  }

  // MARK: - Bulk import (ExportRecordStore)

  @MainActor
  @Test func bulkImportRecords_addsNewRecords() {
    let tempDir = makeTempDir()
    defer { cleanup(tempDir) }
    let store = ExportRecordStore(baseDirectoryURL: tempDir)
    store.configure(for: "test")

    let records = [
      ExportRecord(
        id: "asset-1", year: 2024, month: 3, relPath: "2024/03/",
        variants: [
          .original: ExportVariantRecord(
            filename: "IMG_0001.jpg", status: .done, exportDate: Date(), lastError: nil)
        ]),
      ExportRecord(
        id: "asset-2", year: 2024, month: 3, relPath: "2024/03/",
        variants: [
          .original: ExportVariantRecord(
            filename: "IMG_0002.jpg", status: .done, exportDate: Date(), lastError: nil)
        ]),
    ]
    store.bulkImportRecords(records)
    store.flushForTesting()

    #expect(store.isExported(assetId: "asset-1"))
    #expect(store.isExported(assetId: "asset-2"))
    #expect(store.monthSummary(year: 2024, month: 3, totalAssets: 10).exportedCount == 2)
  }

  @MainActor
  @Test func bulkImportRecords_skipsExistingDoneRecords() {
    let tempDir = makeTempDir()
    defer { cleanup(tempDir) }
    let store = ExportRecordStore(baseDirectoryURL: tempDir)
    store.configure(for: "test")

    // Pre-existing record
    store.markExported(
      assetId: "asset-1", year: 2024, month: 3, relPath: "2024/03/",
      filename: "original.jpg", exportedAt: Date())
    store.flushForTesting()

    // Import tries to overwrite
    let records = [
      ExportRecord(
        id: "asset-1", year: 2024, month: 3, relPath: "2024/03/",
        variants: [
          .original: ExportVariantRecord(
            filename: "different.jpg", status: .done, exportDate: Date(), lastError: nil)
        ])
    ]
    store.bulkImportRecords(records)
    store.flushForTesting()

    // Original should be preserved
    #expect(
      store.exportInfo(assetId: "asset-1")?.variants[.original]?.filename == "original.jpg")
  }

  @MainActor
  @Test func bulkImportRecords_overwritesNonDoneRecords() {
    let tempDir = makeTempDir()
    defer { cleanup(tempDir) }
    let store = ExportRecordStore(baseDirectoryURL: tempDir)
    store.configure(for: "test")

    // Pre-existing failed record
    store.markFailed(assetId: "asset-1", error: "network", at: Date())
    store.flushForTesting()

    let records = [
      ExportRecord(
        id: "asset-1", year: 2024, month: 3, relPath: "2024/03/",
        variants: [
          .original: ExportVariantRecord(
            filename: "imported.jpg", status: .done, exportDate: Date(), lastError: nil)
        ])
    ]
    store.bulkImportRecords(records)
    store.flushForTesting()

    // Should be overwritten since the previous status was .failed
    #expect(
      store.exportInfo(assetId: "asset-1")?.variants[.original]?.status == .done)
    #expect(
      store.exportInfo(assetId: "asset-1")?.variants[.original]?.filename == "imported.jpg")
  }

  // MARK: - Helpers

  private func makeTempDir() -> URL {
    let url = TestScratch.directory("BackupScanner")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }
}
