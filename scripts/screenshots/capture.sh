#!/usr/bin/env bash
#
# scripts/screenshots/capture.sh
#
# End-to-end capture pipeline for marketing screenshots:
#
#   1. Build the app (Release config, no code signing) with the bundled
#      screenshot mode wired in.
#   2. Launch it with `--screenshot-mode --screenshot-width=W --screenshot-height=H`
#      so it boots the curated `ScreenshotPhotoLibraryService`, resizes the
#      main window to the requested frame, and publishes the window's
#      CGWindowID to a temp file (`$TMPDIR/photo-export-screenshot-window-id.txt`).
#   3. Poll for the window-id file, then capture via `screencapture -l<id>`.
#      Capture-by-window-id is pixel-exact and works regardless of which
#      display the window lives on (matters on multi-display setups).
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
# Required TCC permission (one-time, grant in System Settings → Privacy &
# Security → Screen Recording):
#
#   • The shell host running this script (Terminal.app, iTerm2, Warp, etc.)
#     needs Screen Recording permission. Without it, `screencapture` exits
#     non-zero with "could not create image from display".
#
# That's it — no Automation or Accessibility permissions needed. The pipeline
# used to drive the app via AppleScript + System Events (which would have
# needed both), but the app now publishes its window frame to a temp file
# directly, so the script can call `screencapture -R` without AppleScript.
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
WINDOW_ID_FILE="${TMPDIR:-/tmp}/photo-export-screenshot-window-id.txt"

echo "==> Cleaning previous output at $OUT_DIR"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
# Stale window-id file from a prior run would point at a dead CGWindowID.
rm -f "$WINDOW_ID_FILE"

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

# Kill any running instance so we own the window frame reliably.
echo "==> Terminating any existing instance"
pkill -f "${APP_NAME}.*--screenshot-mode" 2>/dev/null || true
# Wait for the binary to actually exit so a stale frame file isn't picked up.
for _ in 1 2 3 4 5 6; do
  if ! pgrep -f "${APP_NAME}.*--screenshot-mode" >/dev/null; then break; fi
  sleep 0.5
done

echo "==> Launching with --screenshot-mode (${WIDTH}x${HEIGHT})"
open "$APP_PATH" --args \
  --screenshot-mode \
  "--screenshot-width=$WIDTH" \
  "--screenshot-height=$HEIGHT"

# Wait up to 10s for the app to publish its window id. The app writes the
# file once the window has been sized + positioned and has a stable
# CGWindowID for screencapture to target.
echo "==> Waiting for window id"
for i in $(seq 1 20); do
  if [[ -s "$WINDOW_ID_FILE" ]]; then break; fi
  sleep 0.5
done
if [[ ! -s "$WINDOW_ID_FILE" ]]; then
  echo "Timed out waiting for $WINDOW_ID_FILE — the app likely didn't reach screenshot mode." >&2
  pkill -f "${APP_NAME}.*--screenshot-mode" 2>/dev/null || true
  exit 4
fi
WINDOW_ID="$(cat "$WINDOW_ID_FILE")"
echo "    window id: $WINDOW_ID"

# Give SwiftUI a brief moment to finish rendering the initial frame after the
# window is sized — without this, in-progress animation can land in the PNG.
sleep 0.5

echo "==> Capturing"
OUT_PATH="$OUT_DIR/01-timeline.png"
# `-o` suppresses the window's drop shadow so the PNG has a clean edge
# suitable for App Store / website use. `-l<id>` targets the window
# regardless of which display it's on.
if ! /usr/sbin/screencapture -t png -o "-l${WINDOW_ID}" "$OUT_PATH"; then
  echo "screencapture failed. Most common cause: Screen Recording permission" >&2
  echo "not granted to your shell host (Terminal / iTerm2 / etc.). Grant in" >&2
  echo "System Settings → Privacy & Security → Screen Recording, then retry." >&2
  pkill -f "${APP_NAME}.*--screenshot-mode" 2>/dev/null || true
  exit 5
fi

echo "==> Terminating screenshot instance"
pkill -f "${APP_NAME}.*--screenshot-mode" 2>/dev/null || true

if ! ls "$OUT_DIR"/*.png >/dev/null 2>&1; then
  echo "No screenshots produced; output dir is empty: $OUT_DIR" >&2
  exit 6
fi

echo
echo "Done. Captures landed in:"
echo "  $OUT_DIR"
ls -1 "$OUT_DIR"
