# scripts/

Small development utilities for this project. CI-only steps live under [`ci/`](ci/) and are invoked from the GitHub Actions workflows in `.github/workflows/`.

## Top-level scripts

| Script | Purpose |
| --- | --- |
| [`bump-version.sh`](bump-version.sh) | Sets `MARKETING_VERSION` across all six build configs in `project.pbxproj`, commits, and tags `v<version>`. Use `--no-tag` to set the version without committing. Required step in [`docs/project/release-process.md`](../docs/project/release-process.md). |
| [`generate-app-icon.sh`](generate-app-icon.sh) | Generates a complete macOS `AppIcon.appiconset` from a single square master image. Source image lives in [`design/app-icon-master.jpeg`](../design/app-icon-master.jpeg). Run when the icon changes. |
| [`prepare-app-store-screenshot.py`](prepare-app-store-screenshot.py) | Pads a screenshot to a Mac App Store spec size and flattens transparency. Operates on [`design/app-store-screenshot.png`](../design/app-store-screenshot.png). Requires `pip install Pillow`. |
| [`screenshots/capture.sh`](screenshots/capture.sh) | Builds the app in screenshot mode (curated synthetic library, no personal photos), launches it at a requested window size, and captures the window via `screencapture -l<id>`. Outputs to `screenshots/<WxH>/NN-name.png`. Requires a one-time Screen Recording TCC grant on your terminal — see the script header. See [`docs/project/archive/screenshot-automation-plan.md`](../docs/project/archive/screenshot-automation-plan.md) for design. |
| [`screenshots/optimize-bundle.sh`](screenshots/optimize-bundle.sh) | Batch-resizes + re-encodes the stock photos under `photo-export/Resources/screenshots/` as JPEG at quality 85, capped at 1600px on the long edge. PNGs typically shrink to ~25% of their original size. Skips files that already have a `.jpg` / `.heic` sibling. Run after dropping new PNGs into the bundle. |
| [`xccov2lcov.sh`](xccov2lcov.sh) | Converts an `.xcresult` coverage bundle into `lcov.info` for tools that consume LCOV. Used by the coverage commands in [`README.md`](../README.md). |

## CI scripts (`scripts/ci/`)

These are wrappers around `xcodebuild` / signing / App Store Connect that the release workflows call. They are not meant to be run interactively unless you are reproducing a CI failure locally — they expect environment variables that the workflows inject.

| Script | Used by workflow |
| --- | --- |
| `archive-appstore.sh` | `release-app-store.yml` |
| `export-appstore.sh` | `release-app-store.yml` |
| `prepare-pkg.sh` | `release-app-store.yml` |
| `setup-keychain-appstore.sh` | `release-app-store.yml` |
| `install-provisioning-profile.sh` | `release-app-store.yml` |
| `upload-appstore-connect.sh` | `release-app-store.yml` |
| `cleanup-appstore.sh` | `release-app-store.yml` (always runs) |

## Design assets

Marketing source files live in [`design/`](../design/), not in the repo root:

- `app-icon-master.jpeg` — square master image for the app icon
- `app-store-screenshot.png` — current Mac App Store hero screenshot
