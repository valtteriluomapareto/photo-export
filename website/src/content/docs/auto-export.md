---
title: Auto Export
description: Keep an external drive automatically in sync with your Apple Photos library — Photo Export adds new photos to your backup as they appear in Photos, without you having to remember to click Export.
---

Auto Export keeps an external drive (or any folder you choose) automatically in sync with your Apple Photos library. Once you turn it on and pick what to back up, Photo Export adds new photos as they appear in Photos — you don't have to remember to click **Export**.

Auto Export runs while Photo Export is open. Turning on **Open Photo Export at login** starts the app automatically when you log in, and a menu bar item lets you check status without opening the main window. Everything still happens locally on your Mac through Apple's PhotoKit API — no cloud service, no background daemon, no helper.

## Turn it on

Open **Photo Export → Settings…** (Cmd+,) and switch to the **Auto Export** tab.

1. **Enable Auto Export** — turn the toggle on.
2. **What to Export** — pick at least one of:
   - **Timeline** — all photos and videos, organized by year and month.
   - **Favorites** — just the photos you've marked as favorites in Apple Photos.
   - **Albums** — every user album you've created in Photos.
3. (Optional) **Open Photo Export at login** — toggle on if you want the app to start automatically when you log in. Without this, Auto Export only runs when you've opened the app yourself.

That's it. Once a destination is selected and at least one scope is on, Photo Export starts watching your library.

## What you'll see

Three places surface Auto Export status, all reading the same state:

- **Toolbar pill** in the main window — short label like *Up to date*, *Scheduled*, *Exporting*, *Waiting*, or *Action needed — no destination*. Click it to open Settings.
- **Menu bar item** — a small icon that's always present while Photo Export is running. Click for a menu with the same status, an enable/disable toggle, and an **Export Now** shortcut. Especially useful when the main window isn't open.
- **Settings → Auto Export** — a status row with a live countdown when a run is scheduled, plus the last-run summary once the first run finishes.

## What triggers a run

You don't kick Auto Export manually for normal usage. A run starts on its own when:

- The app launches and the destination is reachable.
- The destination drive becomes available again after being unplugged.
- Photos reports new or edited photos in your library.
- You change which scopes are selected, or toggle **Include originals**.

Photo Export waits briefly after each trigger — about half a minute after Photos changes — so it doesn't start exporting while you're still in the middle of importing or editing.

If you do want to run a backup right now without waiting:

- **Settings → Auto Export → Export Now**, or
- **Menu bar icon → Export Now** (Cmd+Shift+E from the menu).

Manual exports (the toolbar **Export All / Export Favorites / Export Album** buttons) still work the same way they always have. If you click one while Auto Export is in the middle of a run, Photo Export will ask whether to cancel the automatic run and start your manual one instead.

## Failed exports and retry

Some failures are transient — Photos is busy, an iCloud original isn't ready to download, the network blinked. Auto Export records them per asset and **automatically retries with backoff** — 30 s, 2 m, 10 m, 1 h, then capped at 6 h between attempts.

Other failures need your attention — the destination drive is full, you've revoked write permission on the export folder, an asset has been deleted from Photos. Auto Export records these but won't retry on its own; you fix the underlying condition, then either click **Retry** on the row or wait for a relevant change.

Either way you can see everything that's failed in **Settings → Export Issues**, grouped by category:

- *Destination unavailable* — drive went away mid-run
- *Destination permission* — folder is read-only or sandbox access has been revoked
- *Destination out of space* — disk is full
- *Asset missing* — photo no longer exists in your library
- *Resource unavailable* — Photos couldn't provide the asset's data
- *Photos library transient* — Photos was momentarily busy
- *iCloud / Network* — couldn't download an iCloud-only original

Each row shows what scope and variant failed, when it last failed, how many attempts have happened, and when the next automatic retry will fire. The **Retry** button next to a row clears that failure from the retry policy and kicks off an immediate run.

## Safety

Photo Export will **never delete or overwrite** files at your destination. This holds for both manual and Auto Export runs.

If you point Photo Export at a folder that already contains files (an existing backup, a folder with unrelated content, anything non-empty), the app pauses and asks you to **confirm this destination** before it adds anything. The confirmation persists for that destination — switching to it again later won't re-prompt. If you cancel, Auto Export stays blocked until you confirm or pick a different folder.

For folders the app has been writing to before, no prompt appears — its export records identify the destination as one of its own.

## Open at login

Turn on **Open Photo Export at login** (in **Settings → Auto Export → Startup**) for the simplest "set it and forget it" workflow: the app starts automatically when you log in, the menu bar item appears, and Auto Export watches your library from the moment you sit down at your Mac.

The first time you enable this, macOS may post a system notification confirming that Photo Export was added to your Login Items. If macOS marks the entry as "waiting for approval," Photo Export will show a button to open System Settings → Login Items where you can flip the switch.

## What Auto Export doesn't do

To keep the feature predictable, Photo Export is intentional about what's *not* included:

- **It doesn't run when the app is fully quit.** Background daemons and LaunchAgents are explicitly out of scope for this version. **Open at login** is the supported way to have Auto Export running when you're not actively in the app.
- **It doesn't delete or move files** at the destination — not when you remove a photo from Favorites, not when an asset is deleted from your Photos library, not when you change albums.
- **It doesn't connect to iCloud directly.** Photo Export reads through Apple's PhotoKit, which talks to iCloud Photos on your behalf if you've enabled it in System Settings.
- **It doesn't surface per-album controls yet.** The **Albums** scope covers every user-created album. Per-album include/exclude can land later if there's demand.

## Upgrading from Photo Export 1.2.3 or earlier

This release adds Auto Export plus several internal changes that touch how Photo Export identifies destinations. Most users won't notice anything beyond the new UI; this section explains what to expect and what to do if something looks off.

### What's new in the UI

After updating, you'll see three new surfaces — even with Auto Export turned off:

- A **status pill** in the main-window toolbar, sitting between the Destination indicator and Include Originals. Reads *Auto Export off* in a subdued style until you enable Auto Export. Click it any time to open Settings.
- A **menu bar icon** that appears whenever Photo Export is running. Same status info as the pill, plus a quick Enable / Disable toggle and an Export Now shortcut.
- A **Settings window** (Cmd+, or **Photo Export → Settings…**) with two tabs: Auto Export and Export Issues. The Settings menu item is standard macOS, but it didn't exist in 1.2.3 because there were no preferences to put there.

Your existing manual export workflow is unchanged — same toolbar, same Export All / Export Favorites / Export Album buttons, same Include Originals toggle, same Import Existing Backup… menu item.

### Your export records and destination

This release ships the Phase 0a destination-identity refactor. Photo Export now identifies your destination by a more stable fingerprint than 1.2.3 used. On first launch with the new build:

- The app looks for your existing records under both the old and new identifiers
- If only the old form exists, it's renamed in place to the new form — your export history is preserved and the next manual export resumes where you left off
- If both forms exist (rare — typically only if you alternated between Mac App Store and GitHub-released builds with incompatible state), Photo Export flags this as a **migration conflict** and shows a banner in Settings → Auto Export labeled **Destination Has Unresolved Issues**. Click **Resolve…** and run **Rebuild Records from Destination** — this rebuilds local records from the files actually present on your drive, then removes the legacy duplicate. **No files at the destination are deleted or moved.**

In neither case does Photo Export touch the photos themselves at your destination — see [the safety invariant](#safety) above.

### Auto Export starts off

Auto Export is opt-in. After updating, the toggle is **off** by default. Nothing about your library or destination changes until you visit Settings → Auto Export and turn it on. If you've been using manual export and want to keep doing so, you can ignore the new UI; the pill stays subdued and the menu bar icon is unobtrusive.

If you do enable Auto Export, the first time you point it at a destination that has files (an existing backup, the one you've been using manually all along), it will pause and ask you to **confirm this destination** — this is the safety scan, and the confirmation persists per destination. After confirming once, you won't be prompted again unless you switch to a different folder with pre-existing content.

### Things that *don't* happen on upgrade

To set expectations clearly:

- Photo Export does not start a background scan of your library or your destination on upgrade.
- Auto Export does not turn itself on. You have to enable it explicitly.
- The app does not delete, overwrite, or move any files at your destination — not as part of the update, not as part of the migration-conflict recovery, not as part of any safety scan. The [Safety Invariants](https://github.com/valtteriluomapareto/photo-export/blob/main/docs/project/plans/auto-sync-background-sync-plan.md#safety-invariants) section of the project plan documents this as a load-bearing rule.
- macOS does not need you to re-grant Photos library access on upgrade. The granted access carries over.

### If something looks wrong after upgrading

- **The pill says "Action needed" and Settings → Auto Export shows a destination-conflict banner.** That's the migration-conflict path described above. Click **Resolve…** in Settings and run **Rebuild Records from Destination**. Your destination files are not touched.
- **The pill says "Action needed — destination unsafe" with no banner mention of records conflict.** That's the safety-scan path — you've turned on Auto Export and pointed it at a destination that has pre-existing files. Click the pill, then **Resolve…** in the banner, then **Use This Destination**.
- **My manual exports started over from zero.** Open **File → Import Existing Backup…** (Cmd+Shift+I) to rebuild local records from the destination's actual contents. This adopts existing files as already-exported and is the supported recovery path. Files on disk are unaffected.
- **The menu bar icon is distracting.** A preference to hide it isn't shipped yet — feel free to [open an issue](https://github.com/valtteriluomapareto/photo-export/issues) if you'd find one useful.

## Troubleshooting

- **Toolbar pill says "Action needed — no destination"** — open Settings → Auto Export (click the pill) and the destination picker in the main window's toolbar. Pick a writable folder.
- **"Action needed — destination needs review"** — the safety scan found pre-existing files at the destination. Click **Resolve…** in Settings, then **Use This Destination** if those files are yours to keep.
- **"Action needed — pick what to export"** — open Settings → Auto Export and tick at least one scope.
- **Auto Export status stays at "Waiting"** — usually the drive is disconnected or a manual export is in progress. The status row will tell you which. Reconnect the drive or wait for the manual run to finish.
- **A run failed but I fixed the underlying problem** — open Settings → Export Issues and click **Retry** on the affected row. If the entire destination changed (e.g. the drive was reformatted), use **File → Import Existing Backup…** to rebuild the local records first.
