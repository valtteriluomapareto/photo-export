import Foundation
import Photos
import os

/// Resolves export values and their private resource owner away from the main actor.
final class ProductionPhotoKitReader: PhotoKitReading {
  let thumbnailReader: (any ThumbnailReading)?
  private let io: any DestinationIOExecuting
  private let lookup: (@Sendable (String, Bool) -> PhotoKitAssetSnapshot?)?
  private let resourceOwner: ProductionPhotoKitResourceOwner

  init(
    io: any DestinationIOExecuting = DestinationIO(
      queue: DispatchQueue(label: "photo-export.photokit-reader", qos: .utility)),
    thumbnailBackend: any PhotoKitThumbnailBackend = ProductionThumbnailBackend(),
    resourceOwner: ProductionPhotoKitResourceOwner? = nil,
    lookup: (@Sendable (String, Bool) -> PhotoKitAssetSnapshot?)? = nil
  ) {
    self.thumbnailReader = ProductionThumbnailReader(backend: thumbnailBackend)
    self.io = io
    self.lookup = lookup
    self.resourceOwner = resourceOwner ?? ProductionPhotoKitResourceOwner()
  }

  func readAsset(id: String, livePhotosPaired: Bool) async -> PhotoKitAssetSnapshot? {
    if let lookup {
      return await io.run {
        autoreleasepool { lookup(id, livePhotosPaired) }
      }
    }
    return await resourceOwner.readAsset(id: id, livePhotosPaired: livePhotosPaired)
  }

  static func resourceDescriptor(
    type: PHAssetResourceType, filename: String, uniformTypeIdentifier: String, sizeValue: Any?
  ) -> ResourceDescriptor {
    ResourceDescriptor(
      type: type, originalFilename: filename, fileSize: positiveFileSize(sizeValue),
      uniformTypeIdentifier: uniformTypeIdentifier)
  }

  /// Keeps the existing optional metadata proof without downloading the resource's bytes.
  private static func positiveFileSize(_ value: Any?) -> Int64? {
    guard let size = value as? Int64, size > 0 else { return nil }
    return size
  }
}

/// Only this serial owner stores or uses framework assets, resources and write closures.
final class ProductionPhotoKitResourceOwner: @unchecked Sendable {
  struct Resource {
    let descriptor: ResourceDescriptor
    let writeData: (URL, @escaping @Sendable (Error?) -> Void) -> Void
  }

  struct ResolvedAsset {
    let descriptor: AssetDescriptor
    let enumerateResources: () -> [Resource]
  }

  struct Backend {
    let fetchAsset: (String) -> ResolvedAsset?
  }

  private final class Session {
    let assetId: String
    let asset: ResolvedAsset
    let resources: [Resource]
    var inFlight = 0
    var closed = false

    init(assetId: String, asset: ResolvedAsset, resources: [Resource]) {
      self.assetId = assetId
      self.asset = asset
      self.resources = resources
    }
  }

  /// Across awaits the writer carries only an opaque identity and its serial owner.
  private struct Writer: AssetResourceWriter {
    let id: UUID
    let owner: ProductionPhotoKitResourceOwner

    func writeResource(_ resource: ResourceDescriptor, forAssetId assetId: String, to url: URL)
      async throws
    {
      try await owner.write(resource, forAssetId: assetId, to: url, sessionId: id)
    }

    func close() async { await owner.close(id) }
  }

  private static let logger = Logger.app(.resourceWriter)
  private let queue: DispatchQueue
  private let backend: Backend
  private var sessions: [UUID: Session] = [:]

  init(
    queue: DispatchQueue = DispatchQueue(label: "photo-export.photokit-resources", qos: .utility),
    backend: Backend? = nil
  ) {
    self.queue = queue
    self.backend = backend ?? Self.liveBackend()
  }

  func readAsset(id: String, livePhotosPaired: Bool) async -> PhotoKitAssetSnapshot? {
    await withCheckedContinuation { continuation in
      queue.async { [self] in
        let snapshot: PhotoKitAssetSnapshot? = autoreleasepool {
          guard let asset = backend.fetchAsset(id) else { return nil }
          let resources = asset.enumerateResources()
          let sessionId = UUID()
          sessions[sessionId] = Session(assetId: id, asset: asset, resources: resources)
          return PhotoKitAssetSnapshot.mapping(
            asset.descriptor, resources: resources.map(\.descriptor),
            livePhotosPaired: livePhotosPaired,
            resourceWriter: Writer(id: sessionId, owner: self))
        }
        continuation.resume(returning: snapshot)
      }
    }
  }

  private func write(
    _ descriptor: ResourceDescriptor, forAssetId assetId: String, to url: URL, sessionId: UUID
  ) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      queue.async { [self] in
        guard let session = sessions[sessionId], !session.closed, session.assetId == assetId else {
          continuation.resume(throwing: Self.assetNotFoundError())
          return
        }
        guard
          let resource = session.resources.first(where: {
            $0.descriptor.type == descriptor.type
              && $0.descriptor.originalFilename == descriptor.originalFilename
          })
        else {
          continuation.resume(throwing: Self.resourceNotFoundError())
          return
        }
        let start = Date()
        Self.logger.debug(
          "writeResource begin type: \(descriptor.type.rawValue) filename: \(descriptor.originalFilename, privacy: .public) -> \(url.lastPathComponent, privacy: .public)"
        )
        session.inFlight += 1
        resource.writeData(url) { [self] error in
          queue.async { [self] in
            // Completion resumes only after the serial owner settles this physical write.
            finishWrite(sessionId)
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
  }

  private func finishWrite(_ id: UUID) {
    guard let session = sessions[id] else { return }
    session.inFlight -= 1
    if session.closed && session.inFlight == 0 { sessions.removeValue(forKey: id) }
  }

  private func close(_ id: UUID) async {
    await withCheckedContinuation { continuation in
      queue.async { [self] in
        if let session = sessions[id] {
          session.closed = true
          if session.inFlight == 0 { sessions.removeValue(forKey: id) }
        }
        continuation.resume()
      }
    }
  }

  private static func liveBackend() -> Backend {
    Backend { id in
      let result = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
      guard let asset = result.firstObject else { return nil }
      let descriptor = AssetDescriptor(
        id: asset.localIdentifier, creationDate: asset.creationDate, mediaType: asset.mediaType,
        pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight, duration: asset.duration,
        hasAdjustments: asset.hasAdjustments,
        isLivePhoto: asset.mediaSubtypes.contains(.photoLive))
      return ResolvedAsset(descriptor: descriptor) {
        PHAssetResource.assetResources(for: asset).map { resource in
          Resource(
            descriptor: ProductionPhotoKitReader.resourceDescriptor(
              type: resource.type, filename: resource.originalFilename,
              uniformTypeIdentifier: resource.uniformTypeIdentifier,
              sizeValue: resource.value(forKey: "fileSize")),
            writeData: { url, completion in
              let options = PHAssetResourceRequestOptions()
              options.isNetworkAccessAllowed = true
              PHAssetResourceManager.default().writeData(
                for: resource, toFile: url, options: options, completionHandler: completion)
            })
        }
      }
    }
  }

  private static func assetNotFoundError() -> NSError {
    NSError(
      domain: "Export", code: ExportErrorCode.assetNotFoundForResourceWrite.rawValue,
      userInfo: [NSLocalizedDescriptionKey: "Asset not found for resource write"])
  }

  private static func resourceNotFoundError() -> NSError {
    NSError(
      domain: "Export", code: ExportErrorCode.matchingResourceNotFound.rawValue,
      userInfo: [NSLocalizedDescriptionKey: "Matching PHAssetResource not found"])
  }
}
