import Foundation

/// Maps a `--screenshot-surface=<key>` launch argument to a
/// `(LibrarySection, LibrarySelection)` tuple that `LibraryRootView`'s
/// initial-state machinery consumes. Pulled out of the view as a value-type
/// helper so the launch-arg parsing + key-to-selection mapping is unit-
/// testable without instantiating SwiftUI views — and so the production
/// "no arg → nil" guarantee gets a regression test.
///
/// Production launches don't pass `--screenshot-surface=...`, so the resolver
/// returns `nil` and the view falls back to its default Timeline / current-
/// month state. A `nil` return must remain the production behaviour; a
/// regression that returned non-nil here would land every user on a wrong
/// default screen.
enum ScreenshotSurfaceResolver {

  /// Resolved screenshot landing. Both fields together drive
  /// `LibraryRootView`'s initial `@State`.
  struct Surface: Equatable {
    let section: LibrarySection
    let selection: LibrarySelection
  }

  /// Reads `--screenshot-surface=<key>` from `arguments` and resolves to a
  /// `Surface`. `now` is used only by the `.timeline` key to pick the
  /// current-month selection — injectable so tests don't depend on the wall
  /// clock.
  ///
  /// Returns `nil` when no `--screenshot-surface=` argument is present or the
  /// key is unknown — both cases let the caller fall back to its production
  /// default.
  static func resolve(
    from arguments: [String] = ProcessInfo.processInfo.arguments,
    now: Date = Date()
  ) -> Surface? {
    guard
      let raw = arguments.first(where: { $0.hasPrefix("--screenshot-surface=") })
    else { return nil }
    let key = String(raw.split(separator: "=", maxSplits: 1).last ?? "")
    switch key {
    case "timeline":
      let cal = Calendar(identifier: .gregorian)
      return Surface(
        section: .timeline,
        selection: .timelineMonth(
          year: cal.component(.year, from: now),
          month: cal.component(.month, from: now))
      )
    case "collections-favorites":
      return Surface(section: .collections, selection: .favorites)
    case "collections-album-family":
      return Surface(section: .collections, selection: .album(collectionId: "family"))
    case "collections-album-porvoo":
      return Surface(section: .collections, selection: .album(collectionId: "porvoo"))
    case "collections-folder-trips":
      return Surface(section: .collections, selection: .folder(collectionId: "trips"))
    case "collections-album-london":
      return Surface(section: .collections, selection: .album(collectionId: "london"))
    case "collections-album-paris":
      return Surface(section: .collections, selection: .album(collectionId: "paris"))
    default:
      return nil
    }
  }
}
