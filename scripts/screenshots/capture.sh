#!/usr/bin/env bash
#
# scripts/screenshots/capture.sh
#
# End-to-end capture pipeline for marketing screenshots:
#
#   1. Build the app (Release config, no code signing) with the bundled
#      screenshot mode wired in.
#   2. Launch it with `--screenshot-mode --screenshot-width=W --screenshot-height=H`
#      so it boots the curated `ScreenshotPhotoLibraryService` and resizes the
#      main window to the requested frame.
#   3. Drive it through every marketing surface via the AppleScript at
#      `drive.applescript`, calling `screencapture -R x,y,w,h` between steps.
#   4. Terminate the running instance.
#
# Outputs go to `screenshots/<WIDTHxHEIGHT>/NN-name.png` relative to the repo
# root.
#
# Usage:
#   scripts/screenshots/capture.sh                 # 2880x1800 (default)
#   scripts/screenshots/capture.sh 1440x900        # smaller App Store slot
#
# Manual upload after running: drag the PNGs into App Store Connect's web UI,
# or pass them through scripts/prepare-app-store-screenshot.py if padding is
# needed for a specific spec size.
#
# Required TCC permissions (one-time, grant in System Settings → Privacy & Security):
#
#   • Automation → Terminal (or your shell host) → Photo Export + System Events
#     The AppleScript driver sends Apple events to "Photo Export" to read its
#     window position/size. macOS prompts on first run; the script will time
#     out (-1712) if denied.
#
#   • Screen Recording → Terminal (or your shell host)
#     `screencapture` requires this on macOS 10.15+. Without it, screencapture
#     exits non-zero with "could not create image from display".
#
# Designed to be re-runnable — quits any existing instance and clears the
# output dir.

set -euo pipefail

SIZE="${1:-2880x1800}"
if [[ ! "$SIZE" =~ ^[0-9]+x[0-9]+$ ]]; then
  echo "Usage: $0 [WIDTHxHEIGHT]" >&2
  exit 2
fi
WIDTH="${SIZE%x*}"
HEIGHT="${SIZE#*x}"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

OUT_DIR="$REPO_ROOT/screenshots/${SIZE}"
DERIVED="$REPO_ROOT/build/screenshots"
APP_NAME="Photo Export"
APP_PATH="$DERIVED/Build/Products/Release/${APP_NAME}.app"

echo "==> Cleaning previous output at $OUT_DIR"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

echo "==> Building $APP_NAME (Release, no signing)"
xcodebuild \
  -project photo-export.xcodeproj \
  -scheme "photo-export" \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  build >/dev/null

if [[ ! -d "$APP_PATH" ]]; then
  echo "Build did not produce $APP_PATH" >&2
  exit 3
fi

# Kill any running instance so we own the window number reliably.
echo "==> Terminating any existing instance"
osascript -e 'tell application "Photo Export" to quit' >/dev/null 2>&1 || true
# Wait for it to actually quit so the new launch is fresh.
for _ in 1 2 3 4 5; do
  if ! pgrep -xq "$APP_NAME"; then break; fi
  sleep 0.5
done

echo "==> Launching with --screenshot-mode (${WIDTH}x${HEIGHT})"
open "$APP_PATH" --args \
  --screenshot-mode \
  "--screenshot-width=$WIDTH" \
  "--screenshot-height=$HEIGHT"

# Give the app a moment to materialise the main window before AppleScript pokes
# at it. Driving too fast races SwiftUI's first frame.
sleep 2

echo "==> Driving the app and capturing"
if ! osascript "$REPO_ROOT/scripts/screenshots/drive.applescript" "$OUT_DIR"; then
  echo
  echo "AppleScript driver failed. Most common causes:" >&2
  echo "  • Automation permission not granted to your terminal app for" >&2
  echo "    'Photo Export' or 'System Events' — System Settings → Privacy &" >&2
  echo "    Security → Automation." >&2
  echo "  • Screen Recording permission not granted to your terminal app —" >&2
  echo "    System Settings → Privacy & Security → Screen Recording." >&2
  echo "  • A modal prompt is open on the launched app (e.g. Photo Library" >&2
  echo "    permission). Screenshot mode forces auth = .authorized so the" >&2
  echo "    prompt shouldn't appear; if it does, file an issue." >&2
  osascript -e 'tell application "Photo Export" to quit' >/dev/null 2>&1 || true
  exit 4
fi

echo "==> Terminating screenshot instance"
osascript -e 'tell application "Photo Export" to quit' >/dev/null 2>&1 || true

# Sanity-check: we should have at least one PNG; an empty output dir means
# the driver completed but every capture step failed silently (most likely
# Screen Recording permission denial — screencapture exits non-zero but the
# script's `do shell script` propagates that as an AppleScript error, so we
# should never reach here with an empty dir. Defensive guard regardless.)
if ! ls "$OUT_DIR"/*.png >/dev/null 2>&1; then
  echo "No screenshots produced; output dir is empty: $OUT_DIR" >&2
  exit 5
fi

echo
echo "Done. Captures landed in:"
echo "  $OUT_DIR"
ls -1 "$OUT_DIR"
