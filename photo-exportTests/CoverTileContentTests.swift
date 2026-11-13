import AppKit
import Testing

@testable import Photo_Export

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CoverTileContentTests {
  private func image() throws -> CGImage {
    let context = try #require(
      CGContext(
        data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    return try #require(context.makeImage())
  }

  enum CancelPoint: CaseIterable { case query, failingQuery, imageDecode }

  /// A consumer cancelled while its query or image decode is suspended finishes without a
  /// publishable value, even when the query then fails or the image then arrives.
  @Test(arguments: CancelPoint.allCases)
  func canceledConsumerReturnsNoValue(at point: CancelPoint) async throws {
    let service = FakePhotoLibraryService()
    let gate = AsyncCheckpoint()
    let image = try image()
    service.assetsByAlbumLocalId["A"] = [TestAssetFactory.makeAsset(id: "old")]
    switch point {
    case .query: service.fetchAssetsCheckpointByAlbumId["A"] = gate
    case .failingQuery:
      service.fetchAssetsCheckpointByAlbumId["A"] = gate
      service.fetchAssetsErrorByAlbumId["A"] = CocoaError(.fileReadUnknown)
    case .imageDecode:
      service.decodedThumbnailOverride = { _, _, _ in
        await gate.enter()
        return image
      }
    }
    let consumer = Task {
      await CoverTileContent.load(
        scope: .album(collectionId: "A"), service: service, side: 180, displayScale: 2)
    }
    try await withCleanup {
      try #require(await gate.waitForEnter(count: 1))
      consumer.cancel()
      await gate.releaseAll()
      #expect(await consumer.value == nil)
      #expect(service.decodedThumbnailCalls.count == (point == .imageDecode ? 1 : 0))
    } cleanup: {
      consumer.cancel()
      await gate.releaseAll()
      _ = await consumer.value
    }
  }

  @Test func partialImagesKeepSourceOrderDespiteOutOfOrderCompletion() async throws {
    let service = FakePhotoLibraryService()
    let gate = AsyncCheckpoint()
    let ids = ["first", "missing", "third", "fourth", "fifth"]
    let images = try [image(), image(), image()]
    let supplied = ["first": images[0], "third": images[1], "fourth": images[2]]
    service.assetsByAlbumLocalId["A"] = ids.enumerated().map { index, id in
      TestAssetFactory.makeAsset(id: id, creationDate: Date(timeIntervalSince1970: Double(index)))
    }
    var completed: [String] = []
    var sizes: [CGSize] = []
    service.decodedThumbnailOverride = { id, size, _ in
      sizes.append(size)
      if id == "first" { await gate.enter() }
      completed.append(id)
      return supplied[id]
    }
    let consumer = Task {
      await CoverTileContent.load(
        scope: .album(collectionId: "A"), service: service, side: 180, displayScale: 2)
    }
    try await withCleanup {
      try #require(await gate.waitForEnter(count: 1))
      try #require(
        await eventually("later source images finish before first") {
          completed.contains("third") && completed.contains("fourth")
        })
      await gate.releaseAll()
      guard case .images(let loaded) = try #require(await consumer.value) else {
        Issue.record("Partially available images must still produce a cover")
        return
      }
      #expect(loaded.count == 3)
      #expect(zip(loaded, images).allSatisfy { $0 === $1 })
      #expect(completed.last == "first")
      #expect(Set(service.decodedThumbnailCalls.map(\.assetId)) == Set(ids.prefix(4)))
      #expect(service.decodedThumbnailCalls.allSatisfy { $0.deliveryMode == .highQuality })
      #expect(sizes == Array(repeating: CGSize(width: 360, height: 360), count: 4))
    } cleanup: {
      consumer.cancel()
      await gate.releaseAll()
      _ = await consumer.value
    }
  }

  @Test func captionsAndAccessibleStatesPreserveMonthAndCollectionRules() {
    #expect(CoverTileFormatting.photoCount(nil) == " ")
    #expect(CoverTileFormatting.photoCount(1) == "1 photo")
    #expect(
      CoverTileFormatting.caption(kind: .folder, photoCount: 3, albumCount: 1)
        == "1 album · 3 photos")
    #expect(CoverTileFormatting.caption(kind: .folder, photoCount: 0, albumCount: 2) == "2 albums")
    #expect(CoverTileFormatting.caption(kind: .sharedAlbum, photoCount: 3, albumCount: 0) == " ")
    #expect(
      CoverTileFormatting.label(
        prefix: ["Month", "January 2026"], photoCount: 1, exported: true, content: .loading)
        == "Month, January 2026, 1 photo, fully exported, Loading preview")
    #expect(
      CoverTileFormatting.label(
        prefix: ["Album", "Trip"], photoCount: nil, exported: false, content: .failed)
        == "Album, Trip, Couldn't load preview")
  }
}
