import Foundation

enum AutoExportLibraryScope: String, Codable, CaseIterable, Equatable, Sendable {
  case timeline
  case favorites
  case albums
  /// iCloud shared albums. Distinct scope from `.albums` because Photos exposes
  /// them via a separate fetch and the bytes are reduced quality (downscaled
  /// JPEGs only). Users opt in to Auto Export for them via their own toggle so
  /// the trade-off is explicit.
  case sharedAlbums
}

struct AutoExportScopeSelection: Equatable, Codable, Sendable {
  var timeline: Bool
  var favorites: Bool
  var albums: Bool
  var sharedAlbums: Bool

  init(
    timeline: Bool = false,
    favorites: Bool = false,
    albums: Bool = false,
    sharedAlbums: Bool = false
  ) {
    self.timeline = timeline
    self.favorites = favorites
    self.albums = albums
    self.sharedAlbums = sharedAlbums
  }

  /// Custom decode that defaults missing fields to `false`. Lets persisted
  /// selections written by an older app version (no `sharedAlbums` field) decode
  /// without throwing — the user just keeps their previous selection and the new
  /// scope sits off until they opt in.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.timeline = try container.decodeIfPresent(Bool.self, forKey: .timeline) ?? false
    self.favorites = try container.decodeIfPresent(Bool.self, forKey: .favorites) ?? false
    self.albums = try container.decodeIfPresent(Bool.self, forKey: .albums) ?? false
    self.sharedAlbums =
      try container.decodeIfPresent(Bool.self, forKey: .sharedAlbums) ?? false
  }

  static let none = AutoExportScopeSelection()

  var isEmpty: Bool {
    !timeline && !favorites && !albums && !sharedAlbums
  }

  var enabledScopes: [AutoExportLibraryScope] {
    var out: [AutoExportLibraryScope] = []
    if timeline { out.append(.timeline) }
    if favorites { out.append(.favorites) }
    if albums { out.append(.albums) }
    if sharedAlbums { out.append(.sharedAlbums) }
    return out
  }

  func includes(_ scope: AutoExportLibraryScope) -> Bool {
    switch scope {
    case .timeline: return timeline
    case .favorites: return favorites
    case .albums: return albums
    case .sharedAlbums: return sharedAlbums
    }
  }
}
