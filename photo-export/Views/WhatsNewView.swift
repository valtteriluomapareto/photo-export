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
  @ObservedObject var state: WhatsNewState
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
    .frame(width: 520, height: 480)
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

  private var upgradeContent: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(
        "This version adds Auto Export and a few new UI surfaces. Your existing backup folder and exported files are untouched."
      )
      .font(.callout)
      bullet(
        "Auto Export",
        "Optional set-it-and-forget-it backup — pick Timeline, Favorites, or Albums in **Settings → Auto Export**. New photos in Apple Photos are added to your destination automatically. Off by default; turn it on whenever you're ready."
      )
      bullet(
        "New status surfaces",
        "A small **status pill** appears in the main-window toolbar, a **menu bar icon** is always present while the app is running, and the new **Settings window** (Cmd+,) has Auto Export and Export Issues tabs. All show the same state — pick whichever spot is most convenient."
      )
      bullet(
        "Your records carry over",
        "Photo Export now uses a more stable identifier for destinations. Your existing manual-export history is preserved automatically in almost every case. If you see a **Destination Has Unresolved Issues** banner in Settings → Auto Export (rare — most often when you've installed both the Mac App Store and GitHub builds), click **Resolve…** → **Rebuild Records from Destination**. Your destination files are not touched."
      )
      bullet(
        "Files are still safe",
        "Photo Export never deletes, overwrites, or moves files at your destination drive — on upgrade or otherwise. If something looks off, your previously-exported photos are still there."
      )
      Text(
        "The [Auto Export guide](https://valtteriluomapareto.github.io/photo-export/auto-export/) has the full walkthrough, including an Upgrading section with troubleshooting for the rare cases."
      )
      .font(.callout)
      .padding(.top, 4)
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
