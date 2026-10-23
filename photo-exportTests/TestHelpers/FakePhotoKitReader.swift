import Foundation

@testable import Photo_Export

@MainActor
final class FakePhotoKitReader: PhotoKitReading {
  var snapshots: [String: PhotoKitAssetSnapshot] = [:]
  private(set) var calls: [(id: String, livePhotosPaired: Bool)] = []

  func readAsset(id: String, livePhotosPaired: Bool) async -> PhotoKitAssetSnapshot? {
    calls.append((id, livePhotosPaired))
    return snapshots[id]
  }
}
