---
title: Features
description: What Photo Export can do today.
---

Photo Export is a focused macOS app for exporting and tracking Apple Photos backups. These are the core capabilities available today.

## Library browsing

- Two sidebar sections via a Timeline / Collections segmented control
  - **Timeline**: year/month tree with asset counts and per-month export status
  - **Collections**: Favorites plus the user's albums and folders, grouped by Photos hierarchy
- Export status indicators at both year and month level (not started, in progress with percentage, fully exported with checkmark)
- Fast thumbnail grid with in-memory caching
- Full-size preview for any selected photo or video
- Detail panel showing original filename, creation date, dimensions, file size, media type, and export status

## Export

- One-click export for a single month, a year, or the entire library
- One-click export for Favorites or any album you've created in Photos, written to `Collections/Favorites/` or `Collections/Albums/<Album>/`
- One-click batch export of every album (including albums nested in folders) via the **Export All Albums** toolbar button on the Collections tab
- Only copies assets that haven't been exported yet
- Automatic folder creation in `<year>/<month>/` for the timeline and `Collections/...` for albums and favorites
- Albums under folders preserve their hierarchy on disk (e.g. `Collections/Albums/Trips/Iceland/`)
- Handles both images and videos, including edits made in Photos
- Real-time progress tracking in the toolbar (count and current filename)

### Version selection

A toolbar toggle next to the export buttons chooses what to write:

- **Off (default)** — one file per photo, in the version Photos shows. Edited photos
  export the edit; unedited photos export the original. The file lands at the original
  Photos filename with the extension of the bytes being written, e.g. a HEIC original with
  a JPEG-rendered edit writes `IMG_0001.JPG`.
- **On — Include originals** — same as off, plus a `_orig` companion for any photo with
  edits in Photos. The companion holds the unmodified original bytes alongside the
  user-visible edit. For an edited HEIC + JPEG-rendered edit the destination ends up with
  `IMG_0001.JPG` (the edit) and `IMG_0001_orig.HEIC` (the original).

Unedited photos never produce a `_orig` companion — there is nothing to pair with.

Edited videos export the user-visible version with the original container preserved (e.g.
an edited `.MOV` stays `.MOV`). With **Include originals** on, the companion is named
`IMG_xxxx_orig.MOV` — the `_orig` suffix is the only filename difference, since videos
keep their original container both times. Photos can change containers (an edited HEIC
may export as `.JPG` because Photos rendered the edit as JPEG); videos do not get that
asymmetric rename.

## Export destination

- Standard macOS folder picker for selecting the export root
- Works with local folders, external drives, or mounted network volumes
- Selection persists across app launches via security-scoped bookmarks
- Drive status indicator in the toolbar (connected/disconnected)

## Tracking and resume

- Every exported asset is tracked by its Photos library identifier
- Per-destination tracking — switching destinations reconfigures automatically
- Resume-safe: interrupted exports pick up where they left off without re-copying
- Sidebar badges update as exports complete

## Queue controls

- Pause and resume the export queue at any time
- Cancel and clear the entire batch
- Queue progress visible in the toolbar

## Existing backup import

- Rebuild local export state from an existing backup folder via **File → Import Existing Backup...** (Cmd+Shift+I)
- Five-stage process: scan backup folder, read Photos library, match files, rebuild state, reconcile against disk
- The reconcile step **prunes records for files that no longer exist** at the destination, so a re-run after deleting some exports always reflects current disk contents
- Shows a detailed report with matched, ambiguous, unmatched, and pruned counts
- Continue exporting on a fresh install without re-copying known assets

## Error handling

- Graceful handling when Photos library access is denied or limited
- Export folder unavailable or write-protected detection
- Individual asset failures are skipped and recorded — the batch continues
- Failed assets are logged with error details
- **Help → Save Diagnostic Report…** writes a plain-text file listing every photo whose export is in `failed` or `in-progress` state with its underlying error message — attach it to a bug report so the cause is visible
- When Photos can't provide an asset's edited version (`Edited resource unavailable`), the app **falls back to writing the original** with a `_orig` suffix so the asset still gets bytes on disk; the diagnostic report annotates the affected entries

## Current boundaries

- macOS only (15.0+)
- Timeline exports use the fixed year/month hierarchy; collection exports land under `Collections/Favorites/` and `Collections/Albums/`
- Exports run sequentially (one asset at a time)
- Folders in Photos render in the sidebar tree but are not directly exportable — pick the album you want
- Smart albums other than Favorites and shared albums are not surfaced in the Collections sidebar
