import Photos

/// An immutable framework snapshot resolved off main and retained by its active consumers.
/// The Photos object is never mutated; UI code uses only its descriptor.
final class ThumbnailAsset: @unchecked Sendable {
  let descriptor: AssetDescriptor
  let photoKitAsset: PHAsset?
  let contentRevision: Int

  init(descriptor: AssetDescriptor, photoKitAsset: PHAsset?, contentRevision: Int = 0) {
    self.descriptor = descriptor
    self.photoKitAsset = photoKitAsset
    self.contentRevision = contentRevision
  }

  func withRevision(_ revision: Int) -> ThumbnailAsset {
    ThumbnailAsset(descriptor: descriptor, photoKitAsset: photoKitAsset, contentRevision: revision)
  }

  var preheatKey: String { "\(contentRevision):\(descriptor.id)" }

  static func synthetic(_ descriptor: AssetDescriptor) -> Self {
    Self(descriptor: descriptor, photoKitAsset: nil)
  }
}
