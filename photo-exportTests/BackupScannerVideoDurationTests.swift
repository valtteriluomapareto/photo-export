import Foundation
import Testing

@testable import Photo_Export

@MainActor
struct BackupScannerVideoDurationTests {
  private let filename = "black-2s.mp4"
  private let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
  private var secondDate: Date { firstDate.addingTimeInterval(60) }

  private var video: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("test-fixtures/backup-video-duration")
      .appendingPathComponent(filename)
  }

  private func match(
    _ url: URL, modificationDate: Date? = nil, cancelBeforeMetadata: Bool = false
  ) async throws -> BackupScanner.MatchResult {
    let assets = [
      TestAssetFactory.makeAsset(
        id: "short", creationDate: firstDate, mediaType: .video, duration: 2),
      TestAssetFactory.makeAsset(
        id: "long", creationDate: secondDate, mediaType: .video, duration: 8),
    ]
    let library = FakePhotoLibraryService()
    for asset in assets {
      library.resourcesByAssetId[asset.id] = [
        TestAssetFactory.makeResource(type: .video, originalFilename: filename)
      ]
    }
    let file = BackupScanner.ScannedFile(
      url: url, year: 0, month: 0, filename: filename, baseFilename: filename,
      hasCollisionSuffix: false, fileExtension: "mp4", modificationDate: modificationDate,
      fileSize: nil)
    return try await BackupScanner.matchGroup(
      [file], fingerprints: BackupScanner.buildFingerprints(for: assets, using: library),
      assetById: Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
    ) { _ in
      if cancelBeforeMetadata { withUnsafeCurrentTask { $0?.cancel() } }
    }
  }

  @Test func videoDurationBreaksAnAmbiguousFilenameMatch() async throws {
    let result = try await match(video)
    #expect(result.matched.map(\.asset.id) == ["short"])
    #expect(result.ambiguous.isEmpty)
  }

  @Test func uniqueDateMatchTakesPrecedenceOverVideoDuration() async throws {
    let result = try await match(video, modificationDate: secondDate)
    #expect(result.matched.map(\.asset.id) == ["long"])
    #expect(result.ambiguous.isEmpty)
  }

  @Test func unreadableVideoLeavesCandidatesAmbiguous() async throws {
    let root = TestScratch.directory("UnreadableBackupVideo")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let unreadable = root.appendingPathComponent(filename)
    try Data("not a video".utf8).write(to: unreadable)

    let result = try await match(unreadable)
    #expect(result.matched.isEmpty)
    #expect(result.ambiguous.map(\.url) == [unreadable])
  }

  @Test func cancellationBeforeMetadataPropagatesForTheLastFile() async {
    let task = Task {
      _ = try await match(video, cancelBeforeMetadata: true)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
  }
}
