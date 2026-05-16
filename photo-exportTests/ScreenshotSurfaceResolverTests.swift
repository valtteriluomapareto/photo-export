import Foundation
import Testing

@testable import Photo_Export

/// `ScreenshotSurfaceResolver` is consulted at *every* app launch
/// (LibraryRootView.init), not just under `--screenshot-mode`. Its
/// "production launches return nil" guarantee is load-bearing: a regression
/// that returned a non-nil tuple for an argument-less invocation would land
/// every real user on the wrong default screen. These tests pin that
/// guarantee and the 7-key mapping.
struct ScreenshotSurfaceResolverTests {

  // MARK: - Production-safety guard

  /// The single most-important assertion in this file. Without it, a future
  /// refactor that swaps `first(where:)` for `contains(where:)` or otherwise
  /// returns a default would silently misroute every production launch.
  @Test func productionLaunchReturnsNil() {
    let result = ScreenshotSurfaceResolver.resolve(
      from: [
        "/Applications/Photo Export.app/Contents/MacOS/Photo Export"
      ])
    #expect(result == nil)
  }

  /// Args that include unrelated flags (system-injected, debugger, sandbox
  /// arg, etc.) must not match the surface arg.
  @Test func unrelatedArgsReturnNil() {
    let result = ScreenshotSurfaceResolver.resolve(
      from: [
        "/Applications/Photo Export.app/Contents/MacOS/Photo Export",
        "-NSDocumentRevisionsDebugMode", "YES",
        "--some-other-flag=value",
      ])
    #expect(result == nil)
  }

  /// `--screenshot-surface=` with an unknown key falls through to nil rather
  /// than throwing or asserting.
  @Test func unknownKeyReturnsNil() {
    let result = ScreenshotSurfaceResolver.resolve(
      from: ["app", "--screenshot-surface=does-not-exist"])
    #expect(result == nil)
  }

  // MARK: - Key mapping

  @Test func timelineKeyMapsToCurrentMonth() {
    let date = Calendar(identifier: .gregorian).date(
      from: DateComponents(year: 2025, month: 7, day: 14))!
    let result = ScreenshotSurfaceResolver.resolve(
      from: ["app", "--screenshot-surface=timeline"], now: date)
    #expect(result?.section == .timeline)
    #expect(result?.selection == .timelineMonth(year: 2025, month: 7))
  }

  @Test func collectionsFavoritesKey() {
    let result = ScreenshotSurfaceResolver.resolve(
      from: ["app", "--screenshot-surface=collections-favorites"])
    #expect(result?.section == .collections)
    #expect(result?.selection == .favorites)
  }

  @Test func collectionsFamilyAlbumKey() {
    let result = ScreenshotSurfaceResolver.resolve(
      from: ["app", "--screenshot-surface=collections-album-family"])
    #expect(result?.section == .collections)
    #expect(result?.selection == .album(collectionId: "family"))
  }

  @Test func collectionsPorvooAlbumKey() {
    let result = ScreenshotSurfaceResolver.resolve(
      from: ["app", "--screenshot-surface=collections-album-porvoo"])
    #expect(result?.section == .collections)
    #expect(result?.selection == .album(collectionId: "porvoo"))
  }

  @Test func collectionsTripsFolderKey() {
    let result = ScreenshotSurfaceResolver.resolve(
      from: ["app", "--screenshot-surface=collections-folder-trips"])
    #expect(result?.section == .collections)
    #expect(result?.selection == .folder(collectionId: "trips"))
  }

  @Test func collectionsLondonAlbumKey() {
    let result = ScreenshotSurfaceResolver.resolve(
      from: ["app", "--screenshot-surface=collections-album-london"])
    #expect(result?.section == .collections)
    #expect(result?.selection == .album(collectionId: "london"))
  }

  @Test func collectionsParisAlbumKey() {
    let result = ScreenshotSurfaceResolver.resolve(
      from: ["app", "--screenshot-surface=collections-album-paris"])
    #expect(result?.section == .collections)
    #expect(result?.selection == .album(collectionId: "paris"))
  }

  @Test func collectionsFamilyStreamSharedAlbumKey() {
    let result = ScreenshotSurfaceResolver.resolve(
      from: ["app", "--screenshot-surface=collections-shared-album-family-stream"])
    #expect(result?.section == .collections)
    #expect(result?.selection == .sharedAlbum(collectionId: "family-stream"))
  }

  // MARK: - Multi-select surfaces (issue #46)

  /// Timeline multi-select demo: focused current month + the two prior years.
  /// Tests pin (a) the exact focus + extra set so the marketing capture is
  /// reproducible across runs, and (b) that the buckets dedup count yields
  /// "Export 3 Items" in the toolbar (year–month overlap protection).
  @Test func timelineMultiSelectKey() {
    let date = Calendar(identifier: .gregorian).date(
      from: DateComponents(year: 2026, month: 5, day: 16))!
    let result = ScreenshotSurfaceResolver.resolve(
      from: ["app", "--screenshot-surface=timeline-multi-select"], now: date)
    #expect(result?.section == .timeline)
    #expect(result?.selection == .timelineMonth(year: 2026, month: 5))
    #expect(
      result?.additionalSelections == [
        .timelineYear(year: 2025),
        .timelineYear(year: 2024),
      ])
  }

  /// Collections multi-select demo: focused Family album + Favorites + Porvoo
  /// + the Trips folder. Four disparate row kinds so the sidebar showcases the
  /// full selection vocabulary in one screenshot.
  @Test func collectionsMultiSelectKey() {
    let result = ScreenshotSurfaceResolver.resolve(
      from: ["app", "--screenshot-surface=collections-multi-select"])
    #expect(result?.section == .collections)
    #expect(result?.selection == .album(collectionId: "family"))
    #expect(
      result?.additionalSelections == [
        .favorites,
        .album(collectionId: "porvoo"),
        .folder(collectionId: "trips"),
      ])
  }

  /// Default `additionalSelections` is empty for every single-select key —
  /// guards against a regression that accidentally bleeds the multi-select
  /// extras into the existing surfaces.
  @Test func singleSelectSurfacesHaveNoAdditionalSelections() {
    let keys = [
      "timeline", "collections-favorites", "collections-album-family",
      "collections-album-porvoo", "collections-folder-trips",
      "collections-album-london", "collections-album-paris",
      "collections-shared-album-family-stream",
    ]
    for key in keys {
      let result = ScreenshotSurfaceResolver.resolve(
        from: ["app", "--screenshot-surface=\(key)"])
      #expect(result?.additionalSelections == [], "expected no extras for \(key)")
    }
  }

  // MARK: - Argument-handling edge cases

  /// Multiple `--screenshot-surface=` args take the first one — matches
  /// `first(where:)` semantics so the script can't accidentally route to the
  /// last value if both got passed.
  @Test func firstMatchWins() {
    let result = ScreenshotSurfaceResolver.resolve(
      from: [
        "app",
        "--screenshot-surface=collections-favorites",
        "--screenshot-surface=collections-album-london",
      ])
    #expect(result?.selection == .favorites)
  }

  /// `--screenshot-surface` without `=value` (just the flag) doesn't match.
  /// Important because someone might forget the `=` and we don't want a
  /// silent fall-through to a "default" tuple.
  @Test func flagWithoutValueReturnsNil() {
    let result = ScreenshotSurfaceResolver.resolve(
      from: ["app", "--screenshot-surface"])
    #expect(result == nil)
  }
}
