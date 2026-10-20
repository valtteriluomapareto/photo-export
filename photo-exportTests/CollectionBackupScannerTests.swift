import Foundation
import Testing

@testable import Photo_Export

/// `BackupScanner.scanCollectionsFolder` reports every folder under `Collections/Favorites/`,
/// `Collections/Albums/` and `Collections/Shared Albums/` with its own files, and fails rather
/// than leaving part of the tree unread.
@Suite(.timeLimit(.minutes(2)))
struct CollectionBackupScannerTests {
  private func makeRoot() -> URL {
    TestScratch.directory("CollectionBackupScanner").resolvingSymlinksInPath()
  }

  private func write(_ root: URL, _ relativePath: String) throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("bytes".utf8).write(to: url)
  }

  private func filesByFolder(_ directories: [ScannedCollectionDirectory]) -> [String: [String]] {
    var result: [String: [String]] = [:]
    for directory in directories {
      result[directory.relativePath] = directory.files.map(\.filename)
    }
    return result
  }

  @Test func reportsFavoritesNestedAlbumsSharedAlbumsAndVideosFolders() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try write(root, "Collections/Favorites/FAV.JPG")
    try write(root, "Collections/Favorites/videos/FAV.MOV")
    try write(root, "Collections/Albums/Trips/2024/Rome/B.JPG")
    try write(root, "Collections/Albums/Trips/2024/Rome/A.JPG")
    try write(root, "Collections/Albums/Trips/2024/Rome/videos/R.MOV")
    try write(root, "Collections/Albums/Paris/P.HEIC")
    try write(root, "Collections/Shared Albums/Family/S.JPG")
    try write(root, "Collections/Shared Albums/Family/videos/S.MOV")
    try write(root, "Collections/Other/IGNORED.JPG")
    try write(root, "2025/01/TIMELINE.JPG")

    let scanned = try BackupScanner.scanCollectionsFolder(at: root)
    let folders = filesByFolder(scanned)

    #expect(folders["Collections/Favorites/"] == ["FAV.JPG"])
    #expect(folders["Collections/Favorites/videos/"] == ["FAV.MOV"])
    #expect(folders["Collections/Albums/Trips/"] == [])
    #expect(folders["Collections/Albums/Trips/2024/"] == [])
    #expect(folders["Collections/Albums/Trips/2024/Rome/"] == ["A.JPG", "B.JPG"])
    #expect(folders["Collections/Albums/Trips/2024/Rome/videos/"] == ["R.MOV"])
    #expect(folders["Collections/Albums/Paris/"] == ["P.HEIC"])
    #expect(folders["Collections/Shared Albums/Family/"] == ["S.JPG"])
    #expect(folders["Collections/Shared Albums/Family/videos/"] == ["S.MOV"])
    #expect(!folders.keys.contains { $0.hasPrefix("Collections/Other") })
    let rome = try #require(scanned.first { $0.components == ["Trips", "2024", "Rome"] })
    #expect(rome.root == .albums)
    #expect(rome.files.allSatisfy { $0.subfolder == nil && $0.modificationDate != nil })
    #expect(rome.files.first?.url.lastPathComponent == "A.JPG")
  }

  @Test func scanOfTheTimelineIsUnchangedByCollectionFolders() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try write(root, "Collections/Albums/Paris/P.HEIC")
    try write(root, "2025/01/TIMELINE.JPG")
    let timeline = try BackupScanner.scanBackupFolder(at: root)
    #expect(timeline.map(\.filename) == ["TIMELINE.JPG"])
  }

  @Test func missingCollectionsFolderOrRootsAreEmpty() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    #expect(try BackupScanner.scanCollectionsFolder(at: root).isEmpty)

    try write(root, "Collections/Albums/Paris/P.HEIC")
    let scanned = try BackupScanner.scanCollectionsFolder(at: root)
    #expect(scanned.allSatisfy { $0.root == .albums })
    #expect(filesByFolder(scanned)["Collections/Albums/Paris/"] == ["P.HEIC"])
  }

  @Test(arguments: ["Collections", "Collections/Albums", "Collections/Favorites"])
  func rootThatIsNotAFolderFails(path: String) throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try write(root, path)
    #expect(throws: BackupScanReadError.self) {
      _ = try BackupScanner.scanCollectionsFolder(at: root)
    }
  }

  @Test func symlinksAreNotFollowed() throws {
    let root = makeRoot()
    let elsewhere = TestScratch.directory("CollectionBackupScannerLinked")
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: elsewhere)
    }
    try write(elsewhere, "Linked/OUTSIDE.JPG")
    try write(root, "Collections/Albums/Real/R.JPG")
    let fm = FileManager.default
    try fm.createSymbolicLink(
      at: root.appendingPathComponent("Collections/Albums/Linked"),
      withDestinationURL: elsewhere.appendingPathComponent("Linked"))
    try fm.createSymbolicLink(
      at: root.appendingPathComponent("Collections/Albums/Real/LINK.JPG"),
      withDestinationURL: elsewhere.appendingPathComponent("Linked/OUTSIDE.JPG"))
    try fm.createSymbolicLink(
      at: root.appendingPathComponent("Collections/Shared Albums"),
      withDestinationURL: elsewhere)

    let folders = filesByFolder(try BackupScanner.scanCollectionsFolder(at: root))

    #expect(folders["Collections/Albums/Real/"] == ["R.JPG"])
    #expect(folders["Collections/Albums/Linked/"] == nil)
    #expect(!folders.keys.contains { $0.hasPrefix("Collections/Shared Albums") })
  }

  @Test func decomposedFolderNamesAreReportedAsSpelledOnDisk() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let decomposed = "Cafe\u{301}"
    try write(root, "Collections/Albums/\(decomposed)/C.JPG")
    let scanned = try BackupScanner.scanCollectionsFolder(at: root)
    let cafe = try #require(scanned.first { !$0.files.isEmpty })
    #expect(cafe.components.count == 1)
    // `String ==` compares canonically, so compare the scalars to see the raw spelling.
    #expect(Array(cafe.components[0].unicodeScalars) == Array(decomposed.unicodeScalars))
  }

  @Test func foldersNestedPastTheLimitFailTheScan() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let atLimit = Array(repeating: "n", count: BackupScanner.collectionsMaxDepth)
    try write(root, "Collections/Albums/" + atLimit.joined(separator: "/") + "/OK.JPG")
    let scanned = try BackupScanner.scanCollectionsFolder(at: root)
    #expect(scanned.contains { $0.components.count == atLimit.count && !$0.files.isEmpty })

    try write(root, "Collections/Albums/" + (atLimit + ["deeper"]).joined(separator: "/") + "/X.JPG")
    #expect(throws: BackupScanReadError.self) {
      _ = try BackupScanner.scanCollectionsFolder(at: root)
    }
  }

  // MARK: - Read failures and cancellation

  enum Failure: String, CaseIterable, Sendable {
    case collectionsType = "Collections"
    case albumsListing = "Collections/Albums"
    case nestedListing = "Collections/Albums/Trips"
    case sharedListing = "Collections/Shared Albums/Family"
    case favoritesType = "Collections/Favorites"
    case fileType = "Collections/Albums/Trips/Rome/A.JPG"

    var isMetadata: Bool { [.collectionsType, .favoritesType, .fileType].contains(self) }
  }

  final class Reader: BackupDirectoryReading, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private let real = ProductionBackupDirectoryReader()
    let failingPath: String?
    let failsMetadata: Bool
    let cancelAtPath: String?

    init(failingPath: String? = nil, failsMetadata: Bool = false, cancelAtPath: String? = nil) {
      self.failingPath = failingPath
      self.failsMetadata = failsMetadata
      self.cancelAtPath = cancelAtPath
    }

    var reads: [String] { lock.withLock { log } }

    private func record(_ entry: String, path: String) {
      lock.withLock { log.append(entry) }
      if path == cancelAtPath { withUnsafeCurrentTask { $0?.cancel() } }
    }

    func contentsOfDirectory(at url: URL, keys: [URLResourceKey]) throws -> [URL] {
      let path = url.resolvingSymlinksInPath().path
      record("list " + path, path: path)
      if !failsMetadata && path == failingPath {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTCONN))
      }
      return try real.contentsOfDirectory(at: url, keys: keys).sorted { $0.path < $1.path }
    }

    func resourceValues(at url: URL, keys: Set<URLResourceKey>) throws -> URLResourceValues {
      let path = url.resolvingSymlinksInPath().path
      record("stat " + path, path: path)
      if failsMetadata && path == failingPath {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
      }
      return try real.resourceValues(at: url, keys: keys)
    }
  }

  private func plantTree(at root: URL) throws {
    try write(root, "Collections/Favorites/FAV.JPG")
    try write(root, "Collections/Albums/Trips/Rome/A.JPG")
    try write(root, "Collections/Shared Albums/Family/S.JPG")
  }

  @Test(arguments: Failure.allCases)
  func unreadableFoldersAndFilesFailTheScan(failure: Failure) throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try plantTree(at: root)
    let reader = Reader(
      failingPath: root.appendingPathComponent(failure.rawValue).path,
      failsMetadata: failure.isMetadata)
    #expect(throws: BackupScanReadError.self) {
      _ = try BackupScanner.scanCollectionsFolder(at: root, directoryReader: reader)
    }
  }

  @Test func cancelledScanReadsNothingAfterTheCurrentEntry() async throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try plantTree(at: root)
    let held = root.appendingPathComponent("Collections/Albums/Trips").path
    let reader = Reader(cancelAtPath: held)

    let scan = Task { try BackupScanner.scanCollectionsFolder(at: root, directoryReader: reader) }
    let outcome = await scan.result

    let reads = reader.reads
    let heldIndex = try #require(reads.firstIndex { $0.hasSuffix(held) })
    #expect(reads.count == heldIndex + 1, "Read after cancellation: \(reads[heldIndex...])")
    guard case .failure(let error) = outcome else {
      Issue.record("A cancelled scan must not return folders")
      return
    }
    #expect(error is CancellationError)
  }
}
