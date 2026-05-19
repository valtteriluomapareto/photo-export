# Manual Testing Guide — Collections Export

Date: 2026-04-30
Feature: Collections export (Favorites + user albums)
Parent plan: `collections-export-plan.md`

## Goal

Verify by hand that the new Collections section behaves correctly across the cases unit tests cannot cover: PhotoKit integration, the segmented sidebar selector, sibling-collision behavior on the filesystem, rename behavior, and the corruption-recovery alert.

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

Then run the resulting `Photo Export.app` from the build output.

## Setup

- Pick an export folder (external drive recommended, but a local folder is fine for most cases).
- In Photos.app:
  - Have at least 5 photos marked as favorites.
  - Have at least one user-created album with a few photos.
  - Have at least one folder containing one or more albums (nested album case).

## Scenarios

### 1. Section selector

**Goal:** the Timeline / Collections selector flips between sidebars without losing the per-section selection.

1. Launch the app on the timeline view; pick a specific month.
2. Click **Collections** in the segmented selector.
3. Pick **Favorites** in the collections sidebar.
4. Click back to **Timeline**.
   - Expected: the previously-selected month is still highlighted; the asset grid shows that month again.
5. Click back to **Collections**.
   - Expected: Favorites is still selected.

### 2. Favorites export

1. With **Collections** active, select **Favorites**. The grid shows the favorited assets.
2. Click **Export Favorites**.
3. After the export finishes:
   - On disk, every favorited photo lands under `<root>/Collections/Favorites/`.
   - The sidebar Favorites row shows the green checkmark badge.
   - The grid header shows `N/N exported`.

### 3. Album export, including nested folder

1. Select an album that lives at the top level. Click **Export Album**.
   - Files land under `<root>/Collections/Albums/<Album Title>/`.
2. Select an album nested inside a folder. Click **Export Album**.
   - Files land under `<root>/Collections/Albums/<Folder Title>/<Album Title>/`.
3. Album titles with characters that need sanitization (e.g. `Family / 2025`) get translated to a safe folder name; the in-app sidebar still shows the original title.

### 4. Sibling-collision disambiguation

1. In Photos.app create two albums with identical titles in the same folder (e.g. two `Trips` albums at the root).
2. Export both, in any order.
   - Expected: the first export gets the bare path (`Collections/Albums/Trips/`), the second gets `Collections/Albums/Trips_2/`. The on-disk paths are stable across subsequent exports of the same album.
3. Re-export the first one.
   - Expected: still lands at the bare path; nothing moves.

### 5. Album rename

1. Export an album. Note the on-disk folder name and contents.
2. Rename the album in Photos.app.
3. Re-select the album in Collections sidebar; export again.
   - Expected: a **new** folder is created under `Collections/Albums/<New Name>/` with the assets. The old folder remains on disk untouched.
4. The in-app sidebar shows only the renamed album (the old placement record is preserved internally for collision detection but is not surfaced).

### 6. Cross-store independence

1. Export a single asset under both Timeline and Favorites.
2. On APFS the second copy is a CoW clone (verify with `du -sh` or free-space delta on a known-size source); on non-APFS it is a plain copy.
3. Force a failure on the favorites side (e.g. disconnect the destination mid-run).
   - Expected: the timeline record for that asset is unchanged. The favorites record reflects the failed variant.

### 7. Cancel mid-album export

1. Start exporting a large album.
2. Click **Cancel** in the toolbar.
   - Expected: the queue clears; the in-flight asset's variant is removed from the collection store, not committed as `.failed`.
3. Re-running the export resumes from the next missing asset; the previously written assets are not re-exported.

### 8. Corruption-recovery alert

1. Quit the app.
2. Manually corrupt the collection-records snapshot file:
   ```bash
   echo 'corrupt' > "$HOME/Library/Containers/com.valtteriluoma.photo-export/Data/Library/Application Support/com.valtteriluoma.photo-export/ExportRecords/<destinationId>/collection-records.json"
   ```
3. Launch the app and navigate to Collections.
   - Expected: the **Collection Records Could Not Be Read** alert shows.
4. Click **Reset**.
   - Expected: the corrupt file is renamed to `collection-records.json.broken-<timestamp>`. The store is reset to empty; further exports rebuild the records.
5. The timeline store is unaffected — Timeline sidebar still shows correct progress.

### 9. Limited Photos access

1. Toggle Photos access for the app to "Selected Photos…" with a small subset.
2. Verify that the Collections sidebar reflects only the visible assets:
   - Favorites count = favorites within the selected subset.
   - Albums show counts only for the selected subset.
3. Re-grant full access; counts update without restart.

## Regression checks

- Verify the timeline export workflow is unchanged: month export, year export, "Export All", queue pause/resume, import existing backup.
- Verify the **Include originals** toggle still controls variant selection on collection exports.
- Verify the destination indicator and toolbar progress slot still work for collection runs.
