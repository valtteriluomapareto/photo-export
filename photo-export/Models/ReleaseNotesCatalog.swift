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
      // Placeholder version — adjust when the actual release ships under a
      // different `CFBundleShortVersionString`.
      version: "1.8.0",
      summary:
        "Import Existing Backup now adopts album and shared-album exports too — no more re-exporting the same albums after a reinstall.",
      bullets: [
        ReleaseNote.Bullet(
          title: "Import Existing Backup restores album records",
          body:
            "Folders under `Collections/Favorites/`, `Collections/Albums/`, and "
            + "`Collections/Shared Albums/` are now walked alongside the year/month "
            + "tree when you choose **File → Import Existing Backup…**. Matched "
            + "files become records under the right placement, so the next export "
            + "skips them instead of producing duplicates with `_2`/`_3` suffixes. "
            + "Albums or shared albums that no longer exist in Photos are skipped "
            + "and called out in the result sheet so an empty folder doesn't look "
            + "like corruption. "
            + "Fixes [#106](https://github.com/valtteriluomapareto/photo-export/issues/106)."
        )
      ],
      learnMore: nil
    ),
    ReleaseNote(
      // Placeholder version — adjust when the actual release ships under a
      // different `CFBundleShortVersionString`. The catalog falls back to a
      // generic "Photo Export has been updated" message if no entry matches
      // the user's jump, so a stale version here degrades gracefully.
      version: "1.7.0",
      summary:
        "Optional videos-in-a-subfolder layout so a backup doesn't mix `.JPG` and `.MOV` files in the same folder. Your existing backup folder and exported files are untouched.",
      bullets: [
        ReleaseNote.Bullet(
          title: "Separate videos into a subfolder (opt-in)",
          body:
            "A new toggle in **Settings → Advanced → Organization → Separate videos "
            + "into a subfolder** routes standalone videos into a `videos/` subfolder "
            + "inside their placement (e.g. `2026/03/IMG_0001.JPG` next to "
            + "`2026/03/videos/IMG_0002.MOV`), so a backup browser doesn't have to scroll "
            + "past every video to find the photos. The paired video of a Live Photo is an "
            + "exception — it stays next to its still so the still + motion pair isn't "
            + "split across folders and remains recognised as a Live Photo by viewers and "
            + "re-importers. Off by default. Applies to new exports only — videos already "
            + "on disk stay where they are; turning this on later produces a mixed layout "
            + "until you re-export the affected months. "
            + "Fixes [#38](https://github.com/valtteriluomapareto/photo-export/issues/38)."
        )
      ],
      learnMore: nil
    ),
    ReleaseNote(
      version: "1.6.0",
      summary:
        "Live Photos can now export with their paired video file (opt-in). Your existing backup folder and exported files are untouched.",
      bullets: [
        ReleaseNote.Bullet(
          title: "Export Live Photos as paired image + video (opt-in)",
          body:
            "Turn on **Settings → Advanced → Export Live Photos as paired image + video** "
            + "to also write the `.MOV` paired video next to the still for each Live Photo "
            + "(e.g. `IMG_0001.HEIC` + `IMG_0001.MOV`). Off by default. Each Live Photo's "
            + "paired video is typically 1–3 MB, so libraries with many Live Photos can "
            + "roughly double in size on disk when this is on. Edited Live Photos write the "
            + "rendered pair; with **Include originals** also on, `_orig.HEIC` and `_orig.MOV` "
            + "companions land alongside. Shared-album Live Photos stay still-only — Apple "
            + "doesn't expose their paired video. "
            + "Fixes [#49](https://github.com/valtteriluomapareto/photo-export/issues/49)."
        )
      ],
      learnMore: nil
    ),
    ReleaseNote(
      version: "1.5.0",
      summary:
        "Optional HEIC → JPEG conversion on export, a new Settings → Advanced tab for format options, and the toolbar's \"Export All\" button is back even when a single sidebar item is selected. Your existing backup folder and exported files are untouched.",
      bullets: [
        ReleaseNote.Bullet(
          title: "Convert HEIC to JPEG on export (opt-in)",
          body:
            "A new toggle in **Settings → Advanced** re-encodes HEIC and HEIF captures as high-quality JPEG when exporting. Useful if your destination (a NAS, a Windows PC, an older photo viewer) doesn't understand HEIC. Non-HEIC photos are unaffected. The toggle applies to new exports — re-run an Export action (or wait for Auto Export) to convert HEICs you've already exported. Off by default; existing backups are not touched. Fixes [#47](https://github.com/valtteriluomapareto/photo-export/issues/47)."
        ),
        ReleaseNote.Bullet(
          title: "Format options moved to Settings → Advanced",
          body:
            "**Include originals for edited photos** and the new **Convert HEIC to JPEG** toggle both live in **Cmd+, → Advanced** now, with full descriptions explaining each option's on-disk effect. The previous toolbar Format menu is gone; a Settings cog in the toolbar opens the window in one click. The onboarding flow still lets you set both options inline on first launch."
        ),
        ReleaseNote.Bullet(
          title: "\"Export All\" stays available with a sidebar item selected",
          body:
            "The toolbar's primary action now reads **Export All** (Timeline) or **Export All Albums** (Collections) whenever 0 or 1 sidebar items are selected, instead of flipping to the per-item label. The per-pane **Export Month / Year / Album / Folder / Favorites** buttons still handle single-item dispatch. Shared albums keep their dedicated **Export Shared Album** label because they're excluded from the global batch (iCloud reduced-fidelity caveat). Fixes [#91](https://github.com/valtteriluomapareto/photo-export/issues/91)."
        ),
        ReleaseNote.Bullet(
          title: "Sharper month and folder tile thumbnails",
          body:
            "Year-view month tiles and Collections folder tiles now request thumbnails at the displayed pixel size on Retina displays instead of a small cached version. The 4-up cover grids read as crisply as the in-pane grid below them."
        ),
      ],
      learnMore: nil
    ),
    ReleaseNote(
      version: "1.4.1",
      summary:
        "Fixes launch reliability on macOS 15.7+ and when the destination folder is on an unreachable network share.",
      bullets: [
        ReleaseNote.Bullet(
          title: "Launch no longer hangs while the Photos library catches up",
          body:
            "Photo Export's startup library-changes catch-up now runs in the background instead of holding the main thread. On libraries with a large backlog of recent Photos changes (often the case on macOS 15.7+ after periods away from the app), this prevents the beachball at launch reported in [#92](https://github.com/valtteriluomapareto/photo-export/issues/92). The first scan still runs — you just get a responsive window while it does."
        ),
        ReleaseNote.Bullet(
          title: "Stale network bookmark no longer blocks launch",
          body:
            "If you upgraded from 1.3 with the destination folder on a NAS or other network share that the app can't reach at launch — volume unmounted, sandbox-denied, or otherwise unreadable — Photo Export now starts cleanly and prompts you to re-select the folder instead of beachballing. Companion fix to [#92](https://github.com/valtteriluomapareto/photo-export/issues/92)."
        ),
        ReleaseNote.Bullet(
          title: "Photos library first-touch is no longer synchronous on launch",
          body:
            "PhotoKit's initial handshake also moved off the synchronous launch path, so on macOS 15.7+ the app stays responsive even if Apple's framework takes a moment to come online. Belt-and-braces with the catch-up fix above."
        ),
      ],
      learnMore: nil
    ),
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
    ),
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
