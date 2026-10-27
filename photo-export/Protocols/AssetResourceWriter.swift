import Foundation

/// Abstracts writing asset resource data to disk for testability.
/// Production implementation wraps PHAssetResourceManager. Tests inject a fake.
protocol AssetResourceWriter: Sendable {
  func writeResource(_ resource: ResourceDescriptor, forAssetId assetId: String, to url: URL)
    async throws

  /// Stops new writes and releases job resources after admitted physical writes complete.
  func close() async
}

extension AssetResourceWriter {
  func close() async {}
}
