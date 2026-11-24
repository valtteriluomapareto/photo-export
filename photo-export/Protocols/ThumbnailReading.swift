import CoreGraphics

/// Resolves retained thumbnail sources and performs image work outside the UI actor.
protocol ThumbnailReading: Sendable {
  func resolveAssets(ids: [String]) async -> [ThumbnailAsset]
  func image(for asset: ThumbnailAsset, spec: ThumbnailRequestSpec) async -> CGImage?
  func preheat(start: [ThumbnailAsset], stop: [ThumbnailAsset]) async
  func coverThumbnails(in scope: PhotoFetchScope, limit: Int) async throws -> [ThumbnailAsset]
}
