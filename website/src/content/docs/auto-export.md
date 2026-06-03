---
title: Auto Export
description: Keep an external drive automatically in sync with your Apple Photos library — Photo Export adds new photos to your backup as they appear in Photos, without you having to remember to click Export.
---

Auto Export is the **set-it-and-forget-it** mode of Photo Export. Once you turn it on and pick what to back up, Photo Export adds new photos to your destination as they appear in Apple Photos — you don't have to remember to click **Export**.

Auto Export runs while Photo Export is open. Turn on **Open Photo Export at login** and the app starts with your Mac, a menu bar icon gives you status at a glance, and Auto Export watches your library from the moment you sit down. Everything still happens locally through Apple's official Photos API — no cloud service, no separate background process, no account to sign in to.

## Turn it on

Open **Photo Export → Settings…** (Cmd+,) and switch to the **Auto Export** tab.

1. **Enable Auto Export** — turn the toggle on.
2. **What to Export** — pick at least one of:
   - **Timeline** — all photos and videos, organized by year and month.
   - **Favorites** — just the photos you've marked as favorites in Apple Photos.
   - **Albums** — every user album you've created in Photos.
   - **Shared Albums** — every iCloud shared album. Note: iCloud only provides downscaled JPEGs for shared photos, so the exported files are reduced quality and **Include originals** has no effect on them. See [Shared albums (reduced fidelity)](/photo-export/features/#shared-albums-reduced-fidelity).
3. (Optional) **Open Photo Export at login** — toggle on if you want the app to start automatically when you log in. Without this, Auto Export only runs when you've opened the app yourself.

That's it. Once a destination is selected and at least one category is on, Photo Export starts watching your library.

## What you'll see

Three places surface Auto Export status, all reading the same state:

- **Toolbar pill** (small status badge in the main window) — short label like _Up to date_, _Scheduled_, _Exporting_, _Waiting_, or _Action needed — no destination_. Click it to open Settings.
- **Menu bar item** — a small icon that's always present while Photo Export is running. Click for a menu with the same status, an enable/disable toggle, and an **Export Now** shortcut. Especially useful when the main window isn't open.
- **Settings → Auto Export** — a status row with a live countdown when a run is scheduled, plus the last-run summary once the first run finishes. A **Last updated** line shows when Photo Export last checked iCloud for new photos — it ages on its own so you can tell at a glance whether the background-check loop is alive.

## What triggers a run

You don't kick Auto Export manually for normal usage. A run starts on its own when:

- The app launches and the destination is reachable.
- The destination drive becomes available again after being unplugged.
- Photos reports new or edited photos in your library.
- You change which categories are selected, or toggle **Include originals**.
- A **periodic safety-net check** (every ~15 minutes) and an **on-app-active check** (whenever you switch back to Photo Export) catch newly-synced iCloud photos that macOS didn't otherwise notify Photo Export about. This matters most in long-running sessions where Photos.app isn't open — iCloud's change notifications to third-party apps can lag by tens of minutes in that case.

Photo Export waits a short while after each trigger before actually starting — so it doesn't fire mid-import or mid-edit. The wait is about 30 seconds for Photos library changes (the most common trigger), 10 seconds for app launch, 2–3 seconds for the smaller triggers, and up to 2 minutes for the rare "Photos catch-up" recovery path.

If you want to run a backup right now without waiting:

- **Settings → Auto Export → Export Now**, or
- **Menu bar icon → Export Now** (Cmd+Shift+E). The menu bar's Export Now is greyed out unless Auto Export is idle or already scheduled — use the Settings button in other states.

Manual exports (any **Export Year / Month / Folder / Album** button, in the toolbar or in a content pane) still work the same way they always have. If you click one while Auto Export is in the middle of a run, Photo Export asks whether to cancel the automatic run and start your manual one instead. Anything that was queued by the automatic run stays pending and Auto Export picks it up after your manual run finishes.

## Stopping a run

The toolbar's **Cancel** button stops the current export and also **turns Auto Export off** so it doesn't restart itself a few seconds later. The reasoning: pressing Cancel during an automatic run usually means "stop, don't keep going" — not "pause for 30 seconds." Re-enable Auto Export from **Settings → Auto Export** whenever you're ready to resume the watch.

## Failed exports and retry

Some failures are transient — Photos is busy, an iCloud original isn't ready to download, the network blinked. Auto Export records them per photo and **retries automatically, waiting longer between each attempt**: 30 seconds, then 2 minutes, then 10 minutes, then 1 hour, then every 6 hours.

Other failures need your attention — the destination drive is full, you've revoked write permission on the export folder, an asset has been deleted from Photos. Auto Export records these but won't retry on its own; you fix the underlying condition (free up space, restore permissions, etc.) and Photo Export picks the work back up on its next run. The **Retry** button described below works for any failure, but it only succeeds when the underlying problem is actually resolved — for a still-disconnected drive, the row will just fail again immediately.

Either way you can see everything that's failed in **Settings → Export Issues**, grouped by category:

- _Destination Unavailable_ — drive went away mid-run
- _Destination Permission_ — folder is read-only or write access has been revoked
- _Destination Out of Space_ — disk is full
- _Asset Missing_ — photo no longer exists in your library
- _Resource Unavailable_ — Photos couldn't provide the photo's data
- _Photos Library Transient_ — Photos was momentarily unavailable
- _iCloud / Network_ — couldn't download an iCloud-only original

Each row shows what was being exported, when it last failed, how many attempts have happened, and when the next automatic retry will fire. The **Retry** button next to a row clears that failure from the retry policy and kicks off an immediate run.

## Safety

Photo Export will **never delete or overwrite** files at your destination. This holds for both manual and Auto Export runs.

If you point Photo Export at a folder that already contains user-visible files (an existing backup, a folder with unrelated content), the app pauses and asks you to **confirm this destination** before it adds anything. Hidden system files like `.DS_Store` don't trigger the prompt. The confirmation persists for that destination — switching to it again later won't re-prompt. If you cancel, Auto Export stays blocked until you confirm or pick a different folder.

For folders the app has been writing to before, no prompt appears — its export records identify the destination as one of its own.

**If you've exported to this folder before but Photo Export shows no progress for it** — which can happen after updating the app or reconnecting an external drive — click **Review…** on the prompt and choose **Rebuild Records from Destination**. Photo Export scans what's already on the drive and rebuilds its progress from those files, so the next export skips them instead of writing duplicate copies. Choose **Use This Destination** only when the existing files are genuinely new content you placed there yourself. Your destination files are never touched either way.

## Open at login

Turn on **Open Photo Export at login** (in **Settings → Auto Export → Startup**) and the app starts automatically when you log in, the menu bar icon appears, and Auto Export watches your library from the moment you sit down at your Mac.

The first time you enable this, macOS may post a system notification confirming that Photo Export was added to your Login Items. If macOS marks the entry as "waiting for approval," Photo Export will show a button to open System Settings → Login Items where you can flip the switch.

If you're running Photo Export from a non-standard location (e.g. directly from a Downloads folder or from Xcode's build output), the toggle's footer may read _"Move Photo Export into your Applications folder to enable launch at login."_ macOS's launch-at-login service only registers apps installed in `/Applications` — move the app there and the toggle works.

## What Auto Export doesn't do

To keep the feature predictable, Photo Export is intentional about what's _not_ included:

- **It doesn't run when the app is fully quit.** This is intentional — Photo Export is a regular Mac app, not a background service. Use **Open at login** if you want it always running.
- **It doesn't delete or move files** at the destination — not when you remove a photo from Favorites, not when an asset is deleted from your Photos library, not when you change which categories are selected.
- **It doesn't connect to iCloud directly.** Photo Export reads through Apple's Photos framework, which talks to iCloud Photos on your behalf if you've enabled it in System Settings.
- **It doesn't surface per-album controls yet.** The **Albums** category covers every user-created album. Per-album include/exclude can land later if there's demand.

## Upgrading from Photo Export 1.2.3 or earlier

If you've been using Photo Export 1.2.3 or earlier, most of the update is invisible — your existing backup folder, exported files, and Photos library access all carry over untouched.

### Your files are safe

Before anything else: **Photo Export never deletes, overwrites, or moves files at your destination drive — not as part of this update, not as part of any recovery flow, not ever.** This is enforced everywhere in the code, including all the new Auto Export paths. If anything about the upgrade looks unfamiliar, your previously-exported photos are still where they were.

### What's new in the UI

After updating, you'll see three new surfaces — even with Auto Export turned off:

- A **small status pill** in the main-window toolbar, between the Destination indicator and Include Originals. Reads _Auto Export off_ in a subdued grey until you enable Auto Export. Click any time to open Settings.
- A **menu bar icon** that appears whenever Photo Export is running. Same status info as the pill, plus a quick Enable / Disable toggle and an Export Now shortcut.
- A **Settings window** (Cmd+, or **Photo Export → Settings…**) with two tabs: Auto Export and Export Issues.

Your manual export workflow is unchanged — same toolbar buttons, same Include Originals toggle, same Import Existing Backup… menu item, same Help → Save Diagnostic Report….

### Your export records carry over

Photo Export now identifies destinations using a more reliable internal id than 1.2.3 did. On first launch with the new build:

- For most users, the existing records are automatically recognized and used as-is — your manual export history is preserved and the next export resumes from where you left off.
- In rare cases (typically when alternating between the Mac App Store and GitHub-released builds, or when an unrelated I/O hiccup interrupts the rename), Settings → Auto Export shows a banner titled **"Destination Has Unresolved Issues"**. Click **Resolve…** and run **Rebuild Records from Destination** — this scans the destination's actual contents and rebuilds local records to match. **Nothing is removed or rewritten on your drive.**
- If the rename fails because of a transient issue (e.g. the destination drive briefly disconnected while the app was launching), reopen Photo Export with the drive mounted — the migration retries automatically.

If you've used the app with **multiple destinations**, each migrates independently the first time you point Photo Export at it. Plugging in a second drive later triggers its own migration.

### Auto Export is opt-in

Auto Export defaults to **off**. Nothing about your library or destination changes until you visit Settings → Auto Export and turn it on. If you've been using manual export and want to keep doing so, you can ignore the new UI entirely — the pill stays subdued and the menu bar icon is unobtrusive.

If you do enable Auto Export and you've been using the same destination folder all along, the safety prompt described in [Safety](#safety) above does **not** fire — Photo Export recognizes the folder from your existing records. You'll only see the safety prompt if you point Auto Export at a destination Photo Export hasn't been writing to before.

### Switching between Mac App Store and GitHub builds

If you're moving from one channel (Mac App Store or GitHub Releases) to the other:

1. Install the new build.
2. Pick your existing export folder.
3. Expect the **"Destination Has Unresolved Issues"** banner (the two builds store their state separately — the new build sees the folder as unfamiliar). Click **Resolve…** → **Rebuild Records from Destination**.
4. After that completes, Auto Export (if enabled) and manual exports both recognize the previously-exported files and skip them as before.

### Limited Photos library access

If in 1.2.3 you chose **Select Photos** rather than full Photos access, that limited access carries over. The toolbar pill may read _Action needed — limited Photos access_ once Auto Export is on; open Settings → Privacy & Security → Photos → Photo Export to grant full access if you want Auto Export to see your whole library, or leave it as is to keep Auto Export scoped to the selected subset.

### Things that _don't_ happen on upgrade

- Photo Export does not start a background scan of your library or destination on upgrade.
- Auto Export does not turn itself on. You have to enable it explicitly.
- The app does not delete, overwrite, or move any files at your destination — repeated for emphasis because it's the most common worry.
- macOS does not need you to re-grant Photos library access on upgrade. The granted access carries over.

### If something looks wrong after upgrading

- **The pill says _Action needed — destination needs review_ and Settings → Auto Export shows the "Destination Has Unresolved Issues" banner.** This is either the migration-conflict path (rare; both old and new record forms exist) or the safety-scan path (Auto Export turned on and pointed at a folder Photo Export hasn't seen before). Both resolve through Settings → Auto Export — click **Resolve…**. Your destination files are not touched either way.
- **The pill says _Action needed — limited Photos access_.** See the limited-library section above.
- **My manual exports look like they started over from zero.** Open **File → Import Existing Backup…** (Cmd+Shift+I) to rebuild local records from the destination's actual contents. This adopts existing files as already-exported and is the supported recovery path. Files on disk are unaffected.

## Troubleshooting

- **Toolbar pill says "Action needed — no destination"** — open Settings → Auto Export (click the pill) and the destination picker in the main window's toolbar. Pick a writable folder.
- **"Action needed — destination needs review"** — the safety scan found pre-existing files at the destination. Click **Review…** in Settings. If you've exported to this folder before, choose **Rebuild Records from Destination** to restore your progress; otherwise choose **Use This Destination** if those files are yours to keep.
- **"Action needed — pick what to export"** — open Settings → Auto Export and tick at least one category.
- **Auto Export status stays at "Waiting"** — usually the drive is disconnected or a manual export is in progress. The status row will tell you which. Reconnect the drive or wait for the manual run to finish.
- **A run failed but I fixed the underlying problem** — open Settings → Export Issues and click **Retry** on the affected row. If the entire destination changed (e.g. the drive was reformatted), use **File → Import Existing Backup…** to rebuild the local records first.
