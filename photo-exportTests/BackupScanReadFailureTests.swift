import Foundation
import Testing

@testable import Photo_Export

@Suite(.timeLimit(.minutes(2)))
struct BackupScanReadFailureTests {
  enum Failure: CaseIterable {
    case rootEnumeration, yearEnumeration, monthEnumeration, videosEnumeration
    case yearType, monthType, videosType, fileType

    var metadata: Bool {
      switch self {
      case .yearType, .monthType, .videosType, .fileType: true
      default: false
      }
    }

    var relativePath: String {
      switch self {
      case .rootEnumeration: ""
      case .yearEnumeration, .yearType: "2025"
      case .monthEnumeration, .monthType: "2025/03"
      case .videosEnumeration, .videosType: "2025/03/videos"
      case .fileType: "2025/03/FILE.JPG"
      }
    }
  }

  private final class Reader: BackupDirectoryReading, @unchecked Sendable {
    let failurePath: String
    let metadata: Bool
    private let lock = NSLock()
    private var reads: [String] = []
    private let real = ProductionBackupDirectoryReader()

    init(root: URL, failure: Failure) {
      failurePath =
        failure.relativePath.isEmpty
        ? root.path : root.appendingPathComponent(failure.relativePath).path
      metadata = failure.metadata
    }

    var directoriesRead: [String] { lock.withLock { reads } }

    func contentsOfDirectory(at url: URL, keys: [URLResourceKey]) throws -> [URL] {
      lock.withLock { reads.append(url.resolvingSymlinksInPath().path) }
      if !metadata && url.resolvingSymlinksInPath().path == failurePath {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTCONN))
      }
      return try real.contentsOfDirectory(at: url, keys: keys).sorted { $0.path < $1.path }
    }

    func resourceValues(at url: URL, keys: Set<URLResourceKey>) throws -> URLResourceValues {
      if metadata && url.resolvingSymlinksInPath().path == failurePath {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
      }
      return try real.resourceValues(at: url, keys: keys)
    }
  }

  private func plantBackup(at root: URL) throws {
    for path in ["2025/02", "2025/03", "2025/03/videos"] {
      let directory = root.appendingPathComponent(path)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data("bytes".utf8).write(to: directory.appendingPathComponent("FILE.JPG"))
    }
  }

  @Test(arguments: Failure.allCases)
  func recognizedBackupLookupFailuresAreExplicit(failure: Failure) throws {
    let root = TestScratch.directory("BackupScanReadFailure")
    defer { try? FileManager.default.removeItem(at: root) }
    try plantBackup(at: root)
    let reader = Reader(root: root, failure: failure)
    do {
      _ = try BackupScanner.scanBackupFolder(at: root, directoryReader: reader)
      Issue.record("Scan succeeded despite an unverifiable recognized backup path")
    } catch {
      #expect(
        error.localizedDescription.contains(
          failure == .rootEnumeration ? root.lastPathComponent : reader.failurePath))
    }
  }

  @MainActor
  @Test func unreadableMonthFailsImportBeforeHistoryChanges() async throws {
    let destination = FakeExportDestination()
    let root = TestScratch.directory("BackupScanReadFailure")
    let defaultsName = TestScratch.suiteName("BackupScanFailure")
    defer {
      destination.cleanup()
      try? FileManager.default.removeItem(at: root)
    }
    try plantBackup(at: destination.rootURL)
    let reader = Reader(root: destination.rootURL, failure: .monthEnumeration)
    let timeline = ExportRecordStore(baseDirectoryURL: root)
    let collections = CollectionExportRecordStore(baseDirectoryURL: root)
    timeline.configure(for: "A")
    collections.configure(for: "A")
    timeline.markVariantExported(
      assetId: "history", variant: .original, year: 2025, month: 3, relPath: "2025/03/",
      filename: "HISTORY.JPG", exportedAt: Date(timeIntervalSince1970: 1_700_000_000))
    collections.upsertPlacement(.favorites())
    collections.markVariantExported(
      assetId: "history", placement: .favorites(), variant: .original,
      filename: "HISTORY.JPG", exportedAt: Date(timeIntervalSince1970: 1_700_000_000))
    try await timeline.flush()
    try await collections.flush()
    let beforeTimeline = timeline.recordsById
    let beforeCollections = collections.recordBodies
    let manager = ExportManager(
      photoLibraryService: FakePhotoLibraryService(), exportDestination: destination,
      exportRecordStore: timeline, collectionExportRecordStore: collections,
      backupDirectoryReader: reader, userDefaults: TestScratch.defaults(suiteName: defaultsName))
    manager.startImport()
    await manager.waitForImportCompletion()
    #expect(manager.importError?.contains(reader.failurePath) == true)
    #expect(manager.importResult == nil)
    #expect(!manager.isImporting)
    #expect(timeline.recordsById == beforeTimeline)
    #expect(collections.recordBodies == beforeCollections)
    #expect(
      reader.directoriesRead.contains(
        destination.rootURL.appendingPathComponent("2025/02").resolvingSymlinksInPath().path))
    try await timeline.flush()
    try await collections.flush()
    let freshTimeline = ExportRecordStore(baseDirectoryURL: root)
    let freshCollections = CollectionExportRecordStore(baseDirectoryURL: root)
    freshTimeline.configure(for: "A")
    freshCollections.configure(for: "A")
    #expect(freshTimeline.recordsById == beforeTimeline)
    #expect(freshCollections.recordBodies == beforeCollections)
    #expect(destination.beginScopedAccessCount == 1 && destination.endScopedAccessCount == 1)
  }
}
