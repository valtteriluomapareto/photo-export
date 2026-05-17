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

  /// Resolved screenshot landing. `section` and `selection` together drive
  /// `LibraryRootView`'s initial `@State`. `additionalSelections` adds extra
  /// sidebar rows to the highlight set for multi-select demo surfaces — empty
  /// for single-select keys, which is the default and keeps the production
  /// fall-through (no `--screenshot-surface=` arg → `nil`) untouched.
  struct Surface: Equatable {
    let section: LibrarySection
    /// Focused selection. Drives the content pane; appears in the multi-select
    /// set together with `additionalSelections`.
    let selection: LibrarySelection
    /// Extra rows to highlight in the sidebar alongside `selection`. The full
    /// initial set is `Set([selection] + additionalSelections)`. Empty for the
    /// single-select surfaces.
    let additionalSelections: [LibrarySelection]

    init(
      section: LibrarySection,
      selection: LibrarySelection,
      additionalSelections: [LibrarySelection] = []
    ) {
      self.section = section
      self.selection = selection
      self.additionalSelections = additionalSelections
    }
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
    case "collections-shared-album-family-stream":
      // Issue #48: lands on the synthetic "Family stream" shared album from
      // `ScreenshotPhotoLibraryService.tree` so marketing captures showcase the
      // new "Shared Albums" sidebar section and the reduced-fidelity banner.
      return Surface(
        section: .collections, selection: .sharedAlbum(collectionId: "family-stream"))
    case "timeline-multi-select":
      // Issue #46 multi-select feature: highlights two prior years + a month in
      // the current year so the sidebar shows three rows selected and the
      // toolbar reads "Export 3 Items". Focus on the current month so the
      // content pane renders MonthContentView's populated grid (the most
      // photogenic preview for a marketing capture).
      let cal = Calendar(identifier: .gregorian)
      let currentYear = cal.component(.year, from: now)
      let currentMonth = cal.component(.month, from: now)
      return Surface(
        section: .timeline,
        selection: .timelineMonth(year: currentYear, month: currentMonth),
        additionalSelections: [
          .timelineYear(year: currentYear - 1),
          .timelineYear(year: currentYear - 2),
        ]
      )
    case "collections-multi-select":
      // Issue #46 multi-select feature: Favorites + two albums + a folder, four
      // disparate row kinds highlighted in the sidebar. Focus on the Family
      // album so the content pane renders a populated thumbnail grid; the
      // toolbar's primary action reads "Export 4 Items". `Trips` folder
      // demonstrates that folders dedup-expand to their contained albums at
      // dispatch time without the sidebar reproducing the expansion.
      return Surface(
        section: .collections,
        selection: .album(collectionId: "family"),
        additionalSelections: [
          .favorites,
          .album(collectionId: "porvoo"),
          .folder(collectionId: "trips"),
        ]
      )
    default:
      return nil
    }
  }
}
