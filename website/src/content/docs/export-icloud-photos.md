---
title: How to Export iCloud Photos to an External Hard Drive
description: Step-by-step guide to exporting your iCloud and Apple Photos library to an external hard drive or local folder on Mac using the free Photo Export app.
---

If your iCloud Photo Library contains thousands of photos and you want a local backup on an external hard drive, Photo Export makes it simple. This guide walks you through the process.

## What you need

- A Mac running **macOS 15.0** or later
- **iCloud Photos enabled** on your Mac — go to **System Settings → Apple Account → iCloud → Photos** and make sure it's on. Photo Export reads your local Photos library through Apple's PhotoKit framework (the same API the built-in Photos app uses), so your iCloud photos need to be syncing to this Mac.
- An external hard drive, USB drive, or any local folder
- The Photo Export app — [on the Mac App Store](https://apps.apple.com/app/photo-export-local-backup/id6761410742), or [free on GitHub](https://github.com/valtteriluomapareto/photo-export/releases)

## Step 1: Download and install Photo Export

**[Mac App Store](https://apps.apple.com/app/photo-export-local-backup/id6761410742)** — Install directly from the App Store for automatic updates. Your purchase supports ongoing development.

**GitHub Releases (free):**

1. Download the latest `.dmg` from the [GitHub Releases page](https://github.com/valtteriluomapareto/photo-export/releases).
2. Open the DMG and drag **Photo Export** to your Applications folder.
3. Launch the app. It is signed and notarized by Apple, so it will open without Gatekeeper warnings.

## Step 2: Grant Photos library access

When you first open Photo Export, macOS will ask you to grant access to your Photos library. Click **Allow** to continue. This lets the app read your iCloud and Apple Photos library.

## Step 3: Choose your export destination

Click **Choose Folder** and select your external hard drive or any local folder. The app remembers your choice, so you only need to do this once.

## Step 4: Browse and export

Browse your library two ways via the **Timeline / Collections** segmented control above the sidebar:

- **Timeline** — your library by year and month. Click a month to preview its thumbnails and full-size photos.
- **Collections** — your **Favorites**, every album and folder you've created in Photos, and any **iCloud shared albums** you participate in. Click an album to preview its contents. Shared albums sit in their own sidebar section because they export at reduced quality — see [Shared albums (reduced fidelity)](/photo-export/features/#shared-albums-reduced-fidelity). (Smart albums other than Favorites aren't included.)

The selected full-size preview follows edits and reverts in Photos without needing to select another asset. It keeps the current image visible while the revised version loads.

The selected asset’s detail pane shows export history for the scope you are browsing. An album’s history is separate from its Timeline and Favorites copies; after an album rename or move, details refer to the current export folder.

New sibling albums with case-only names, such as `Trip` and `trip`, receive separate export
folders; Shared Albums follow the same rule. Previously tracked folders keep their paths.
For an older mixed backup, export the affected albums to a **new empty destination folder**
and retain the old backup until the new copies are verified. See [album folder names](/photo-export/features/#album-folder-names).

Once you've picked a scope, decide what to write. Open **Settings → Advanced** (Cmd+, or the toolbar's Settings cog) for three toggles:

- **Include originals for edited photos** — off (default) exports one file per photo, in the version Photos shows. Edited photos write the edit; unedited photos write the original. On adds a `_orig` companion (e.g. `IMG_0001_orig.HEIC`) for any photo with edits in Photos so you keep a copy of the original bytes.
- **Convert HEIC to JPEG** — off (default) preserves HEIC and HEIF captures in their original format. On re-encodes HEIC captures as high-quality JPEG on export — useful if your destination (a NAS, a Windows PC, an older photo viewer) doesn't understand HEIC. Non-HEIC photos are unaffected. Applies to new exports — re-run an Export action to convert HEICs already on disk.
- **Separate videos into a subfolder** — off (default) keeps photos and videos in the same month or album folder. On routes standalone videos into a `videos/` subfolder (e.g. `2026/03/videos/IMG_0002.MOV`) so a backup doesn't mix `.JPG` and `.MOV` files together. The paired video of a Live Photo stays next to its still. Applies to new exports — videos already on disk stay where they are; turning this on later produces a mixed layout until you re-export the affected months.

Then export:

- **Timeline:** navigate to a month and click **Export Month**, or click **Export All** in the toolbar to queue the whole library.
- **Collections:** select **Favorites** or any album and click **Export Favorites** / **Export Album**, or click **Export All Albums** in the toolbar to queue every user album in one go (Favorites is excluded — it has its own button).

The app organizes the output on disk:

- Timeline exports land in a `Year/Month/` folder structure (e.g. `2025/06/IMG_0001.JPG`).
- Favorites land in `Collections/Favorites/`.
- Albums land in `Collections/Albums/<Album>/`. Albums under Photos folders preserve their hierarchy (e.g. `Collections/Albums/Trips/Iceland/`).

If any photos are stored only in iCloud, the app automatically downloads the originals during export. Unedited photos never produce a `_orig` companion — there is nothing to pair with.

**Live Photos** export as still-only by default. Turn on Settings → Advanced →
**Export Live Photos as paired image + video** to also write the paired video
next to the still (e.g. `IMG_0001.HEIC` alongside `IMG_0001.MOV`) using whatever
extension casing PhotoKit reports for that resource — typically `.MOV` on Apple
hardware. With **Include originals** on, the `_orig` companions are also paired
(e.g. `IMG_0001_orig.HEIC` + `IMG_0001_orig.MOV`). The paired video is typically
1–3 MB per Live Photo — libraries with thousands of them roughly double in size on
disk when the toggle is on. Shared-album Live Photos stay still-only regardless of
the setting because Apple doesn't expose the paired video for assets that live
only in a shared album.

If an original-side file reached its paired slot before the app stopped, a retry can
recover it when history still identifies that exact interrupted filename and folder.
The app verifies a non-empty regular file and checks the resource size when known;
foreign or mismatched files remain conflicts. Conflicts require a manual retry rather
than repeating on Auto Export's timer. This recovery does not cover edited renders,
unrecorded first files, or history whose interruption marker was already replaced by
an earlier collision failure.

Edited videos render on your Mac during export, which is slower than copying — expect 4K
iCloud videos to take noticeably longer per file than a plain copy would. Plain copies
remain fast.

## Resuming an interrupted export

If the export is interrupted — you unplug the drive, close the app, or your Mac goes to sleep — you can resume and the app will skip most already-exported files. In rare cases (e.g. a crash mid-write), a file may be copied again, but no data is lost.

After a manual export finishes, the progress strip briefly shows **Export complete** on success. If any asset job fails, it instead shows **N exported · M failed** with **View Issues**, which opens **Settings → Export Issues**. A job that fails on several photo/video versions counts once; successfully exported versions remain tracked. Failed scans, cleared pending work and export-history save errors show an incomplete or stopped explanation. Failure feedback stays until you dismiss it or start another run. A full destination or denied write access stops the current run immediately and shows the reason. Unattempted assets keep their history and do not gain failure rows. Fix the destination, then start a new export; the stopped queue is cleared, and the new run skips versions already exported. Dismissal and success expiry hide the finished strip without changing export history. Explicit cancellation clears the feedback; an unavailable destination remains explained above the strip.

## Rebuilding state from an existing backup

If you reinstall the app, switch builds, or restore your data on a new Mac, **File → Import Existing Backup…** rebuilds local export state from disk. It scans the destination, matches files to your Photos library, and adopts what's already there as exported. As part of the same step, it **prunes records for files that are no longer on disk** — for example if you deleted a folder, recreated it empty under the same name, or removed individual exports. Matched files retain their actual year/month folder, even when a timezone change or a Photos date adjustment places the asset in an adjacent month. The next export skips the imported asset instead of creating another copy in its current Photos month.

Import preserves any completed history already tracked in another month, skipping conflicting matches. The matched count reports files matched to Photos, including those already tracked; it is not a count of newly adopted records. If reconciliation removes an old record whose file is missing, run import again to adopt a matching file in another month.

Import stops with a visible error if a recognized backup folder cannot be read or a
tracked file cannot be verified. Permission and drive/share errors do not count as
missing files. The affected history check keeps its whole batch of records; invalid
stored locations and files replaced by directories also require attention rather than
silently removing tracking. A folder-scan failure happens before history changes.
A later verification failure can leave earlier matched files and verified progress
saved. Restore access, then use **Retry**; missing optional `videos/` folders remain normal.

If timeline history is corrupt, choose **Reset and Rebuild from Folder…** in its recovery alert to reset tracking and immediately run Import Existing Backup. **Reset Records** alone leaves tracking empty; exporting before rebuilding can create duplicate copies. Rebuilding requires Photos access, a connected readable destination, and no export or import already running. If both history stores need recovery, reset timeline history, resolve the collection alert, then choose **File → Import Existing Backup…**. Favorites and album history [cannot yet be rebuilt from disk](https://github.com/valtteriluomapareto/photo-export/issues/106); resetting it and re-exporting can create duplicate collection copies.

If an import fails, the sheet stops showing progress and explains the error. **Close** lets you reconnect the drive or reselect the export folder; **Retry** becomes available when the folder and export history are ready. Read-only backup folders remain valid for importing. If either history store reports a storage or corruption problem, close the import sheet and resolve the export-history alert before retrying. Cancelling or invalidating an old import cannot replace a newer import’s result or error.

## If an export gets stuck

If the progress fraction stops climbing or you suspect specific photos are failing, use **Help → Save Diagnostic Report…**. The app writes a plain-text file listing every photo whose export is in `failed` or `in-progress` state, along with the underlying error message (e.g. iCloud download failure, disk full). If a previous Auto Export run was interrupted by the operating system (rare, but possible on very large libraries), the report also names which scope was in flight at the time of the interruption. Attach the file to a [GitHub issue](https://github.com/valtteriluomapareto/photo-export/issues) so the actual failure cause is visible — it is otherwise only in the macOS unified log under the `com.valtteriluoma.photo-export` subsystem.

When Photos can't provide the edited version of an asset (`Edited resource unavailable` in the report), the app **falls back to writing the original instead**, with a `_orig` suffix on the filename — for example `IMG_4019_orig.MOV`. Once the original has been written, the asset is considered exported and won't be retried on future runs — the original is your backup. The diagnostic report flags these assets so you can see which ones used the original instead of the edit.

Export progress storage errors stop further exports using the affected records and show a Retry action. Restore storage access or free disk space, then retry while the app remains open to save retained progress without resetting history. Export runs acknowledge record writes before reporting completion. After an interrupted history write, valid recovered entries stay tracked when new exports add progress.

## Why use Photo Export instead of manually dragging photos?

- **Organized folders**: Photos are automatically sorted into `Year/Month/` folders instead of dumped into one giant directory.
- **Tracks what's exported**: The app remembers what's been exported. Run it again and it skips already-exported photos.
- **Pause and resume**: Long exports can be paused and picked up later. Cancelling and starting a new export keeps any unfinished scan from the cancelled run from affecting the new run. If a file has already moved into place, its history update finishes for the original destination before the next export proceeds, so cancellation and retry do not copy it again. An unfinished download, render or conversion cannot damage a restarted export or add failures to its result.
- **Open source**: No subscription, no account, no ads. MIT licensed. Free on GitHub, or [support the project on the Mac App Store](https://apps.apple.com/app/photo-export-local-backup/id6761410742).
