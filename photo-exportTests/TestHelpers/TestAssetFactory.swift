import Foundation
import Photos

@testable import Photo_Export

enum TestAssetFactory {
  static func makeAsset(
    id: String = UUID().uuidString,
    creationDate: Date? = Date(),
    mediaType: PHAssetMediaType = .image,
    pixelWidth: Int = 4032,
    pixelHeight: Int = 3024,
    duration: TimeInterval = 0,
    hasAdjustments: Bool = false,
    originalUTI: String? = nil,
    isLivePhoto: Bool = false
  ) -> AssetDescriptor {
    AssetDescriptor(
      id: id,
      creationDate: creationDate,
      mediaType: mediaType,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      duration: duration,
      hasAdjustments: hasAdjustments,
      originalUTI: originalUTI,
      isLivePhoto: isLivePhoto
    )
  }

  static func makeResource(
    type: PHAssetResourceType = .photo,
    originalFilename: String = "IMG_0001.JPG",
    fileSize: Int64? = nil
  ) -> ResourceDescriptor {
    ResourceDescriptor(type: type, originalFilename: originalFilename, fileSize: fileSize)
  }
}
