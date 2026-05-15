import Testing

@testable import Photo_Export

/// Pure-function coverage for the sidebar's "Shared Albums" section rendering
/// decision. The view body switches on `SharedAlbumsSectionMode.resolve(...)`
/// to pick between the actual album list, the discovery hint, and hiding the
/// section entirely; the four-cell truth table belongs here so a regression in
/// the hide/show logic doesn't ship dark.
struct SharedAlbumsSectionModeTests {
  /// Albums present always win, regardless of whether the discovery hint was
  /// dismissed in some prior state. A user who dismissed the hint when they
  /// had no shared albums must still see the actual section once Photos syncs
  /// the first one down — without this, the section would stay hidden until
  /// they reset state somehow.
  @Test func albumsPresentReturnsAlbumsRegardlessOfHintDismissal() {
    #expect(
      SharedAlbumsSectionMode.resolve(hasSharedAlbums: true, hintDismissed: false)
        == .albums)
    #expect(
      SharedAlbumsSectionMode.resolve(hasSharedAlbums: true, hintDismissed: true)
        == .albums)
  }

  /// Empty + not dismissed renders the discovery hint, so a user with iCloud
  /// Shared Albums turned off in Photos.app sees the affordance that teaches
  /// them the toggle exists.
  @Test func emptyAndNotDismissedReturnsHint() {
    #expect(
      SharedAlbumsSectionMode.resolve(hasSharedAlbums: false, hintDismissed: false)
        == .hint)
  }

  /// Empty + dismissed hides the section entirely. A user who genuinely has no
  /// shared albums and has acknowledged the hint shouldn't keep seeing a dead
  /// section header forever.
  @Test func emptyAndDismissedReturnsHidden() {
    #expect(
      SharedAlbumsSectionMode.resolve(hasSharedAlbums: false, hintDismissed: true)
        == .hidden)
  }
}
