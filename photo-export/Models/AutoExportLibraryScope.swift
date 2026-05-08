import Foundation

enum AutoExportLibraryScope: String, Codable, CaseIterable, Equatable, Sendable {
  case timeline
  case favorites
  case albums
}

struct AutoExportScopeSelection: Equatable, Codable, Sendable {
  var timeline: Bool
  var favorites: Bool
  var albums: Bool

  init(timeline: Bool = false, favorites: Bool = false, albums: Bool = false) {
    self.timeline = timeline
    self.favorites = favorites
    self.albums = albums
  }

  static let none = AutoExportScopeSelection()

  var isEmpty: Bool {
    !timeline && !favorites && !albums
  }

  var enabledScopes: [AutoExportLibraryScope] {
    var out: [AutoExportLibraryScope] = []
    if timeline { out.append(.timeline) }
    if favorites { out.append(.favorites) }
    if albums { out.append(.albums) }
    return out
  }

  func includes(_ scope: AutoExportLibraryScope) -> Bool {
    switch scope {
    case .timeline: return timeline
    case .favorites: return favorites
    case .albums: return albums
    }
  }
}
