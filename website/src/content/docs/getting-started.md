---
title: Getting Started
description: How to install and use Photo Export on your Mac.
---

Photo Export is a native macOS app that exports your Apple Photos library to local or external storage. Browse two ways: a **Timeline** view organized by year and month, or a **Collections** view that lists your Favorites and every album you've created in Photos. (Smart albums other than Favorites and shared albums aren't included.)

## Prerequisites

- **macOS 15.0** or later
- **iCloud Photos enabled** — Photo Export reads your local Photos library via Apple's PhotoKit framework. It sees exactly what the built-in Photos app sees. For your iCloud photos to appear, iCloud Photos must be turned on: go to **System Settings → Apple Account → iCloud → Photos** and make sure it's enabled.

:::note
Photo Export uses only Apple's official PhotoKit API — no private APIs, no reverse engineering, no iCloud credentials. This means it works reliably across macOS updates and never accesses anything outside what the Photos app itself can see.
:::

## Download

Photo Export is available through two channels:

- **[Mac App Store](https://apps.apple.com/app/photo-export-local-backup/id6761410742)** — Automatic updates, trusted distribution. Your purchase supports development of an open-source project.
- **GitHub Releases (free)** — Download the latest `.dmg` from the [GitHub Releases page](https://github.com/valtteriluomapareto/photo-export/releases). Open the DMG and drag Photo Export to your Applications folder.

Both versions are identical in functionality, signed and notarized by Apple.

## First launch

### 1. Grant Photos access

On first launch, macOS will prompt for **Photos library access**. Click **Grant Access** to allow the app to read your photo and video library.

If you choose **Select Photos**, the app will work with only the photos you pick. If you accidentally deny access, you can change permissions later in **System Settings → Privacy & Security → Photos**, or click the "Open System Preferences" button shown in the app.

### 2. Choose an export destination

An onboarding screen will guide you through selecting the folder where photos and videos will be exported. This can be:

- A folder on your Mac (e.g. Desktop, Documents, or a dedicated backup folder)
- An external USB or Thunderbolt drive
- A network volume (if mounted)

The folder needs to be writable. The app remembers your choice across launches using a security-scoped bookmark.

### 3. Start exporting

Once the destination is set, you'll see the main window with a **Timeline / Collections** segmented control above the sidebar and a **thumbnail grid** in the center.

- **Timeline** — browse year by year, month by month. Click a month to see its photos. Click **Export Month** in the grid header to export that month, or **Export All** in the toolbar to queue the entire library.
- **Collections** — see your **Favorites** at the top, then every album and folder from Photos beneath. Click an album to see its photos, then **Export Favorites** or **Export Album** in the grid header. To queue every user album in one go, use **Export All Albums** in the toolbar (Favorites is excluded — it has its own button). Albums under Photos folders preserve their hierarchy on disk (e.g. `Collections/Albums/Trips/Iceland/`).

A few extras that work in both views:

- The **Include originals** toggle in the toolbar chooses what gets written. Off (default) exports one file per asset, in the version Photos shows. On adds a `_orig` companion for any photo or video edited in Photos so you keep a copy of the original bytes.
- Edited videos render through Photos and may take longer than copying — especially for 4K or iCloud-only originals. The toolbar may briefly show `(downloading…)` while Photos prepares the source, then `(rendering…)` while the edit is applied.
- **File → Import Existing Backup...** (Cmd+Shift+I) rebuilds local state to match the destination on disk. It adopts any files that are already there as exported, and prunes records for files that have since been deleted — useful both on a fresh install and when you've manually cleared part of a backup folder.

Export progress is shown in the toolbar. You can pause, resume, or cancel at any time.

### Troubleshooting

- **"Export folder is not reachable"** — Check that the external drive is plugged in and mounted.
- **"Export folder is read-only"** — Right-click the folder, choose Get Info, and make sure you have write permission.
- **Photos permission denied** — Open **System Settings → Privacy & Security → Photos** and enable access for Photo Export.
- **Export stuck near 100%** — Use **Help → Save Diagnostic Report…** to write a text file listing every photo whose export is in `failed` or `in-progress` state, including the underlying error message. Attach it to a [GitHub issue](https://github.com/valtteriluomapareto/photo-export/issues) so the cause is visible.

## Updates and distribution channels

Photo Export is distributed through two channels. Both versions are identical in functionality.

- **Mac App Store** users receive updates automatically through the App Store.
- **GitHub Releases** users should check the [Releases page](https://github.com/valtteriluomapareto/photo-export/releases) for new versions.

Both builds can be installed on the same Mac simultaneously — they use separate bundle identifiers and separate data (export history, bookmarks, preferences).

### Switching between channels

If you want to move from one channel to the other:

1. Install the new channel's build
2. Select the same export folder you used before
3. Go to **File > Import Existing Backup...** (Cmd+Shift+I) — this scans the destination folder, matches exported files to your Photos library, and rebuilds the export history so future exports skip already-exported assets

Without step 3, the new build treats the destination as fresh and may create duplicate files.

## Build from source

If you prefer to build from source or want to contribute:

```bash
git clone https://github.com/valtteriluomapareto/photo-export.git
cd photo-export
open photo-export.xcodeproj
```

Press Run (Cmd+R) with the `photo-export` scheme selected. Requires Xcode 16.2+.

See the [Contributing guide](https://github.com/valtteriluomapareto/photo-export/blob/main/CONTRIBUTING.md) for more details on development setup, running tests, and linting.
