import Foundation
import Photos
import os

/// Production implementation of AssetResourceWriter that wraps PHAssetResourceManager.
struct ProductionAssetResourceWriter: AssetResourceWriter {
  struct ResolvedResource {
    let type: PHAssetResourceType
    let originalFilename: String
    let writeData: (URL, @escaping (Error?) -> Void) -> Void
  }

  final class Backend: @unchecked Sendable {
    private let resolver: (String, ResourceDescriptor) throws -> ResolvedResource

    init(resolver: @escaping (String, ResourceDescriptor) throws -> ResolvedResource) {
      self.resolver = resolver
    }

    func resolveResource(for assetId: String, matching descriptor: ResourceDescriptor) throws
      -> ResolvedResource
    {
      try resolver(assetId, descriptor)
    }

    static let live = Backend { assetId, descriptor in
      let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
      guard let asset = fetchResult.firstObject else {
        throw assetNotFoundError()
      }

      let resources = PHAssetResource.assetResources(for: asset)
      guard
        let resource = resources.first(where: {
          $0.type == descriptor.type && $0.originalFilename == descriptor.originalFilename
        })
      else {
        throw resourceNotFoundError()
      }

      return ResolvedResource(
        type: resource.type,
        originalFilename: resource.originalFilename,
        writeData: { url, completion in
          let options = PHAssetResourceRequestOptions()
          options.isNetworkAccessAllowed = true
          PHAssetResourceManager.default().writeData(
            for: resource,
            toFile: url,
            options: options,
            completionHandler: completion
          )
        }
      )
    }

    private static func assetNotFoundError() -> NSError {
      NSError(
        domain: "Export",
        code: 3,
        userInfo: [NSLocalizedDescriptionKey: "Asset not found for resource write"]
      )
    }

    private static func resourceNotFoundError() -> NSError {
      NSError(
        domain: "Export",
        code: 4,
        userInfo: [NSLocalizedDescriptionKey: "Matching PHAssetResource not found"]
      )
    }
  }

  private static let logger = Logger(
    subsystem: "com.valtteriluoma.photo-export", category: "ResourceWriter")
  private let backend: Backend

  init(backend: Backend = .live) {
    self.backend = backend
  }

  func writeResource(_ resource: ResourceDescriptor, forAssetId assetId: String, to url: URL)
    async throws
  {
    let resolved = try backend.resolveResource(for: assetId, matching: resource)

    let start = Date()
    Self.logger.debug(
      "writeResource begin type: \(resolved.type.rawValue) filename: \(resolved.originalFilename, privacy: .public) -> \(url.lastPathComponent, privacy: .public)"
    )
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      resolved.writeData(url) { error in
        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
        if let error {
          Self.logger.error(
            "writeResource failed after \(elapsedMs)ms: \(error.localizedDescription, privacy: .public)"
          )
          continuation.resume(throwing: error)
        } else {
          Self.logger.debug(
            "writeResource success after \(elapsedMs)ms -> \(url.lastPathComponent, privacy: .public)"
          )
          continuation.resume(returning: ())
        }
      }
    }
  }
}
