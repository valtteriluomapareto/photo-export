#if DEBUG
  import AppKit
  import CoreGraphics
  import Foundation
  import ImageIO
  import Photos
  import UniformTypeIdentifiers

  /// Immutable fixture data, shared by the Photos read and resource write seams.
  @MainActor
  final class FixturePhotoLibraryService: PhotoLibraryService, ThumbnailReading {
    private struct Asset: Decodable {
      let id: String
      let year: Int
      let month: Int
      let name: String
      let favorite: Bool
      let colors: [UInt8]
    }

    private struct Album: Decodable {
      let id: String
      let title: String
      let assets: [String]
    }

    private struct Document: Decodable {
      let assets: [Asset]
      let albums: [Album]
    }

    private static let fixtureJSON = """
      {
        "assets": [
          {"id":"harbor","year":2025,"month":6,"name":"Harbor","favorite":true,"colors":[30,100,145]},
          {"id":"pines","year":2025,"month":6,"name":"Pines","favorite":false,"colors":[32,112,70]},
          {"id":"ridge","year":2025,"month":5,"name":"Ridge","favorite":true,"colors":[135,77,52]},
          {"id":"coast","year":2024,"month":8,"name":"Coast","favorite":false,"colors":[42,119,137]}
        ],
        "albums": [{"id":"summer","title":"Summer","assets":["harbor","pines"]}]
      }
      """

    private let assets: [Asset]
    private let albums: [Album]
    private let descriptors: [String: AssetDescriptor]
    let images: [String: Data]
    private let thumbnails: [String: CGImage]

    let isAuthorized = true
    let authorizationStatus: PHAuthorizationStatus = .authorized
    var thumbnailReader: any ThumbnailReading { self }

    init() throws {
      let document = try JSONDecoder().decode(Document.self, from: Data(Self.fixtureJSON.utf8))
      assets = document.assets
      albums = document.albums
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = .gmt
      var descriptors: [String: AssetDescriptor] = [:]
      var images: [String: Data] = [:]
      var thumbnails: [String: CGImage] = [:]
      for asset in assets {
        let date = calendar.date(
          from: DateComponents(year: asset.year, month: asset.month, day: 15, hour: 12))
        descriptors[asset.id] = AssetDescriptor(
          id: asset.id, creationDate: date, mediaType: .image, pixelWidth: 480, pixelHeight: 320,
          duration: 0, hasAdjustments: false, originalUTI: UTType.png.identifier)
        let image = try Self.drawImage(colors: asset.colors)
        let data = NSMutableData()
        guard
          let encoder = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil)
        else { throw ControlLaunch.Invalid("Could not allocate fixture PNG encoder.") }
        CGImageDestinationAddImage(encoder, image, nil)
        guard CGImageDestinationFinalize(encoder) else {
          throw ControlLaunch.Invalid("Could not encode fixture PNG.")
        }
        images[asset.id] = data as Data
        thumbnails[asset.id] = image
      }
      self.descriptors = descriptors
      self.images = images
      self.thumbnails = thumbnails
    }

    private static func drawImage(colors: [UInt8]) throws -> CGImage {
      let space = CGColorSpaceCreateDeviceRGB()
      guard
        let context = CGContext(
          data: nil, width: 480, height: 320, bitsPerComponent: 8, bytesPerRow: 0,
          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
      else { throw ControlLaunch.Invalid("Could not allocate fixture image.") }
      let rgb = colors.map { CGFloat($0) / 255 }
      context.setFillColor(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
      context.fill(CGRect(x: 0, y: 0, width: 480, height: 320))
      context.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.35)
      context.fillEllipse(in: CGRect(x: 310, y: 205, width: 60, height: 60))
      context.setFillColor(red: 0, green: 0, blue: 0, alpha: 0.22)
      context.move(to: CGPoint(x: 0, y: 40))
      context.addLine(to: CGPoint(x: 180, y: 190))
      context.addLine(to: CGPoint(x: 390, y: 60))
      context.addLine(to: CGPoint(x: 480, y: 125))
      context.addLine(to: CGPoint(x: 480, y: 0))
      context.addLine(to: .zero)
      context.closePath()
      context.fillPath()
      guard let image = context.makeImage() else {
        throw ControlLaunch.Invalid("Could not render fixture image.")
      }
      return image
    }

    var timelineMonths: Set<ExportRecordStore.MonthKey> {
      Set(assets.map { .init(year: $0.year, month: $0.month) })
    }

    func requestAuthorization() async -> Bool { true }
    func fetchAssetDescriptor(for assetId: String) -> AssetDescriptor? { descriptors[assetId] }

    func timelineAssets(in month: ExportRecordStore.MonthKey) -> [AssetDescriptor] {
      members(in: .timeline(year: month.year, month: month.month)).compactMap {
        descriptors[$0.id]
      }
    }

    func containsAlbum(_ id: String) -> Bool { albums.contains { $0.id == id } }

    private func fetchAssets(in scope: PhotoFetchScope, mediaType: PHAssetMediaType?) async throws
      -> [AssetDescriptor]
    {
      try Task.checkCancellation()
      guard mediaType == nil || mediaType == .image else { return [] }
      return members(in: scope).compactMap { descriptors[$0.id] }
    }

    private func members(in scope: PhotoFetchScope) -> [Asset] {
      switch scope {
      case let .timeline(year, month):
        return assets.filter { $0.year == year && (month == nil || $0.month == month) }
      case .favorites: return assets.filter(\.favorite)
      case .album(let id):
        guard let album = albums.first(where: { $0.id == id }) else { return [] }
        let members = Set(album.assets)
        return assets.filter { members.contains($0.id) }
      case .sharedAlbum: return []
      }
    }

    nonisolated func countAssets(in scope: PhotoFetchScope) async throws -> Int {
      try await fetchAssets(in: scope, mediaType: nil).count
    }
    nonisolated func countAdjustedAssets(in scope: PhotoFetchScope) async throws -> Int { 0 }
    nonisolated func cachedCountAssets(in scope: PhotoFetchScope) async throws -> Int {
      try await countAssets(in: scope)
    }
    nonisolated func cachedCountAdjustedAssets(in scope: PhotoFetchScope) async throws -> Int { 0 }

    func availableYears() throws -> [Int] { Set(assets.map(\.year)).sorted(by: >) }

    func availableYearsWithCounts() throws -> [(year: Int, count: Int)] {
      try availableYears().map {
        (year: $0, count: members(in: .timeline(year: $0, month: nil)).count)
      }
    }

    nonisolated func loadYearsWithCounts() async throws -> [PhotoLibraryYearCount] {
      try await availableYearsWithCounts().map {
        PhotoLibraryYearCount(year: $0.year, count: $0.count)
      }
    }

    private func collectionTree() -> [PhotoCollectionDescriptor] {
      [
        .init(
          id: "favorites", localIdentifier: nil, title: "Favorites", kind: .favorites,
          pathComponents: [], children: [])
      ]
        + albums.map {
          .init(
            id: "album:\($0.id)", localIdentifier: $0.id, title: $0.title, kind: .album,
            pathComponents: [], children: [])
        }
    }

    nonisolated func loadCollectionTree() async throws -> [PhotoCollectionDescriptor] {
      await collectionTree()
    }

    nonisolated func fetchAssetsProgressive(
      in scope: PhotoFetchScope, mediaType: PHAssetMediaType?, batchSize: Int
    ) -> AsyncThrowingStream<[AssetDescriptor], any Error> {
      AsyncThrowingStream { continuation in
        let task = Task {
          do {
            let assets = try await fetchAssets(in: scope, mediaType: mediaType)
            if !assets.isEmpty { continuation.yield(assets) }
            continuation.finish()
          } catch { continuation.finish(throwing: error) }
        }
        continuation.onTermination = { _ in task.cancel() }
      }
    }

    func resolveAssets(ids: [String]) async -> [ThumbnailAsset] {
      ids.compactMap { descriptors[$0].map(ThumbnailAsset.synthetic) }
    }

    func coverThumbnails(in scope: PhotoFetchScope, limit: Int) async throws -> [ThumbnailAsset] {
      try await fetchAssets(in: scope, mediaType: nil).prefix(max(0, limit)).map(
        ThumbnailAsset.synthetic)
    }

    func image(for asset: ThumbnailAsset, spec: ThumbnailRequestSpec) async -> CGImage? {
      thumbnails[asset.descriptor.id]
    }
    func preheat(start: [ThumbnailAsset], stop: [ThumbnailAsset]) async {}
    func decodedThumbnail(
      for assetId: String, quantizedSize: CGSize, deliveryMode: ThumbnailDeliveryMode
    ) async -> CGImage? { thumbnails[assetId] }

    func cachedDecodedThumbnail(
      for assetId: String, quantizedSize: CGSize, deliveryMode: ThumbnailDeliveryMode
    ) -> CGImage? { thumbnails[assetId] }

    func requestPreview(
      for assetId: String, pixelSize: CGSize,
      onDegraded: @escaping @MainActor @Sendable (NSImage) -> Void
    ) async throws -> NSImage { try await requestFullImage(for: assetId) }

    private func requestFullImage(for assetId: String) async throws -> NSImage {
      guard let image = thumbnails[assetId] else {
        throw PhotoLibraryManager.PhotoLibraryError.assetUnavailable
      }
      return NSImage(cgImage: image, size: .zero)
    }

    func resources(for assetId: String) -> [ResourceDescriptor] {
      guard let asset = assets.first(where: { $0.id == assetId }), let image = images[assetId]
      else { return [] }
      return [
        ResourceDescriptor(
          type: .photo, originalFilename: asset.name + ".png", fileSize: Int64(image.count),
          uniformTypeIdentifier: UTType.png.identifier)
      ]
    }

    func assetDetails(for assetId: String) -> AssetDetails? { nil }
  }

  struct FixtureResourceWriter: AssetResourceWriter {
    let images: [String: Data]

    func writeResource(_ resource: ResourceDescriptor, forAssetId assetId: String, to url: URL)
      async throws
    {
      try Task.checkCancellation()
      guard let image = images[assetId] else { throw CocoaError(.fileNoSuchFile) }
      try image.write(to: url, options: .withoutOverwriting)
    }
  }
  struct FixtureMediaRenderer: MediaRenderer {
    func render(request: MediaRenderRequest, to url: URL) async throws {
      // This fixture has no edited videos.
      throw PhotoLibraryManager.PhotoLibraryError.assetUnavailable
    }
  }
#endif
