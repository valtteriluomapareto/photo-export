---
title: Features
description: What Photo Export can do today.
---

Photo Export is a focused macOS app for exporting and tracking Apple Photos backups. These are the core capabilities available today.

## Auto Export

Photo Export can keep an external drive (or any folder) automatically in sync with your Apple Photos library — see the [Auto Export guide](/photo-export/auto-export/) for the full walkthrough.

- Optional **Enable Auto Export** toggle in Settings — off by default
- Pick what to back up: **Timeline**, **Favorites**, **Albums**, **Shared Albums**, or any combination
- Runs automatically while Photo Export is open; new photos in Apple Photos are added to your backup after a short delay
- **Status surfaces** in three places: a pill in the main-window toolbar, an always-on menu bar item, and Settings → Auto Export
- **Export Now** in Settings and the menu bar fires a run immediately without waiting
- **Retry policy** waits longer between each attempt for transient failures (Photos library momentarily busy, iCloud download failed, etc.); hard failures (destination full, asset missing) need user action
- **Export Issues** tab groups failures by category. Matching Auto Export retry history can offer a per-row **Retry** button; other failures can be retried with a manual export. See [failed exports and retry](/photo-export/auto-export/#failed-exports-and-retry)
- **Open Photo Export at login** for a set-it-and-forget-it workflow — the app launches with your Mac and Auto Export starts watching
- **Manual exports always take precedence** — clicking any Export button (toolbar **Export All** or an in-pane **Export Year / Month / Folder / Album**) while an automatic run is in flight prompts to supersede the auto run
- **Safety scan** asks for confirmation when you point Auto Export at a folder that already contains files; the confirmation persists per destination

## Library browsing

- Two sidebar sections via a Timeline / Collections segmented control
  - **Timeline**: year/month tree with asset counts and per-month export status
  - **Collections**: Favorites plus the user's albums and folders, grouped by Photos hierarchy
- Export status indicators at both year and month level (not started, in progress with percentage, fully exported with checkmark). After Photos changes, badges keep their previous count pairs visible until fresh pairs are ready; export progress continues updating during the refresh. Each month’s pair is replaced together. Canceling outdated count work keeps the last pair visible; genuine count failures show unknown coverage for the affected month. Obsolete refreshes cannot overwrite newer counts. Historical sidebar summaries still approximate coverage from export records: deleting exported photos and adding new ones at unchanged counts can overstate completion.
- **Year overview** — selecting a year in the Timeline sidebar opens a Photos.app-style grid of month tiles (four cover thumbnails per month, a green checkmark when fully exported). Click a tile to drill into that month.
- Collection headers, thumbnail badges, sidebar progress and folder summaries describe the current album name and folder location. Renaming or moving an album starts progress for the new target; existing files and historical records remain in their original folders.
- Thumbnail preheating follows the visible grid while export runs. Image resolution and pixel decoding run off the main thread, with static placeholders during loading and bounded four-image cover queries.
- Fast thumbnail grid with in-memory caching; the first available asset opens in the detail panel while the rest of the grid loads. Choosing another asset keeps your selection. After Photos changes, a surviving selection gets current details; removing it selects the first remaining asset, and an empty month or collection clears the detail panel.
- Photos changes refresh the grid in place without blanking it. Edits update thumbnails already on screen without navigating away; the current image stays visible while its replacement loads, and older refreshes or image responses cannot replace newer results
- Export status in the detail pane follows the current Timeline, Favorites, album, or Shared Album placement. Renamed or moved albums show history only for their current folder, and recorded converted versions and recovery messages stay visible
- Full-size preview for any selected photo or video. Editing or reverting the selected asset in Photos refreshes the preview without changing selection; the existing image stays visible while replacement loads. Editing another asset leaves the selected preview stable. Switching selections or closing the detail view cancels obsolete requests, and late responses cannot replace revised content. If loading fails, the preview shows retry guidance
- Detail panel showing original filename, creation date, dimensions, file size, media type, and export status

## Export

- One-click export for a single month, a year, or the entire library
- One-click export for Favorites or any album you've created in Photos, written to `Collections/Favorites/` or `Collections/Albums/<Album>/`
- One-click batch export of Favorites and every user album (including albums nested in folders) via the **Export All Albums** toolbar button on the Collections tab
- Export a folder's descendant albums using **Export 1 Album** / **Export N Albums** in its content pane. Selecting child tiles narrows that pane action to their albums; selecting a single folder leaves the toolbar on **Export All Albums**
- Multi-select album tiles inside a folder with Cmd-click / Shift-click to enqueue an arbitrary subset (selected subfolders expand to their descendant albums)
- **Multi-select in the sidebar** with Cmd-click / Shift-click to enqueue an arbitrary mix in one run:
  - Timeline: any combination of years and months. A year covers all its months — selecting a year and a month inside it exports the year.
  - Collections: any combination of Favorites, albums, folders, and shared albums. Selected folders expand to their nested albums; duplicates dedupe.
  - **Edit → Select All Years** / **Select All Collections** (⌘A) picks every top-level row in the active sidebar. Right-clicking a folder that's part of a multi-selection acts on the whole selection, matching the toolbar's primary action.
- **iCloud Shared Albums** appear in their own Collections sidebar section and export when explicitly selected to `Collections/Shared Albums/<Album>/`. See the [reduced-fidelity note](#shared-albums-reduced-fidelity) below — Apple only serves shared photos as downscaled JPEGs
- Only copies assets that haven't been exported yet
- Automatic folder creation in `<year>/<month>/` for the timeline and `Collections/...` for albums and favorites
- Albums under folders preserve their hierarchy on disk (e.g. `Collections/Albums/Trips/Iceland/`)
- Handles both images and videos, including edits made in Photos
- Export progress in the content-column strip below the toolbar (count, current filename, and download/render status)

### Album folder names

New sibling albums whose names differ only by case get distinct folder names, for example
`Trip/` and `trip_2/`. The same rule applies to Shared Albums. Existing folder names and
tracking records stay unchanged; the app does not move or merge backup files. Collisions
between different folder trees whose parent folder names differ only by case remain a
separate limitation.

If an older backup already mixed case-only sibling albums into one folder, choose a **new
empty destination folder** and export the affected albums there. That destination starts
with fresh tracking and separate album folders. Keep the old mixed backup until you have
verified the new copies; importing the old backup does not separate those mixed folders.

### Files already at the destination

Existing files are never overwritten. When a name is taken, the export is written as
`IMG_0001 (1).JPG`, then `(2)`, and so on. A name that an exported item still records counts
as taken even if you deleted its file, so another photo with the same filename does not take
it. **File → Import Existing Backup…** clears records whose files are gone, and the next
export writes those items again under their own names. If the file already there has exactly the same
bytes and no other exported item uses it, for example after the export history was reset or
the folder was set up as a new destination, Photo Export records that file instead of
writing another copy, and leaves it as it is. This covers files exported on their own; an edit with its
`_orig` companion and a Live Photo with its paired video still get new copies. An `_orig`
companion or paired video added later fails, and appears in Export Issues, while another
exported file still records its name; if you deleted that file, Import Existing Backup clears
the record.

### Format options (Settings → Advanced)

Two settings under **Settings → Advanced** (Cmd+,) shape what lands on disk. A Settings
cog in the toolbar opens the window in one click. The onboarding flow also exposes both
toggles inline on first launch.

#### Include originals for edited photos

- **Off (default)** — one file per photo, in the version Photos shows. Edited photos
  export the edit; unedited photos export the original. The file lands at the original
  Photos filename with the extension of the bytes being written, e.g. a HEIC original with
  a JPEG-rendered edit writes `IMG_0001.JPG`.
- **On** — same as off, plus a `_orig` companion for any photo with edits in Photos. The
  companion holds the unmodified original bytes alongside the user-visible edit. For an
  edited HEIC + JPEG-rendered edit the destination ends up with `IMG_0001.JPG` (the edit)
  and `IMG_0001_orig.HEIC` (the original).

Unedited photos never produce a `_orig` companion — there is nothing to pair with.

Edited videos export the user-visible version with the original container preserved (e.g.
an edited `.MOV` stays `.MOV`). With **Include originals** on, the companion is named
`IMG_xxxx_orig.MOV` — the `_orig` suffix is the only filename difference, since videos
keep their original container both times. Photos can change containers (an edited HEIC
may export as `.JPG` because Photos rendered the edit as JPEG); videos do not get that
asymmetric rename.

#### Convert HEIC to JPEG

- **Off (default)** — HEIC and HEIF captures keep their original format on export.
- **On** — HEIC and HEIF captures are re-encoded as high-quality JPEG on export. Useful
  if your destination (a NAS, a Windows PC, an older photo viewer) doesn't understand
  HEIC. Non-HEIC photos (already-JPEG captures, PNG, screenshots, edited photos that
  Photos rendered as JPEG) are unaffected.

The toggle applies to **new exports only.** Existing HEIC files on disk aren't touched
when you flip it on — re-run an Export action (Export All, Export Month, Export Album,
or wait for Auto Export) to convert them.

The two toggles compose naturally. Under **Include originals + Convert HEIC to JPEG**,
an unedited HEIC capture writes both the JPEG (at the natural filename) and the original
HEIC as a `_orig` companion (e.g. `IMG_0001.JPG` next to `IMG_0001_orig.HEIC`).

### Live Photos

Live Photos export as still-only by default. Turn on Settings → Advanced →
**Export Live Photos as paired image + video** to also write the paired video as
a `.MOV` (or whatever extension PhotoKit reports for that resource — typically
uppercase `.MOV` on Apple hardware) next to the still (e.g. `IMG_0001.HEIC` +
`IMG_0001.MOV`). This matches the convention Photos.app uses for its own Live Photo
exports.

- **Default (toggle off)** — byte-identical to a non-Live-Photo still. Only the
  image is written.
- **Toggle on, Include originals off** — one paired set per asset, in the version
  Photos shows. An unedited Live Photo writes the still and the original paired video
  at the natural stem. An edited Live Photo writes the rendered still and the
  rendered paired video at the natural stem; if Photos didn't render a separate
  edited paired video (the common case for edits that don't touch motion), the
  original paired video is reused so the pair is always intact.
- **Toggle on, Include originals on** — same as above, plus `_orig.HEIC` and
  `_orig.MOV` companions for any edited Live Photo. An edited Live Photo ends up
  with four files: `IMG_0001.HEIC` + `IMG_0001.MOV` (the rendered pair) and
  `IMG_0001_orig.HEIC` + `IMG_0001_orig.MOV` (the unmodified originals).

**Disk footprint.** A Live Photo's paired video is typically 1–3 MB. Libraries with
thousands of Live Photos roughly double in size on disk when the toggle is on —
worth checking the destination's free space before flipping it. The setting is
remembered across launches and applies to both manual exports and Auto Export.

Shared-album Live Photos remain still-only regardless of the toggle because Apple
doesn't expose the paired video for assets that live only in a shared album.

### Separate videos into a subfolder

Default off — photos and videos share each month or album folder, e.g.
`2026/03/IMG_0001.JPG` alongside `2026/03/IMG_0002.MOV`.

Turn on Settings → Advanced → **Separate videos into a subfolder** to route
standalone videos into a `videos/` subfolder inside their placement, so a
backup browser doesn't have to scroll past every `.MOV` to find the photos:

- `2026/03/IMG_0001.JPG` (unchanged)
- `2026/03/videos/IMG_0002.MOV`
- `Collections/Albums/Trip/IMG_0003.JPG` and `Collections/Albums/Trip/videos/IMG_0004.MOV`

The paired video of a Live Photo is an exception — it stays next to its still
(e.g. `2026/03/IMG_LIVE.HEIC` + `2026/03/IMG_LIVE.MOV`), not in `videos/`.
Splitting the pair across folders would break the on-disk relationship that
Photos.app, the macOS Finder Quick Look, and other Live-Photo-aware tools use
to recognise the still + motion as a single Live Photo.

**Compose with Include originals.** An edited standalone video under both
toggles writes both `IMG_0002.MOV` and `IMG_0002_orig.MOV` into the same
`videos/` subfolder. An edited Live Photo with both toggles writes all four
files (`IMG_LIVE.HEIC`, `IMG_LIVE_orig.HEIC`, `IMG_LIVE.MOV`,
`IMG_LIVE_orig.MOV`) at the bare month folder so the pair stays intact.

**Applies to new exports only.** Videos already written under the previous
layout stay where they are — turning this on later produces a mixed layout
(old videos in the month root, new videos in `videos/`). The same is true in
reverse when turning the setting off. There's no in-app action to relocate
already-exported files: Photo Export tracks each variant as `.done` per
destination and skips it on subsequent runs, so deleting files on disk and
re-running Export Month alone won't rewrite them. To rebuild a month under
the new layout, delete the existing copies on disk, run **Import Existing
Backup** so the records reconcile against disk truth (missing variants get
pruned), then re-run the Export action.

### Shared albums (reduced fidelity)

iCloud shared albums (the kind you create in Photos to share with family or a partner) are surfaced under a "Shared Albums" section in the Collections sidebar. Selecting a shared album shows its photos in the same grid as a user album, and the **Export Shared Album** button on its pane writes everything to `Collections/Shared Albums/<Album>/`.

There's an important caveat that Photo Export can't work around: **iCloud only serves shared-album photos as downscaled JPEGs.** No API exists to fetch the full-resolution originals for an asset that lives only in a shared album. So:

- The exported files are the best version Apple makes available — typically a JPEG well under the original's resolution
- The **Include originals** and **Convert HEIC to JPEG** toggles are no-ops for shared albums; no `_orig` companion is written and shared-album JPEGs are already JPEG
- A photo that exists in both your library _and_ a shared album gets exported twice — once at full quality under its owned-library scope (`2025/...`, `Collections/Albums/...`), once downscaled under `Collections/Shared Albums/...`. Photo Export uses Photos' own per-asset identifiers, which differ between the two copies, so they're treated as distinct
- Shared albums are excluded from **Export All Albums**. Selecting one gives the toolbar an **Export Shared Album** action; selecting several sidebar items switches to **Export N Items** and can explicitly include Shared Albums

The shared-album pane shows an in-app banner with the same warning so the choice is visible at the moment of export.

## Export destination

- Standard macOS folder picker for selecting the export root
- Works with local folders, external drives, or mounted network volumes
- Selection persists across app launches via security-scoped bookmarks
- Re-selecting the same folder keeps an active export and its history running; choosing a different folder cancels the old run
- Drive status indicator in the toolbar (connected/disconnected)
- Destination problems stay visible in the main window and disable export controls whether Auto Export is on or off. Reconnect an unavailable drive or share, or restore access with **Choose Folder**

## Tracking and resume

- Every exported asset is tracked by its Photos library identifier
- Per-destination tracking — switching destinations reconfigures automatically
- Resume-safe: interrupted exports pick up where they left off without re-copying
- Tracking snapshots are replaced atomically, preserving previous export history if the replacement is interrupted
- Export preparation uses progressive Photos enumeration and yields between planning slices of at most 200 assets. Each scope commits after its scan succeeds. This bounds planning work per turn; buffers and staged jobs can still grow with the scope. Large-library responsiveness still needs real Photos validation.
- Sidebar badges update as exports complete

## Queue controls

- Pause and resume the export queue at any time
- Clicking **Export Month** for a month with paused work resumes the existing queue with its original settings, including other queued months, without adding duplicate jobs
- Cancel and restart exports safely: a cancelled scan cannot change the new run’s progress or completion. A file already moved into place finishes its timestamps and history update for the original destination before a replacement export proceeds, avoiding a duplicate on retry. History storage failures retain the completed file for non-destructive Retry; process-crash recovery remains separate. An unfinished download, render or conversion cannot damage a restarted export or add failures to its result.
- Cancel and clear the entire batch
- Queue progress visible in the content-column strip below the toolbar; pause/resume/cancel controls remain in the toolbar

## Existing backup import

- Rebuild local export state from an existing backup folder via **File → Import Existing Backup...** (Cmd+Shift+I). Failed imports, including failures saving history partway through, stop progress with an error and Close/Retry controls. Reconnect or reselect an unavailable folder; resolve export-history alerts before retrying
- Five-stage process: scan backup folder, read Photos library, match files, rebuild state, reconcile against disk
- The reconcile step **prunes records for files that no longer exist** at the destination. Cancelled or superseded scans discard their results; switching destinations cannot apply an old scan to the replacement destination’s history, and newer record changes are preserved
- Rebuilds Favorites, album and shared-album history from the folders under `Collections/` too, so exporting those collections again skips files already there. Folders of albums renamed, moved or deleted in Photos since they were exported are reported and left in place
- Shows a detailed report with matched, ambiguous, unmatched, and pruned counts, album and Favorites files scanned and matched, and album folders not linked to an album
- Continue exporting on a fresh install without re-copying known assets

## Error handling

- Graceful handling when Photos library access is denied or limited
- Export folder unavailable or write-protected detection
- Individual asset failures are skipped and recorded — the batch continues
- Failed assets are logged with error details
- **Help → Save Diagnostic Report…** writes a plain-text file listing every photo whose export is in `failed` or `in-progress` state with its underlying error message — attach it to a bug report so the cause is visible. If a prior Auto Export run was interrupted mid-flight by the operating system, the report names which scope (timeline / favorites / albums / shared albums) was in flight at the time
- When Photos can't provide an asset's edited version (`Edited resource unavailable`), the app **falls back to writing the original** with a `_orig` suffix so the asset still gets bytes on disk; the diagnostic report annotates the affected entries

Export progress storage errors stop further exports using the affected records and show a Retry action. Restore storage access or free disk space, then retry while the app remains open to save retained progress without resetting history. If Retry finds damaged history, the Reset prompt appears so recovery can continue. Dismissing a timeline storage alert also allows a collection recovery alert to appear. Export runs acknowledge record writes before reporting completion.

## Current boundaries

- macOS only (15.0+)
- Timeline exports use the fixed year/month hierarchy; collection exports land under `Collections/Favorites/` and `Collections/Albums/`
- Exports run sequentially (one asset at a time)
- Folder export actions queue their descendant albums; folders themselves do not contain photos
- Smart albums other than Favorites are not surfaced in the Collections sidebar
- Shared albums are surfaced but export at reduced quality (downscaled JPEGs) — see [Shared albums (reduced fidelity)](#shared-albums-reduced-fidelity) above
