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
- **Collections** — your **Favorites** plus every album and folder you've created in Photos. Click an album to preview its contents. (Smart albums other than Favorites and shared albums aren't included.)

Once you've picked a scope, decide what to write:

- Use the toolbar's **Include originals** toggle to choose what to write. Off (default) exports one file per photo, in the version Photos shows — edited photos write the edit, unedited photos write the original. On adds a `_orig` companion (e.g. `IMG_0001_orig.HEIC`) for any photo with edits in Photos so you keep a copy of the original bytes.

Then export:

- **Timeline:** navigate to a month and click **Export Month**, or click **Export All** in the toolbar to queue the whole library.
- **Collections:** select **Favorites** or any album and click **Export Favorites** / **Export Album**, or click **Export All Albums** in the toolbar to queue every user album in one go (Favorites is excluded — it has its own button).

The app organizes the output on disk:

- Timeline exports land in a `Year/Month/` folder structure (e.g. `2025/06/IMG_0001.JPG`).
- Favorites land in `Collections/Favorites/`.
- Albums land in `Collections/Albums/<Album>/`. Albums under Photos folders preserve their hierarchy (e.g. `Collections/Albums/Trips/Iceland/`).

If any photos are stored only in iCloud, the app automatically downloads the originals during export. Unedited photos never produce a `_orig` companion — there is nothing to pair with.

Edited videos render on your Mac during export, which is slower than copying — expect 4K
iCloud videos to take noticeably longer per file than a plain copy would. Plain copies
remain fast.

## Resuming an interrupted export

If the export is interrupted — you unplug the drive, close the app, or your Mac goes to sleep — you can resume and the app will skip most already-exported files. In rare cases (e.g. a crash mid-write), a file may be copied again, but no data is lost.

## Rebuilding state from an existing backup

If you reinstall the app, switch builds, or restore your data on a new Mac, **File → Import Existing Backup…** rebuilds local export state from disk. It scans the destination, matches files to your Photos library, and adopts what's already there as exported. As part of the same step, it **prunes records for files that are no longer on disk** — for example if you deleted a folder, recreated it empty under the same name, or removed individual exports. The result always reflects the current contents of the destination.

## If an export gets stuck

If the progress fraction stops climbing or you suspect specific photos are failing, use **Help → Save Diagnostic Report…**. The app writes a plain-text file listing every photo whose export is in `failed` or `in-progress` state, along with the underlying error message (e.g. iCloud download failure, disk full). Attach the file to a [GitHub issue](https://github.com/valtteriluomapareto/photo-export/issues) so the actual failure cause is visible — it is otherwise only in the macOS unified log under the `com.valtteriluoma.photo-export` subsystem.

When Photos can't provide the edited version of an asset (`Edited resource unavailable` in the report), the app **falls back to writing the original instead**, with a `_orig` suffix on the filename — for example `IMG_4019_orig.MOV`. The natural-stem slot (where the edit would have lived) is left empty, so a future export run can still write the edited file there if Photos starts cooperating. The diagnostic report flags these assets so you can see which ones used the original instead of the edit.

## Why use Photo Export instead of manually dragging photos?

- **Organized folders**: Photos are automatically sorted into `Year/Month/` folders instead of dumped into one giant directory.
- **Tracks what's exported**: The app remembers what's been exported. Run it again and it skips already-exported photos.
- **Pause and resume**: Long exports can be paused and picked up later.
- **Open source**: No subscription, no account, no ads. MIT licensed. Free on GitHub, or [support the project on the Mac App Store](https://apps.apple.com/app/photo-export-local-backup/id6761410742).
