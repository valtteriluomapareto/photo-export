import AVFoundation
import Foundation
import Photos
import Testing

@testable import Photo_Export

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TestFakeBehaviorTests {
  private func date(_ year: Int, _ month: Int, _ day: Int = 1) -> Date {
    Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
  }

  @Test func readingThumbnailReaderDoesNotRetainTheLibrary() {
    weak var released: FakePhotoLibraryService?
    autoreleasepool {
      let service = FakePhotoLibraryService()
      released = service
      _ = service.thumbnailReader
    }
    #expect(released == nil)
  }

  @Test func thumbnailDefaultsAreVisibleToTheCallRecorder() async {
    let service = RecordingPhotoLibraryService()
    let resolved = await service.resolveThumbnailAssets(ids: ["thumbnail"])
    #expect(resolved.isEmpty)
    #expect(!service.calls.isEmpty)
  }

  @Test func timelineUsesCreationDatesRatherThanBucketKeys() async throws {
    let service = FakePhotoLibraryService()
    service.assetsByYearMonth["2025-1"] = [
      TestAssetFactory.makeAsset(id: "late", creationDate: date(2025, 6, 20), hasAdjustments: true)
    ]
    service.assetsByYearMonth["2025-6"] = [
      TestAssetFactory.makeAsset(id: "next-month", creationDate: date(2025, 7)),
      TestAssetFactory.makeAsset(id: "no-date", creationDate: nil),
      TestAssetFactory.makeAsset(id: "early", creationDate: date(2025, 6)),
      TestAssetFactory.makeAsset(id: "old-year", creationDate: date(2024, 6)),
      TestAssetFactory.makeAsset(id: "next-year", creationDate: date(2026, 1)),
    ]
    let scope = PhotoFetchScope.timeline(year: 2025, month: 6)
    #expect(
      try await service.fetchAssets(in: scope, mediaType: nil).map(\.id) == ["early", "late"])
    #expect(
      try await service.fetchAssets(in: scope, mediaType: .video).isEmpty)
    #expect(try service.countAssets(year: 2025, month: 6) == 2)
    #expect(try await service.countAssets(in: scope) == 2)
    #expect(try await service.countAdjustedAssets(in: scope) == 1)
    #expect(
      try await service.fetchAssets(year: 2025, month: nil, mediaType: nil).map(\.id)
        == ["early", "late", "next-month"])
    #expect(try service.countAssets(year: 2025) == 3)
    #expect(try await service.countAdjustedAssets(year: 2025) == 1)
    var streamed: [String] = []
    for try await batch in service.fetchAssetsProgressive(in: scope, mediaType: nil, batchSize: 1) {
      streamed += batch.map(\.id)
    }
    #expect(streamed == ["early", "late"])
  }

  @Test(arguments: [
    PhotoFetchScope.favorites, .album(collectionId: "album"), .sharedAlbum(collectionId: "shared"),
  ])
  func collectionsSortByDateAndKeepTheirMembership(scope: PhotoFetchScope) async throws {
    let service = FakePhotoLibraryService()
    let assets = [
      TestAssetFactory.makeAsset(id: "video", creationDate: date(2025, 7), mediaType: .video),
      TestAssetFactory.makeAsset(id: "late", creationDate: date(2025, 6, 20)),
      TestAssetFactory.makeAsset(id: "early", creationDate: date(2024, 6)),
    ]
    service.favoritesAssets = assets
    service.assetsByAlbumLocalId["album"] = assets
    service.assetsBySharedAlbumLocalId["shared"] = assets
    #expect(
      try await service.fetchAssets(in: scope, mediaType: nil).map(\.id)
        == ["early", "late", "video"])
    #expect(
      try await service.fetchAssets(in: scope, mediaType: .image).map(\.id) == ["early", "late"])
    #expect(try await service.countAssets(in: scope) == 3)
    var streamed: [String] = []
    for try await batch in service.fetchAssetsProgressive(
      in: scope, mediaType: .image, batchSize: 1)
    {
      streamed += batch.map(\.id)
    }
    #expect(streamed == ["early", "late"])
  }

  @Test(arguments: ["", "/absolute", ".", "..", "a/../b", "a//b", "a/./b"], [false, true])
  func destinationRejectsInvalidComponents(path: String, create: Bool) throws {
    let destination = FakeExportDestination()
    defer { destination.cleanup() }
    #expect(throws: ExportDestinationManager.ExportDestinationError.self) {
      try destination.urlForRelativeDirectory(path, createIfNeeded: create)
    }
  }

  @Test(arguments: [false, true])
  func destinationRejectsSymlinkEscapeAndRegularFileParents(create: Bool) throws {
    let destination = FakeExportDestination()
    let outside = destination.rootURL.deletingLastPathComponent()
      .appendingPathComponent(destination.rootURL.lastPathComponent + "-sibling")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer {
      destination.cleanup()
      try? FileManager.default.removeItem(at: outside)
    }
    try FileManager.default.createSymbolicLink(
      at: destination.rootURL.appendingPathComponent("escape"), withDestinationURL: outside)
    #expect(throws: ExportDestinationManager.ExportDestinationError.self) {
      try destination.urlForRelativeDirectory("escape/missing/child/", createIfNeeded: create)
    }
    #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("missing").path))
    let file = destination.rootURL.appendingPathComponent("file")
    try Data("file".utf8).write(to: file)
    #expect(throws: ExportDestinationManager.ExportDestinationError.self) {
      try destination.urlForRelativeDirectory("file/child", createIfNeeded: create)
    }
    #expect(throws: ExportDestinationManager.ExportDestinationError.self) {
      try destination.urlForRelativeDirectory(
        String(repeating: "a/", count: 600), createIfNeeded: create)
    }
  }

  @Test func destinationAcceptsTrailingSlashAndInRootSymlink() throws {
    let destination = FakeExportDestination()
    defer { destination.cleanup() }
    let nested = try destination.urlForRelativeDirectory("a/b/", createIfNeeded: true)
    #expect(FileManager.default.fileExists(atPath: nested.path))
    try FileManager.default.createSymbolicLink(
      at: destination.rootURL.appendingPathComponent("inside"),
      withDestinationURL: destination.rootURL.appendingPathComponent("a"))
    let linked = try destination.urlForRelativeDirectory("inside/c/", createIfNeeded: true)
    #expect(FileManager.default.fileExists(atPath: linked.path))
  }

  @Test func writerReadsChangedConfigurationAfterCheckpoint() async throws {
    let writer = FakeAssetResourceWriter()
    let checkpoint = AsyncCheckpoint()
    writer.checkpoint = checkpoint
    let root = TestScratch.directory("fake-writer-config")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent(".photo-export-config.tmp")
    let resource = TestAssetFactory.makeResource()
    let task = Task.detached {
      try await writer.writeResource(resource, forAssetId: "asset", to: url)
    }
    try await withCleanup {
      try #require(await checkpoint.waitForEnter(count: 1))
      writer.writeError = CocoaError(.fileWriteOutOfSpace)
      await checkpoint.releaseAll()
      await #expect(throws: CocoaError(.fileWriteOutOfSpace)) { try await task.value }
      #expect(!FileManager.default.fileExists(atPath: url.path))
    } cleanup: {
      await checkpoint.releaseAll()
      _ = await task.result
    }
  }

  @Test func converterReadsChangedConfigurationAfterCheckpoint() async throws {
    let converter = FakeImageConverter()
    let checkpoint = AsyncCheckpoint()
    converter.beforeConvertCheckpoint = checkpoint
    let root = TestScratch.directory("fake-converter-config")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.HEIC")
    let target = root.appendingPathComponent("target.JPG")
    let task = Task.detached {
      try await converter.convertHEIC(at: source, to: target, quality: 0.9)
    }
    try await withCleanup {
      try #require(await checkpoint.waitForEnter(count: 1))
      converter.shouldCreateFile = false
      await checkpoint.releaseAll()
      try await task.value
      #expect(converter.convertCalls.count == 1)
      #expect(!FileManager.default.fileExists(atPath: target.path))
    } cleanup: {
      await checkpoint.releaseAll()
      _ = await task.result
    }
  }

  @Test func videoExecutorTracksConcurrentRequestsAndCancellation() async throws {
    let executor = FakeVideoExportExecutor()
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<100 {
        group.addTask {
          let request = MediaRenderRequest(
            assetId: "asset-\(index)", originalFilename: "VIDEO.MOV", fileType: .mov, kind: .video)
          let session = try await executor.requestSession(for: request)
          for _ in 0..<100 { executor.cancel(session: session) }
        }
      }
      try await group.waitForAll()
    }
    #expect(executor.requestCalls.count == 100)
    #expect(Set(executor.requestCalls.map(\.assetId)).count == 100)
    #expect(executor.cancelCount == 10_000)
    #expect(executor.runCalls.isEmpty)
  }

  @Test func filesystemHookCanChangeTheCurrentOperationWithoutDeadlock() throws {
    let fileSystem = FakeFileSystem()
    fileSystem.beforeMoveHook = { [fileSystem] _, _ in
      fileSystem.moveError = CocoaError(.fileWriteOutOfSpace)
    }
    defer { fileSystem.beforeMoveHook = nil }
    let root = TestScratch.directory("fake-hook-config")
    #expect(throws: CocoaError(.fileWriteOutOfSpace)) {
      try fileSystem.moveItemAtomically(
        from: root.appendingPathComponent("source"), to: root.appendingPathComponent("target"))
    }
    #expect(fileSystem.moveCalls.count == 1)
  }
}
