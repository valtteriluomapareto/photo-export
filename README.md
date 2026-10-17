# Photo Export

[![CI](https://github.com/valtteriluomapareto/photo-export/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/valtteriluomapareto/photo-export/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A free, open-source macOS app for backing up Apple Photos and iCloud Photos to normal folders on a local or external drive.

Export by year and month (`YYYY/MM/`), by Favorites, or by individual albums. Photo Export runs locally on your Mac using Apple's PhotoKit framework — no account, no cloud service, no subscription.

![Photo Export — timeline view, thumbnail grid, and full-size preview](website/src/assets/photo_export_screenshot.png)

## Download

- **[Mac App Store](https://apps.apple.com/app/photo-export-local-backup/id6761410742)** — paid. Automatic updates, and your purchase supports development.
- **[GitHub Releases](https://github.com/valtteriluomapareto/photo-export/releases)** — free. Same app, same features.

Both versions are signed and notarized by Apple. Project [website and docs](https://valtteriluomapareto.github.io/photo-export/).

## Privacy

Photo Export runs locally on your Mac. It uses Apple's PhotoKit framework to read the same library the built-in Photos app sees, **read-only** — it can't modify or delete anything in your Photos library. It does not upload your photos, use any third-party cloud service, require an account, or ask for your Apple Account password.

## Features

- Browse your library two ways via a Timeline / Collections segmented control
  - **Timeline** — by year and month
  - **Collections** — Favorites plus your Photos albums and folders
- Preview thumbnails and selected assets as the first batch loads. Detail export status follows the current Timeline, Favorites, album, or Shared Album placement, including recorded converted versions and recovery messages
- Photos changes refresh the grid in place and update selected details. A surviving selection stays selected; removing it selects the first remaining asset, and an empty scope clears details. Edited thumbnails and the selected full-size preview refresh; current images stay visible during replacement, and older refreshes or image responses cannot replace newer results
- Export a month, a year, an album, or the full queue without overwriting existing files
- Export preparation uses progressive Photos enumeration and yields between planning slices of at most 200 assets. Each scope commits after its scan succeeds; preparation can still retain scope-sized data.
- Timeline badges wait for fresh count pairs after Photos changes and reject obsolete refreshes. Historical sidebar summaries still approximate coverage from export records; replacing deleted photos with new photos at the same counts can overstate completion.
- Cmd/Shift-click rows in either sidebar to enqueue a mix in one run (e.g. multiple years on the Timeline, or Favorites + several albums + a folder on Collections). Selected folders expand to their nested albums; a selected year supersedes any individual month in it
- Collection completion follows the current album name and folder location. Renaming or moving an album starts progress for its new target; previous files and history stay in their original folders.
- Export Favorites or any album you've created in Photos to `Collections/Favorites/` or `Collections/Albums/<Album>/`, individually or via **Export All Albums** in the toolbar. Select a folder in the Collections sidebar to flip the primary action to **Export Folder** (every descendant album), or Cmd/Shift-click album tiles to enqueue an explicit selection
- Export **iCloud Shared Albums** one at a time to `Collections/Shared Albums/<Album>/`. Apple serves shared photos as downscaled JPEGs only, so Photo Export saves whatever Apple provides — originals aren't available for shared-album assets
- New sibling albums with case-only names receive distinct folders, including Shared Albums. Existing tracked paths stay unchanged; to separate an older mixed backup, export the affected albums to a new empty destination and keep the old backup until verified
- Choose what to write under **Settings → Advanced** (Cmd+,):
  - **Include originals for edited photos** — off (default) exports one file per asset in the version Photos shows; on adds a `_orig` companion (e.g. `IMG_0001_orig.HEIC`) for any photo or video edited in Photos so you keep a copy of the original bytes alongside the user-visible edit
  - **Convert HEIC to JPEG** — off (default) preserves the original HEIC/HEIF format; on re-encodes HEIC captures as high-quality JPEG on export, useful if your destination doesn't understand HEIC. Non-HEIC photos are unaffected. Applies to new exports — re-run an Export action to convert HEICs already on disk
  - **Separate videos into a subfolder** — off (default) keeps photos and videos in the same month or album folder; on routes standalone videos into a `videos/` subfolder (e.g. `2026/03/videos/IMG_0002.MOV`) so a backup doesn't mix `.JPG` and `.MOV` files together. The paired video of a Live Photo stays next to its still — splitting the pair across folders would break on-disk Live Photo recognition. Applies to new exports only; videos already on disk stay where they are
- **Auto Export** (opt-in; off by default) keeps a chosen destination automatically in sync with your Photos library: pick Timeline / Favorites / Albums in Settings → Auto Export, and Photo Export adds new photos as they appear in Apple Photos. Photos changes received during an export stay pending for a follow-up run. Switching destinations stops the old automatic run; its late results cannot change the new destination’s status or retry history. A periodic safety-net check (every ~15 minutes, plus whenever you switch back to the app) catches newly-synced iCloud photos even in long-running sessions where Photos.app isn't open. Surfaced via a toolbar pill, a menu bar item, and a Settings status row that shows when the last check ran. Transient failures retry automatically when due, with separate backoff for each missing photo or video version. Completed versions stay skipped, and resolved failures disappear from Export Issues. Settings → Export Issues shows recorded failures from manual and automatic exports, including versions covered by an original fallback. Matching Auto Export failures retain a Retry button; other failures can be retried with a manual export. **Open Photo Export at login** provides the simplest set-it-and-forget-it setup. See the [Auto Export guide](https://valtteriluomapareto.github.io/photo-export/auto-export/).
- Track exported assets per destination so interrupted exports resume safely; replacing a tracking snapshot preserves the previous history until the replacement is ready
- Browse full-size previews with cancellation when selection changes; late responses cannot replace the current preview
- Pause, resume, cancel, and clear queued work; cancelled scans cannot alter a replacement export. A file already moved into place finishes its history update for the original destination before a replacement export proceeds, so cancelling and retrying does not duplicate that file. An unfinished download, render or conversion cannot damage a restarted export or add failures to its result.
- Import an existing backup folder to rebuild local export state, preserving each matched file’s existing year/month folder even when its Photos date falls in an adjacent month, and pruning records for files no longer present on disk. Completed history is never moved to another month by an import. Cancelled or superseded reconciliation cannot remove history from a replacement destination or overwrite newer record changes. Import failures stop progress and offer Close and Retry; export-history failures require recovery before retrying. Corrupt timeline history offers Reset and Rebuild from Folder; a plain reset empties tracking and can cause duplicate exports until rebuilt. Collection history cannot yet be rebuilt from disk
- Save a diagnostic report (Help menu) listing failed and in-progress exports with their error messages, for attaching to bug reports
- If Photos can't provide an asset's edited version, fall back to writing the original with a `_orig` suffix so the asset still gets backed up

- Detect export-history storage failures and offer non-destructive Retry; completion waits for record writes.
- Recover conservatively from damaged Auto Export metadata: preserve invalid files before replacement, rescan uncertain scopes, and retain known retry history when storage access returns. Exact retry counts cannot be reconstructed from unreadable history.

## Known limitations

- Requires **macOS 15.0** or later.
- **Live Photos** export as still-only by default. Turn on Settings → Advanced → *Export Live Photos as paired image + video* to also write the paired video next to the still (e.g. `IMG_0001.HEIC` + `IMG_0001.MOV`). The paired-video extension matches what PhotoKit reports for that resource — typically `.MOV` on Apple hardware. The paired video is usually 1–3 MB per Live Photo, so libraries with thousands of them roughly double in size when the toggle is on. Shared-album Live Photos remain still-only because Apple doesn't expose their paired video.
- **Albums, Favorites, and iCloud Shared Albums** are supported. Smart albums other than Favorites are not currently included.
- **Shared albums export at reduced quality.** iCloud only serves shared photos as downscaled JPEGs — there's no API to fetch full-resolution originals for an asset that lives only in a shared album. The **Include originals** toggle is a no-op for shared albums (no `_orig` companion is possible).
- Edited photos export as the version Photos renders for you. Turn on **Settings → Advanced → Include originals** to also keep an `_orig` companion with the original bytes.

## Requirements

- macOS 15.0+
- Xcode 16.2+ (tested in CI) for building from source
- No third-party runtime dependencies

## Build from source

Open the project in Xcode:

```bash
open photo-export.xcodeproj
```

Or build from the command line:

```bash
xcodebuild \
  -project photo-export.xcodeproj \
  -scheme "photo-export" \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Run unit tests:

The shared scheme includes native hosted SwiftUI behavior tests and fake platform-service tests.
Login-item tests never change System Settings; volume tests use isolated notifications and temporary folders.
The CI XCUITest onboarding/navigation smoke remains deferred in [#108](https://github.com/valtteriluomapareto/photo-export/issues/108).

```bash
xcodebuild \
  -project photo-export.xcodeproj \
  -scheme "photo-export" \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

Generate coverage:

```bash
rm -rf TestResults.xcresult
xcodebuild \
  -project photo-export.xcodeproj \
  -scheme "photo-export" \
  -destination 'platform=macOS' \
  -enableCodeCoverage YES \
  -resultBundlePath TestResults.xcresult \
  CODE_SIGNING_ALLOWED=NO \
  test

./scripts/xccov2lcov.sh TestResults.xcresult lcov.info
```

Optional local tools: `swiftlint`, `swift-format`, `xcpretty`.

Marketing screenshots are captured with `scripts/screenshots/capture.sh`, which builds the app, then for each marketing surface launches it with `--screenshot-mode --screenshot-surface=<key>` against a curated synthetic Photos library (no personal photos involved) and captures the window via `screencapture -l<window-id>`. See [`scripts/README.md`](scripts/README.md) for entry points and [`docs/project/archive/screenshot-automation-plan.md`](docs/project/archive/screenshot-automation-plan.md) for design.

## Contributing

Contributions are welcome. Start with [`CONTRIBUTING.md`](CONTRIBUTING.md) for local setup and testing expectations.

For maintainers and contributors, additional internal references live in:

- User-facing docs source: [`website/src/content/docs/`](website/src/content/docs/)
- Maintainer notes and plans: [`docs/README.md`](docs/README.md)
- Persistence store reference: [`docs/reference/persistence-store.md`](docs/reference/persistence-store.md)
- Agent guidance: [`AGENTS.md`](AGENTS.md)

## License

Photo Export is released under the MIT License. See [`LICENSE`](LICENSE).
