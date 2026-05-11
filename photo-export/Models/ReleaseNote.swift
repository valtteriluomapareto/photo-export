import Foundation

/// One version's worth of "What's New" content. Used by the
/// `WhatsNewState` / `WhatsNewView` pair to surface release-flavored
/// content on first launch after a version bump.
///
/// New releases are added by appending to `ReleaseNotesCatalog.all`.
/// Forgetting to append doesn't crash or show stale copy — the modal
/// falls back to a generic "Photo Export has been updated — see release
/// notes" message keyed on the current bundle version.
///
/// Body strings support SwiftUI's inline markdown (`**bold**`,
/// `[label](url)`), which the rendering view passes through
/// `Text(.init(...))`.
struct ReleaseNote: Equatable, Sendable {
  /// Semver of the release this note describes. Matched lexically against
  /// `CFBundleShortVersionString`, so the value must equal the bundle
  /// version exactly (e.g. `"1.3.0"`, not `"v1.3.0"` or `"1.3.0-beta.1"`).
  let version: String

  /// One-sentence intro shown above the bullets. Markdown supported.
  let summary: String

  /// Bullet list. Each entry has a bolded title and a markdown body.
  let bullets: [Bullet]

  /// Optional inline link at the end (e.g. "See the [Auto Export
  /// guide](https://…) for…"). Markdown supported.
  let learnMore: String?

  struct Bullet: Equatable, Sendable {
    let title: String
    let body: String
  }
}
