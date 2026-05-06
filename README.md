# Photo Export

[![CI](https://github.com/valtteriluomapareto/photo-export/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/valtteriluomapareto/photo-export/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Photo Export is a native macOS app for exporting your Apple Photos library to local or external storage. Pick the layout that fits your library: a predictable `YYYY/MM/` timeline, or per-album folders under `Collections/Favorites/` and `Collections/Albums/<Album>/`.

**[Download on the Mac App Store](https://apps.apple.com/app/photo-export-local-backup/id6761410742)** · [Download from GitHub (free)](https://github.com/valtteriluomapareto/photo-export/releases) · [Documentation](https://valtteriluomapareto.github.io/photo-export/)

The project is intentionally small: SwiftUI on top, system frameworks only, and a straightforward export pipeline that favors reliability over feature sprawl.

## Current Capabilities

- Browse your library two ways via a Timeline / Collections segmented control
  - Timeline: year and month
  - Collections: Favorites plus your Photos albums and folders
- Preview thumbnails and selected assets
- Export a month, a year, or the full queue without overwriting existing files
- Export your Favorites or any album you've created in Photos to `Collections/Favorites/` or `Collections/Albums/<Album>/`, individually or via **Export All Albums** in the toolbar
- Choose what to write with the toolbar's **Include originals** toggle. Off (default)
  exports one file per asset, in the version Photos shows. On adds a `_orig` companion
  (e.g. `IMG_0001_orig.HEIC`) for any photo or video edited in Photos so you keep a copy
  of the original bytes alongside the user-visible edit
- Track exported assets per destination so interrupted exports can resume safely
- Pause, resume, cancel, and clear queued work
- Import an existing backup folder to rebuild local export state, pruning records for files no longer present on disk
- Save a diagnostic report (Help menu) listing failed and in-progress exports with their error messages, for attaching to bug reports

## Requirements

- macOS 15.0+
- Xcode 16.2+ tested in CI
- No third-party runtime dependencies

Optional local tools:

- `swiftlint`
- `swift-format`
- `xcpretty`

## Build and Test

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

## Documentation

- Project website: [valtteriluomapareto.github.io/photo-export](https://valtteriluomapareto.github.io/photo-export/)
- User docs: [`website/src/content/docs/`](website/src/content/docs/)
- Contributor guide: [`CONTRIBUTING.md`](CONTRIBUTING.md)
- AI agent guide: [`AGENTS.md`](AGENTS.md)
- Maintainer notes and plans: [`docs/README.md`](docs/README.md) (canonical map of every doc location)
- Persistence store reference: [`docs/reference/persistence-store.md`](docs/reference/persistence-store.md)

## Repository Layout

- `photo-export/` app source
- `photo-exportTests/` unit tests
- `photo-exportUITests/` UI tests
- `website/` documentation website
- `docs/` maintainer-facing notes, plans, and reference material
- `scripts/` small development utilities

## Contributing

Contributions are welcome. Start with [`CONTRIBUTING.md`](CONTRIBUTING.md) for local setup and testing expectations. For docs ownership and the "what to update when behavior changes" table, see [`docs/README.md`](docs/README.md).

## License

Photo Export is released under the MIT License. See [`LICENSE`](LICENSE).
