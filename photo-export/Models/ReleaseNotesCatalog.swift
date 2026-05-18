import Foundation

/// Single source of truth for in-app release notes. Append a new entry
/// for each public release that ships user-visible changes worth
/// highlighting in the **What's New** sheet. Older entries stay
/// indefinitely — users skipping multiple releases see the combined set
/// for everything between their last-seen version and the current
/// bundle version.
///
/// **Release checklist:** before bumping the version in
/// `scripts/bump-version.sh`, add the new entry here. If you forget,
/// the modal degrades gracefully — it shows a generic "Photo Export has
/// been updated — see release notes on GitHub" message instead of
/// stale per-version copy. The plan's `docs/project/release-process.md`
/// names this step.
enum ReleaseNotesCatalog {
  /// All release notes, newest first or oldest first — the lookup uses
  /// semver comparison rather than array order. Each entry's `version`
  /// must match a real `CFBundleShortVersionString` shipped to users.
  static let all: [ReleaseNote] = [
    ReleaseNote(
      version: "1.4.0",
      summary:
        "Auto Export gets iCloud Shared Albums, the sidebar gets multi-select, the timeline year view gets a proper overview, and Auto Export keeps up better in long iCloud-sync sessions. Your existing backup folder and exported files are untouched.",
      bullets: [
        ReleaseNote.Bullet(
          title: "iCloud Shared Albums",
          body:
            "Albums shared with you via iCloud now appear in the **Collections** sidebar and can be exported. Caveat: Apple only provides downscaled JPEGs for shared-album photos, so quality is reduced compared to your own photos. Fixes [#48](https://github.com/valtteriluomapareto/photo-export/issues/48)."
        ),
        ReleaseNote.Bullet(
          title: "Multi-select in the sidebar",
          body:
            "**Cmd-click** to toggle, **Shift-click** to extend a range. Pick years and months in the Timeline sidebar, or albums and folders in the Collections sidebar; the toolbar's Export action targets your selection. Fixes [#46](https://github.com/valtteriluomapareto/photo-export/issues/46)."
        ),
        ReleaseNote.Bullet(
          title: "Year overview shows month tiles",
          body:
            "Selecting a year in the **Timeline** sidebar now opens a Photos.app-style grid of month tiles — four cover thumbnails per month, a green checkmark when fully exported, click to drill in."
        ),
        ReleaseNote.Bullet(
          title: "Auto Export keeps up in long iCloud-sync sessions",
          body:
            "Photo Export now checks iCloud for new photos every 15 minutes (and immediately when you switch back to the app), so newly synced photos get picked up even when Photos.app isn't running. A new **Last updated** line in **Settings → Auto Export** shows when the check last ran. Fixes [#69](https://github.com/valtteriluomapareto/photo-export/issues/69)."
        ),
        ReleaseNote.Bullet(
          title: "Auto Export UX polish",
          body:
            "Pressing **Cancel** during an export now disables Auto Export (it used to restart 30 seconds later). And the in-pane **Export Year / Month / Folder / Album** buttons now show the same \"Auto Export is running\" supersede dialog the toolbar's ⌘E does, instead of silently piling work onto the auto-queue."
        ),
      ],
      learnMore: nil
    ),
    ReleaseNote(
      version: "1.3.0",
      summary:
        "This version adds Auto Export, folder-level batch export, a polished toolbar, and a few new UI surfaces. Your existing backup folder and exported files are untouched.",
      bullets: [
        ReleaseNote.Bullet(
          title: "Auto Export",
          body:
            "Optional set-it-and-forget-it backup — pick Timeline, Favorites, or Albums in **Settings → Auto Export**. New photos in Apple Photos are added to your destination automatically. Off by default; turn it on whenever you're ready."
        ),
        ReleaseNote.Bullet(
          title: "Export by folder",
          body:
            "Folders in the **Collections** sidebar are now selectable. Pick one and the toolbar's primary action becomes **Export N Albums** — every album under that folder, in one click. Or **Cmd-click** album tiles to pick an explicit subset; the button targets just the selection. Right-click the folder for the same action via context menu."
        ),
        ReleaseNote.Bullet(
          title: "Cleaner toolbar",
          body:
            "The **Export All** button is now the visually dominant control (with **⌘E** for the keyboard inclined). The destination indicator is one click — tap the folder name to change it. **Include originals** moved into a Format menu so the toolbar stops competing with itself for attention. The Auto Export status pill is quieter."
        ),
        ReleaseNote.Bullet(
          title: "New status surfaces",
          body:
            "A small **status pill** appears in the main-window toolbar, a **menu bar icon** is always present while the app is running, and the new **Settings window** (Cmd+,) has Auto Export and Export Issues tabs. All show the same state — pick whichever spot is most convenient."
        ),
        ReleaseNote.Bullet(
          title: "Your records carry over",
          body:
            "Photo Export now uses a more stable identifier for destinations. Your existing manual-export history is preserved automatically in almost every case. If you see a **Destination Has Unresolved Issues** banner in Settings → Auto Export (rare — most often when you've installed both the Mac App Store and GitHub builds), click **Resolve…** → **Rebuild Records from Destination**. Your destination files are not touched."
        ),
        ReleaseNote.Bullet(
          title: "Files are still safe",
          body:
            "Photo Export never deletes, overwrites, or moves files at your destination drive — on upgrade or otherwise. If something looks off, your previously-exported photos are still there."
        ),
      ],
      learnMore:
        "The [Auto Export guide](https://valtteriluomapareto.github.io/photo-export/auto-export/) has the full walkthrough, including an Upgrading section with troubleshooting for the rare cases."
    )
  ]

  /// Returns the notes a user upgrading from `lastSeen` to `current`
  /// should see, oldest-version first. An upgrade that crosses multiple
  /// releases (e.g. `1.2.0` → `1.4.0`) returns every entry for
  /// `1.2.0 < v <= 1.4.0`. Fresh installs (`lastSeen == nil`) return
  /// an empty array — the fresh-install path has its own copy in
  /// `WhatsNewView`.
  static func notesForUpgrade(
    lastSeen: String?, current: String, catalog: [ReleaseNote] = all
  ) -> [ReleaseNote] {
    guard let lastSeen, !lastSeen.isEmpty else { return [] }
    return
      catalog
      .filter { note in
        Self.compare(note.version, lastSeen) == .orderedDescending
          && Self.compare(note.version, current) != .orderedDescending
      }
      .sorted { Self.compare($0.version, $1.version) == .orderedAscending }
  }

  /// Numeric-aware lexical comparison; works for the simple dotted
  /// versions Photo Export ships (`1.2.3`, `1.10.0`). Not a full semver
  /// implementation — pre-release suffixes (`-beta.1`) would compare
  /// lexically, which is acceptable because we don't actually ship them
  /// to end users today.
  static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
    lhs.compare(rhs, options: .numeric)
  }
}
