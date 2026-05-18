# Manual Testing Guide — Edited Photos Export

Date: 2026-04-27
Feature: [issue #13 — Support exporting edited photos](https://github.com/valtteriluomapareto/photo-export/conversations/issues/13)
Parent plan: `edited-photos-modes-redesign-plan.md`

## Goal

Verify by hand that the redesigned edited-photos export feature behaves
correctly across the cases unit tests cannot cover: PhotoKit integration,
file system side effects, and the full UI. Each scenario is independently
runnable. The two modes are surfaced via the toolbar's **Include
originals** toggle:

- **Off (default):** one file per photo, in the version Photos shows.
  Edited photos write the edit; unedited photos write the original.
- **On — Include originals:** same as off, plus a `_orig` companion for
  any photo with edits in Photos.

## Build and install

```bash
xcodebuild \
  -project photo-export.xcodeproj \
  -scheme "photo-export" \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Run from Xcode (**Run** ⌘R) or launch the built `Photo Export.app`.

## Prerequisites

- **macOS 15.0+**, Photos with iCloud Photos enabled, assets downloaded
  locally. iCloud-only assets whose originals aren't on the Mac may show
  `"Edited version was not provided by Photos. Future exports will try
  again."` — that's iCloud, not the app.
- **Two empty folders** as test destinations. Switch between them when a
  scenario needs a clean slate.
- A small set of seed assets in Photos. Suggested:

| ID | What | Notes |
|---|---|---|
| **PA-1** | Plain photo, no edits | Any unedited JPEG |
| **PA-2** | Edited JPEG | Apply any edit in Photos |
| **PA-3** | Edited HEIC with JPEG-rendered edit | Edited HEIC from iPhone |
| **PA-4** | Edited video | Trim or filter |
| **PA-5** | Two photos in same month with same `IMG_TEST.JPG` filename, one edited |
| **PA-6** | Asset whose actual original filename is `vacation_orig.JPG` (rename to test the `_orig` collision corner case) |

Reset state between groups: pick a fresh empty destination and (in
**File → Choose Different Folder…**) point the app at it. Records reset
because tracking is per-destination.

---

## Group A — Default mode

Toggle **Include originals** OFF.

### A1 — Plain photo writes original
1. Export PA-1 by clicking **Export Month** for its month.
2. Expected: destination has `IMG_<n>.JPG` only. No `_orig` companion.
3. Detail pane: `Original: Exported …`. No "Edited" row.

### A2 — Edited JPEG writes the edit at the natural stem
1. Export PA-2.
2. Expected: destination has `IMG_<n>.JPG` (the edited bytes) at the
   natural stem. No `_orig`. No `_edited`.
3. Detail pane: `Edited: Exported …`. No "Original" row.

### A3 — Edited HEIC + JPEG-rendered edit writes JPEG at natural stem
1. Export PA-3.
2. Expected: destination has `IMG_<n>.JPG` only (the JPEG-rendered
   edit). No HEIC. No `_orig`.

### A4 — Edited video writes the edited bytes
1. Export PA-4.
2. Expected: destination has `IMG_<n>.MOV` (or whatever the original
   extension is — the rendered edit keeps the source container). No
   `_orig`. The toolbar may briefly show `(downloading…)` while Photos
   prepares the source, then `(rendering…)` while AVFoundation writes
   the edit.

### A4b — Edited video with Include originals
1. Toggle **Include originals** ON.
2. Export PA-4.
3. Expected: destination has both `IMG_<n>.MOV` (rendered edit) and
   `IMG_<n>_orig.MOV` (original bytes). Both files share the same
   container; `_orig` suffix is the only filename difference. First plays
   the edit, second plays the full original.

### A4c — Edited iCloud-only video
1. Make sure PA-4 (or another adjusted video) is iCloud-only on this Mac.
2. Export.
3. Expected: download + render + write all succeed; toolbar transitions
   `(downloading…)` → `(rendering…)`. No error.

### A4d — Edited slow-motion video
1. Edit a slow-motion video in Photos (trim or filter).
2. Export.
3. Expected: rendered output preserves the slow-motion segment; visual
   matches Photos playback.

### A4e — Cancel mid-render
1. Start an export of a long edited video.
2. Click cancel while the toolbar shows `(rendering…)`.
3. Expected: queue stops within ~1–2 seconds (not instant —
   `AVAssetExportSession` wind-down is acceptable). No partial file at
   destination. The cancelled variant has no `.failed` record (the
   in-progress record is removed instead). The 1–2 second wait is
   expected, not a bug.

### A4f — Edited cinematic-mode video (iPhone 13 Pro+)
1. Edit a cinematic-mode video in Photos.
2. Export.
3. Expected: flat rendered output matching Photos' preview of the
   user-chosen focus track.

### A4g — Edited HDR video (iPhone 13+) — empirical
1. Edit an HDR video in Photos.
2. Export.
3. Open the result on an HDR-capable display alongside the Photos
   preview. Acceptance: visual match (HDR preserved). If degraded to
   SDR, document as known limitation; turn on **Include originals** to
   keep an HDR copy of the source bytes via the `_orig` companion.

### A4h — Re-edit after a successful export
1. Export PA-4.
2. Re-edit PA-4 in Photos.
3. Export again.
4. Expected: second export creates `IMG_<n> (1).MOV`; original
   `IMG_<n>.MOV` is not overwritten.

### A4i — Trim + adjust combined edits
1. In Photos, trim a video AND apply a colour adjustment.
2. Export.
3. Expected: both adjustments visible in the rendered output.

### A4j — Adjustment rollback before render
1. Edit a video in Photos. Queue an export.
2. Before the render starts, revert the edit in Photos.
3. Expected: render completes (Photos returns the original bytes); no
   error; record store clean.

### A4k — Unsupported-extension fallback (verification gate)
1. Find or synthesise a video in Photos whose original extension is
   `.avi` or `.mkv`.
2. Edit it.
3. Run the export.
4. Open the result in QuickTime.
5. Acceptance: plays correctly. **Failure mode:** if the file is
   unplayable, switch `selectEditedProducer` to refuse-mode for
   unsupported extensions per the resolved-decisions section of the
   plan.

---

## Group B — Include originals toggle

Pick a fresh destination.

### B1 — Toggle on for an edited photo writes both
1. Toggle **Include originals** ON.
2. Export PA-2.
3. Expected: destination has `IMG_<n>.JPG` (the edit) AND
   `IMG_<n>_orig.JPG` (the original bytes).
4. Repeat with PA-3: destination has `IMG_<n>.JPG` (edit) and
   `IMG_<n>_orig.HEIC` (original bytes).

### B2 — Toggle off again does not remove existing companions
1. With B1's state intact, toggle **Include originals** OFF.
2. Export the same month again. Expected: empty-run message
   "This month is already exported." No files removed.

### B3 — Toggle state survives quit/relaunch
1. With toggle ON, quit and relaunch the app.
2. Expected: toggle is still ON.

---

## Group C — Collisions

### C1 — Two same-name photos in default mode
1. Toggle OFF. Export PA-5's month.
2. Expected: `IMG_TEST.JPG` (one of them) and `IMG_TEST (1).JPG` (the
   other). The edited one writes its edit at whichever stem it landed on.

### C2 — Same setup with toggle on adds `_orig` companions
1. Pick a fresh destination. Toggle ON. Export PA-5's month.
2. Expected: the unedited PA-5 lands at `IMG_TEST.JPG` (no `_orig`).
   The edited PA-5 pairs at the next stem `IMG_TEST (1).JPG` and
   `IMG_TEST (1)_orig.JPG`.

### C3 — Step-1 fail-path guard
1. Pick a fresh destination. Toggle OFF. Export an edited PA-2 (writes
   `IMG_<n>.JPG`).
2. Manually drop a stray `IMG_<n>_orig.JPG` into the destination
   (any contents).
3. Toggle ON and export again.
4. Expected: the original variant fails with an error "Paired original
   filename already exists on disk: IMG_<n>_orig.JPG". The stray file
   is untouched. The detail pane shows `Original failed: …`.

---

## Group D — Empty-run feedback

### D1 — Already exported
1. Run an export. Run it again.
2. Expected: toolbar shows "This month is already exported." (or year/
   destination scope).

### D2 — Toggle off → on adds new work
1. Default mode export of an edited photo. Then toggle ON, run again.
2. Expected: new `_orig` companion is exported. No empty-run message.

### D3 — Toggle locked during active export
1. Click Export All; while it runs, observe the **Include originals**
   toggle.
2. Expected: toggle is disabled. Tooltip "Available after the current
   export finishes."

---

## Group E — Recovery

### E1 — Cancel mid-export and resume
1. Start a large export. Click **Cancel**. Click **Export All** again.
2. Expected: the cancelled asset is retried; previously-completed
   assets are skipped.

### E2 — Force-quit and resume
1. Start an export. Force-quit the app (⌘⌥Esc or Activity Monitor).
   Relaunch.
2. Expected: previously in-progress variant becomes `failed` with
   "Will retry on next export". The next Export All retries it.

---

## Group F — Sidebar / detail

### F1 — Sidebar counts mean what they say
1. With both modes, open a month with mixed edited and unedited assets.
2. Expected: sidebar shows `<exported>/<total>` with no "edited"
   qualifier. Counts match the asset detail pane's per-asset state for
   typical (non-edge) cases.
3. **Documented under-count:** for an asset whose actual filename is
   `vacation_orig.JPG` (PA-6), the sidebar under-counts by 1 even after
   it's correctly exported. The asset detail pane and `MonthContentView`
   summary remain correct.

### F2 — Detail pane variant rows
1. Click an exported asset.
2. Expected: detail pane shows `Original: Exported …` and (if adjusted)
   `Edited: Exported …` rows with timestamps. Failed variants render
   with their error message.

### F3 — Thumbnail dot reacts to toggle
1. With toggle OFF, an edited asset already exported as `.edited.done`
   shows a "fully exported" dot.
2. Toggle ON: dot disappears for that asset because the `_orig`
   companion is now required and missing.
3. Run Export All; dot returns once the companion is written.

---

## Group G — Onboarding

Reset onboarding by deleting the `hasCompletedOnboarding` `UserDefaults`
flag (or use a fresh user) and relaunch.

### G1 — First-run with toggle off
1. Walk through onboarding leaving the **Include originals for edited
   photos** checkbox unchecked.
2. Click **Start Export**. Expected: default-mode export begins.

### G2 — First-run with toggle on
1. Walk through onboarding with the checkbox checked.
2. Click **Start Export**. Expected: include-originals export begins.

---

## Group H — Import existing backup

### H1 — Default-mode export then import
1. With toggle OFF, export some assets (mixed edited + unedited).
2. Reset records (delete the destination's records dir) and click
   **File → Import Existing Backup…**.
3. Expected: every file matched. **Documented limitation:** for
   same-extension adjusted assets (JPEG original + JPEG edit at the
   natural stem), the file is classified as `.original` because the
   filename alone can't distinguish edited bytes from original bytes.
   The next default-mode export will see `.edited` not done and
   re-export at a `(1)` suffix — one duplicate per such asset, then
   steady state.

### H2 — Toggle-on export then import (lossless)
1. With toggle ON, export adjusted assets so each has a `_orig`
   companion.
2. Reset records and import.
3. Expected: every file matched without ambiguity. `_orig` companions
   classify as `.original`; natural-stem files classify as `.edited`
   (cross-extension) or `.original` (same-extension; the `_orig`
   companion still pins the asset).

---

## Group I — Accessibility

### I1 — VoiceOver
1. Enable VoiceOver. Tab to the **Include originals** toggle.
2. Expected: VoiceOver reads "Include originals for edited photos,
   button. Off by default. Turn on to keep original-bytes copies
   alongside edited photos."

---

## Group J — Library observation

### J1 — User edits a photo after export
1. Default mode. Export PA-1 (unedited).
2. In Photos, edit PA-1 and save.
3. Re-run Export Month.
4. Expected: a new `IMG_<n> (1).JPG` (the edit) appears next to the
   existing `IMG_<n>.JPG` (the unedited original). One-time documented
   duplicate — subsequent runs are steady state. Detail pane shows
   both the original and edited rows with timestamps.

---

## Group K — Other shipped behaviours

### K1 — Pause/resume
1. Start an export. Click pause. Wait. Click resume.
2. Expected: the queue picks up where it left off.

### K2 — Stale `.tmp` cleanup
1. Pre-seed a stray `IMG_X.JPG.tmp` in the destination's month folder.
2. Run an export of that asset.
3. Expected: the stale `.tmp` is removed and replaced with the final
   file. No leftover `.tmp` files after the run.

### K3 — Visible mid-toggle inconsistency
1. Default-mode export half a library. Toggle ON. Export the rest.
2. Expected: the first half has no `_orig` companions; the second half
   does. There is no automatic backfill for previously-exported assets;
   the next manual Export All picks up the missing companions.
