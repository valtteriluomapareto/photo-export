import SwiftUI

/// "What's New" sheet shown on first launch after a version bump. Two
/// flavors:
///
/// - **Fresh install** — "Welcome to Photo Export"; brief feature
///   orientation complementing the existing onboarding flow (which
///   focuses on permissions + destination).
/// - **Upgrade** — "What's New in Photo Export"; highlights Auto Export,
///   the new UI surfaces, and the safety reassurance that no files at
///   the user's destination are touched on upgrade.
///
/// Single dismiss button. No tour, no marketing scroll, no blocking — the
/// user can close it instantly and get on with their work.
struct WhatsNewView: View {
  let state: WhatsNewState
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          if state.isFirstLaunch {
            freshInstallContent
          } else {
            upgradeContent
          }
        }
        .padding(.vertical, 4)
      }
      Spacer(minLength: 0)
      footer
    }
    .padding(24)
    // Min-only sizing so a multi-version jump can grow the sheet
    // vertically instead of pushing everything into a small ScrollView.
    // Width stays narrow enough to read comfortably; the OS will pick a
    // reasonable initial height for the content.
    .frame(minWidth: 520, idealWidth: 520, minHeight: 480)
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: state.isFirstLaunch ? "sparkles" : "arrow.up.circle.fill")
        .font(.system(size: 36))
        .foregroundStyle(.tint)
      VStack(alignment: .leading, spacing: 2) {
        Text(state.isFirstLaunch ? "Welcome to Photo Export" : "What's New in Photo Export")
          .font(.title2.bold())
        Text("Version \(state.currentVersion)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: - Content

  private var freshInstallContent: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(
        "Photo Export backs up your Apple Photos library to a folder you choose — locally, on an external drive, or any mounted volume. A few things to know before you start:"
      )
      bullet(
        "Browse two ways",
        "Use the segmented control above the sidebar to switch between **Timeline** (year + month) and **Collections** (Favorites + your albums)."
      )
      bullet(
        "Manual or automatic",
        "Click **Export All / Export Album / Export Favorites** in the toolbar to back up immediately. Or open **Settings → Auto Export** to keep your destination automatically in sync as new photos appear in Photos."
      )
      bullet(
        "Your files are safe",
        "Photo Export has read-only access to your Photos library and never deletes or overwrites files at your destination — including during recovery flows."
      )
      Text(
        "Want a tour? The [Getting Started guide](https://valtteriluomapareto.github.io/photo-export/getting-started/) walks through the first export step by step."
      )
      .font(.callout)
      .padding(.top, 4)
    }
  }

  @ViewBuilder
  private var upgradeContent: some View {
    if state.isUnknownUpgrade {
      genericUpgradeContent
    } else {
      VStack(alignment: .leading, spacing: 18) {
        ForEach(Array(state.upgradeNotes.enumerated()), id: \.element.version) { idx, note in
          if idx > 0 {
            Divider()
          }
          releaseNoteSection(note)
        }
      }
    }
  }

  private func releaseNoteSection(_ note: ReleaseNote) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      // Per-version header only fires when the user is crossing multiple
      // releases — a single-release upgrade omits it because the sheet's
      // main title bar already shows the current version. Rendered at
      // subheadline weight (not headline) so it doesn't compete with the
      // sheet's title bar.
      if state.upgradeNotes.count > 1 {
        Text("In \(note.version)")
          .font(.subheadline.bold())
          .foregroundStyle(.secondary)
      }
      Text(.init(note.summary))
        .font(.callout)
      ForEach(Array(note.bullets.enumerated()), id: \.offset) { _, b in
        bullet(b.title, b.body)
      }
      if let learnMore = note.learnMore {
        Text(.init(learnMore))
          .font(.callout)
          .padding(.top, 4)
      }
    }
  }

  /// Shown when the user is on a newer bundle version than they've seen
  /// before, but `ReleaseNotesCatalog` has no entry for their jump.
  /// Better to surface a generic, accurate message than stale per-
  /// version copy from an earlier release.
  private var genericUpgradeContent: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(
        "Photo Export has been updated to version \(state.currentVersion). Your existing backup folder and exported files are untouched."
      )
      .font(.callout)
      Text(
        "See the [release notes on GitHub](https://github.com/valtteriluomapareto/photo-export/releases) for the highlights, or the [Photo Export documentation site](https://valtteriluomapareto.github.io/photo-export/) for guides on Auto Export and the rest of the app."
      )
      .font(.callout)
    }
  }

  private func bullet(_ title: String, _ body: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("**\(title)**")
        .font(.callout)
      Text(.init(body))
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: - Footer

  private var footer: some View {
    HStack {
      Spacer()
      Button("Got It") {
        state.markAsSeen()
        dismiss()
      }
      .keyboardShortcut(.defaultAction)
    }
  }
}
