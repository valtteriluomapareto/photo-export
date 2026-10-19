import Foundation
import Testing

@testable import Photo_Export

/// Cancelling the backup scan stops it at its next directory or file entry. A read in
/// progress finishes; nothing after it is read.
@Suite(.timeLimit(.minutes(2)))
struct BackupScanCancellationTests {
  /// The read on which the scan's caller is cancelled.
  enum HoldPoint: CaseIterable, Sendable {
    case rootListing, yearListing, monthListing, lastFileOfMonth

    func matches(_ read: Read, root: URL) -> Bool {
      switch self {
      case .rootListing: read == .contents(root.path)
      case .yearListing: read == .contents(root.appendingPathComponent("2025").path)
      case .monthListing: read == .contents(root.appendingPathComponent("2025/02").path)
      case .lastFileOfMonth:
        read == .values(root.appendingPathComponent("2025/02/FILE.JPG").path)
      }
    }
  }

  enum Read: Equatable, Sendable {
    case contents(String)
    case values(String)
  }

  /// Records every read in order and runs `onHold` on the first read that matches.
  final class RecordingReader: BackupDirectoryReading, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [Read] = []
    private var held = false
    private let real = ProductionBackupDirectoryReader()
    private let shouldHold: @Sendable (Read) -> Bool
    private let onHold: @Sendable () -> Void

    init(
      shouldHold: @escaping @Sendable (Read) -> Bool = { _ in false },
      onHold: @escaping @Sendable () -> Void = {}
    ) {
      self.shouldHold = shouldHold
      self.onHold = onHold
    }

    var reads: [Read] { lock.withLock { log } }

    private func record(_ read: Read) {
      let hold = lock.withLock {
        log.append(read)
        guard !held, shouldHold(read) else { return false }
        held = true
        return true
      }
      if hold { onHold() }
    }

    func contentsOfDirectory(at url: URL, keys: [URLResourceKey]) throws -> [URL] {
      record(.contents(url.resolvingSymlinksInPath().path))
      return try real.contentsOfDirectory(at: url, keys: keys).sorted { $0.path < $1.path }
    }

    func resourceValues(at url: URL, keys: Set<URLResourceKey>) throws -> URLResourceValues {
      record(.values(url.resolvingSymlinksInPath().path))
      return try real.resourceValues(at: url, keys: keys)
    }
  }

  static func plantBackup(at root: URL) throws {
    for path in ["2025/02", "2025/03", "2025/03/videos"] {
      let directory = root.appendingPathComponent(path)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data("bytes".utf8).write(to: directory.appendingPathComponent("FILE.JPG"))
    }
  }

  @Test(arguments: HoldPoint.allCases)
  func cancelledScanReadsNothingAfterTheCurrentEntry(hold: HoldPoint) async throws {
    let root = TestScratch.directory("BackupScanCancellation")
      .resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    try Self.plantBackup(at: root)
    let reader = RecordingReader(
      shouldHold: { hold.matches($0, root: root) },
      onHold: { withUnsafeCurrentTask { $0?.cancel() } })

    let scan = Task { try BackupScanner.scanBackupFolder(at: root, directoryReader: reader) }
    let outcome = await scan.result

    let reads = reader.reads
    let heldIndex = try #require(reads.firstIndex { hold.matches($0, root: root) })
    #expect(reads.count == heldIndex + 1, "Read after cancellation: \(reads[heldIndex...])")
    guard case .failure(let error) = outcome else {
      Issue.record("A cancelled scan must not return files")
      return
    }
    #expect(error is CancellationError)
  }

  @MainActor
  @Test func cancellingImportStopsTheBackupScan() async throws {
    let full = try await importReads(cancelAtMonthListing: false)
    let cancelled = try await importReads(cancelAtMonthListing: true)
    #expect(cancelled.reads.last == cancelled.monthListing, "Nothing is read after the hold")
    #expect(cancelled.reads.count < full.reads.count)
  }

  /// Runs an import over a planted backup and returns the scan's reads. When cancelling,
  /// the reader cancels the import from the main queue on the 2025/02 listing.
  @MainActor
  private func importReads(
    cancelAtMonthListing cancel: Bool
  ) async throws -> (reads: [Read], monthListing: Read) {
    let destination = FakeExportDestination()
    let storeRoot = TestScratch.directory("BackupScanCancellation")
    let defaultsName = TestScratch.suiteName("BackupScanCancel")
    defer {
      destination.cleanup()
      try? FileManager.default.removeItem(at: storeRoot)
    }
    let root = destination.rootURL.resolvingSymlinksInPath()
    try Self.plantBackup(at: root)
    let monthListing = Read.contents(root.appendingPathComponent("2025/02").path)
    let timeline = ExportRecordStore(baseDirectoryURL: storeRoot)
    let collections = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    timeline.configure(for: "A")
    collections.configure(for: "A")
    defer {
      timeline.flushForTesting()
      collections.flushForTesting()
    }
    nonisolated(unsafe) var manager: ExportManager?
    let reader = RecordingReader(
      shouldHold: { cancel && $0 == monthListing },
      onHold: { DispatchQueue.main.sync { MainActor.assumeIsolated { manager?.cancelImport() } } })
    let created = ExportManager(
      photoLibraryService: FakePhotoLibraryService(), exportDestination: destination,
      exportRecordStore: timeline, collectionExportRecordStore: collections,
      backupDirectoryReader: reader, userDefaults: TestScratch.defaults(suiteName: defaultsName))
    manager = created
    defer { manager = nil }  // The reader's closure would otherwise keep the manager alive.
    created.startImport()
    let task = try #require(created.importTask)
    let settled = await finished(task)
    try #require(settled)
    #expect(!created.isImporting)
    #expect(created.importError == nil)
    if cancel { #expect(created.importStage == nil && created.importResult == nil) }
    #expect(destination.beginScopedAccessCount == destination.endScopedAccessCount)
    return (reader.reads, monthListing)
  }
}
