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

Photo Export runs locally on your Mac. It uses Apple's PhotoKit framework to read the same library the built-in Photos app sees,
**read-only** — it can't modify or delete anything in your Photos library. It does not upload your photos, use any third-party cloud
service, require an account, or ask for your Apple Account password.

The access screen, Auto Export Settings and manual export failures share one recovery instruction: turn on Photos access for Photo Export in **System Settings → Privacy & Security → Photos**. Choose **Open System Settings** on the access screen, then return to the app to continue.

If Auto Export shows "Blocked — Photos access needed", Photos access is off and Auto Export doesn't run. Turn it back on under **System Settings → Privacy & Security → Photos**; pending changes are kept and export shortly after you return to Photo Export.

## Features

- Browse your library by **Timeline** or **Collections**, including Favorites, albums and folders. [Browsing
  guide](https://valtteriluomapareto.github.io/photo-export/features/#library-browsing).
- Open thumbnails and full-size previews while the first batch loads. Thumbnail preheating follows scrolling, with static placeholders while images arrive. Details show the current collection’s export history. [Preview
  details](https://valtteriluomapareto.github.io/photo-export/features/#library-browsing).
- Photos edits refresh the grid and previews in place while keeping surviving selections. Timeline progress badges retain their last counts when an outdated count request is canceled. [Refresh
  behavior](https://valtteriluomapareto.github.io/photo-export/features/#library-browsing).
- Export a month, year or queued batch while skipping completed files and protecting existing copies. [File naming and
  reuse](https://valtteriluomapareto.github.io/photo-export/features/#files-already-at-the-destination).
- Cmd/Shift-click sidebar rows or album tiles to export a mix of months, years, Favorites, albums and folders. [Batch
  actions](https://valtteriluomapareto.github.io/photo-export/features/#export).
- Export Favorites, individual albums, a folder’s albums or all user albums, preserving their folder hierarchy. [Collection
  exports](https://valtteriluomapareto.github.io/photo-export/features/#export).
- Keep separate progress for renamed or moved albums, with distinct folders for new case-only sibling names. [Album folder
  rules](https://valtteriluomapareto.github.io/photo-export/features/#album-folder-names).
- Export selected **iCloud Shared Albums** using the reduced-quality JPEGs Apple provides. [Shared album
  limits](https://valtteriluomapareto.github.io/photo-export/features/#shared-albums-reduced-fidelity).
- Choose **Include originals** to keep unmodified copies alongside Photos edits. [Original and edited
  versions](https://valtteriluomapareto.github.io/photo-export/features/#include-originals-for-edited-photos).
- Convert HEIC/HEIF captures to JPEG for devices that need it. [Conversion
  settings](https://valtteriluomapareto.github.io/photo-export/features/#convert-heic-to-jpeg).
- Optionally put standalone videos in a `videos/` subfolder. [Video
  layout](https://valtteriluomapareto.github.io/photo-export/features/#separate-videos-into-a-subfolder).
- Optionally export **Live Photos** as paired image and video files. [Live Photo
  settings](https://valtteriluomapareto.github.io/photo-export/features/#live-photos).
- Follow progress below the toolbar, then pause, resume, cancel or clear queued work. [Queue and safe-restart
  behavior](https://valtteriluomapareto.github.io/photo-export/features/#queue-controls).
- See completed and failed counts after a manual export, with wrapped failure details and **View Issues**. [Export
  outcomes](https://valtteriluomapareto.github.io/photo-export/export-icloud-photos/#resuming-an-interrupted-export).
- Enable **Auto Export** to add new photos automatically, retry transient failures and optionally open at login. [Auto Export
  guide](https://valtteriluomapareto.github.io/photo-export/auto-export/).
- See destination problems in the main window and reconnect a drive or restore folder access. [Destination
  guidance](https://valtteriluomapareto.github.io/photo-export/features/#export-destination).
- Re-select the same backup folder without interrupting an active export.
- Track progress separately for each destination and resume interrupted exports. [History and
  recovery](https://valtteriluomapareto.github.io/photo-export/features/#tracking-and-resume).
- Import an existing backup to rebuild history for Timeline, Favorites, albums and Shared Albums. Failures saving import history show an error. [Import and
  recovery](https://valtteriluomapareto.github.io/photo-export/export-icloud-photos/#rebuilding-state-from-an-existing-backup).
- Save a diagnostic report from the **Help** menu when an export needs investigation.
  [Diagnostics](https://valtteriluomapareto.github.io/photo-export/features/#error-handling).
- Keep an original backup when Photos cannot supply an edited version. [Fallback
  behavior](https://valtteriluomapareto.github.io/photo-export/features/#error-handling).
- Retry export-history storage errors without resetting retained progress. [Storage
  recovery](https://valtteriluomapareto.github.io/photo-export/features/#error-handling).
- Recover conservatively from damaged Auto Export metadata while retaining known retry history. [Auto Export
  safety](https://valtteriluomapareto.github.io/photo-export/auto-export/#safety).

## Known limitations

- Requires **macOS 15.0** or later.
- Live Photos export as still images by default; paired video is optional and uses more space.
  See [Live Photos](https://valtteriluomapareto.github.io/photo-export/features/#live-photos).
- Smart albums other than Favorites are not supported.
- Shared Albums provide reduced-quality JPEGs, with no full-resolution originals or paired video.
  See [Shared Album limits](https://valtteriluomapareto.github.io/photo-export/features/#shared-albums-reduced-fidelity).
- Edited photos use the version Photos renders; **Include originals** also keeps the unmodified bytes.

## Requirements

- macOS 15.0+
- Xcode at or above the version in [`.xcode-version`](.xcode-version) for building from source; CI and releases use exactly that version
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

For automatic real-export measurement capture and the local synthetic benchmark, see
[`scripts/README.md` → Export measurements](scripts/README.md#export-measurements).

Marketing screenshots are captured with `scripts/screenshots/capture.sh`, which builds the app, then for each marketing surface launches it
with `--screenshot-mode --screenshot-surface=<key>` against a curated synthetic Photos library (no personal photos involved) and captures
the window via `screencapture -l<window-id>`. See [`scripts/README.md`](scripts/README.md) for entry points and
[`docs/project/archive/screenshot-automation-plan.md`](docs/project/archive/screenshot-automation-plan.md) for design.

## Contributing

Contributions are welcome. Start with [`CONTRIBUTING.md` → Start here](CONTRIBUTING.md#start-here) for the reading order, local setup and testing guide.

For maintainers and contributors, additional internal references live in:

- User-facing docs source: [`website/src/content/docs/`](website/src/content/docs/)
- Maintainer notes and plans: [`docs/README.md`](docs/README.md)
- Persistence store reference: [`docs/reference/persistence-store.md`](docs/reference/persistence-store.md)
- Agent guidance: [`AGENTS.md`](AGENTS.md)

## License

Photo Export is released under the MIT License. See [`LICENSE`](LICENSE).
