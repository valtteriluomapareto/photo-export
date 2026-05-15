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
- Preview thumbnails and selected assets
- Export a month, a year, an album, or the full queue without overwriting existing files
- Export Favorites or any album you've created in Photos to `Collections/Favorites/` or `Collections/Albums/<Album>/`, individually or via **Export All Albums** in the toolbar. Select a folder in the Collections sidebar to flip the primary action to **Export Folder** (every descendant album), or Cmd/Shift-click album tiles to enqueue an explicit selection
- Export **iCloud Shared Albums** one at a time to `Collections/Shared Albums/<Album>/`. Apple serves shared photos as downscaled JPEGs only, so Photo Export saves whatever Apple provides — originals aren't available for shared-album assets
- Choose what to write with the toolbar's **Include originals** toggle. Off (default) exports one file per asset, in the version Photos shows. On adds a `_orig` companion (e.g. `IMG_0001_orig.HEIC`) for any photo or video edited in Photos so you keep a copy of the original bytes alongside the user-visible edit
- **Auto Export** (opt-in; off by default) keeps a chosen destination automatically in sync with your Photos library: pick Timeline / Favorites / Albums in Settings → Auto Export, and Photo Export adds new photos as they appear in Apple Photos. Surfaced via a toolbar pill, a menu bar item, and a Settings status row. Transient failures retry automatically, waiting longer between each attempt; everything that failed is listed in an Export Issues view with a per-row Retry button. **Open Photo Export at login** provides the simplest set-it-and-forget-it setup. See the [Auto Export guide](https://valtteriluomapareto.github.io/photo-export/auto-export/).
- Track exported assets per destination so interrupted exports resume safely
- Pause, resume, cancel, and clear queued work
- Import an existing backup folder to rebuild local export state, pruning records for files no longer present on disk
- Save a diagnostic report (Help menu) listing failed and in-progress exports with their error messages, for attaching to bug reports
- If Photos can't provide an asset's edited version, fall back to writing the original with a `_orig` suffix so the asset still gets backed up

## Known limitations

- Requires **macOS 15.0** or later.
- **Live Photos** currently export as still images. Paired image + video export is planned.
- **Albums, Favorites, and iCloud Shared Albums** are supported. Smart albums other than Favorites are not currently included.
- **Shared albums export at reduced quality.** iCloud only serves shared photos as downscaled JPEGs — there's no API to fetch full-resolution originals for an asset that lives only in a shared album. The **Include originals** toggle is a no-op for shared albums (no `_orig` companion is possible).
- Edited photos export as the version Photos renders for you. Turn on **Include originals** to also keep an `_orig` companion with the original bytes.

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

Marketing screenshots are captured with `scripts/screenshots/capture.sh`, which builds the app, then for each marketing surface launches it with `--screenshot-mode --screenshot-surface=<key>` against a curated synthetic Photos library (no personal photos involved) and captures the window via `screencapture -l<window-id>`. See [`scripts/README.md`](scripts/README.md) for entry points and [`docs/project/plans/screenshot-automation-plan.md`](docs/project/plans/screenshot-automation-plan.md) for design.

## Contributing

Contributions are welcome. Start with [`CONTRIBUTING.md`](CONTRIBUTING.md) for local setup and testing expectations.

For maintainers and contributors, additional internal references live in:

- User-facing docs source: [`website/src/content/docs/`](website/src/content/docs/)
- Maintainer notes and plans: [`docs/README.md`](docs/README.md)
- Persistence store reference: [`docs/reference/persistence-store.md`](docs/reference/persistence-store.md)
- Agent guidance: [`AGENTS.md`](AGENTS.md)

## License

Photo Export is released under the MIT License. See [`LICENSE`](LICENSE).
