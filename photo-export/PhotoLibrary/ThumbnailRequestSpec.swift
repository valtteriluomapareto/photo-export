import CoreGraphics
import Photos

/// The cache identity and PhotoKit options shared by requests and preheating.
struct ThumbnailRequestSpec: Hashable, Sendable {
  static let gridSize = CGSize(width: 256, height: 256)
  let size: CGSize
  let delivery: ThumbnailDeliveryMode

  var contentMode: PHImageContentMode { .aspectFill }

  func options() -> PHImageRequestOptions {
    let options = PHImageRequestOptions()
    options.deliveryMode = delivery == .fast ? .fastFormat : .highQualityFormat
    options.resizeMode = delivery == .fast ? .fast : .exact
    options.isNetworkAccessAllowed = true
    return options
  }
}
