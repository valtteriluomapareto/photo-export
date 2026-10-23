import Photos

/// A Photos query includes its media predicate; membership is independent of image content.
struct PhotoLibraryQuery: Hashable, Sendable {
  let scope: PhotoFetchScope
  let mediaTypeRawValue: Int?

  init(scope: PhotoFetchScope, mediaType: PHAssetMediaType? = nil) {
    self.scope = scope
    mediaTypeRawValue = mediaType?.rawValue
  }
}

struct PhotoLibraryYearCount: Equatable, Sendable {
  let year: Int
  let count: Int
}
