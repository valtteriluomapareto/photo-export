#!/usr/bin/env bash
#
# scripts/screenshots/capture.sh
#
# End-to-end capture pipeline for marketing screenshots. Builds the app
# once, then for each "surface" launches the app with a
# `--screenshot-surface=<key>` arg that lands directly on that view via
# `LibraryRootView.requestedScreenshotSurface`. Captures the window by
# CGWindowID, then quits and moves on to the next surface.
#
# Outputs go to `screenshots/<WIDTHxHEIGHT>/NN-name.png` relative to the repo
# root.
#
# Usage:
#   scripts/screenshots/capture.sh                 # 2880x1800, all surfaces
#   scripts/screenshots/capture.sh 1440x900        # smaller App Store slot
#   scripts/screenshots/capture.sh 1440x900 timeline collections-favorites
#                                                  # capture only the listed surfaces
#
# Manual upload after running: drag the PNGs into App Store Connect's web UI,
# or pass them through scripts/prepare-app-store-screenshot.py if padding is
# needed for a specific spec size.
#
# Required TCC permission (one-time, grant in System Settings → Privacy &
# Security → Screen Recording):
#
#   • The shell host running this script (Terminal.app, iTerm2, Warp,
#     Ghostty, etc.) needs Screen Recording permission. Without it,
#     `screencapture` exits non-zero with "could not create image from
#     display".
#
# That's it — no Automation or Accessibility permissions needed.
#
# Designed to be re-runnable — quits any existing instance and clears the
# output dir on each invocation.

set -euo pipefail

SIZE="${1:-2880x1800}"
if [[ ! "$SIZE" =~ ^[0-9]+x[0-9]+$ ]]; then
  echo "Usage: $0 [WIDTHxHEIGHT] [surface...]" >&2
  exit 2
fi
shift || true
WIDTH="${SIZE%x*}"
HEIGHT="${SIZE#*x}"

# Default surface set when none is requested explicitly on the command line.
# Each entry is "key:NN-filename" — the key matches a case in
# `LibraryRootView.requestedScreenshotSurface()`, the NN-filename is the
# output PNG (stable upload order via the NN prefix).
DEFAULT_SURFACES=(
  "timeline:01-timeline"
  "timeline-multi-select:02-timeline-multi-select"
  "collections-favorites:03-collections-favorites"
  "collections-album-family:04-collections-album-family"
  "collections-album-porvoo:05-collections-album-porvoo"
  "collections-folder-trips:06-collections-folder-trips"
  "collections-multi-select:07-collections-multi-select"
  "collections-album-london:08-collections-album-london"
  "collections-shared-album-family-stream:09-collections-shared-album-family-stream"
)

# If the user supplied positional args after the size, use those as surface
# keys (matching the suffix-by-key form) so they can capture a subset for
# iteration.
if (($# > 0)); then
  REQUESTED_SURFACES=()
  for key in "$@"; do
    found=""
    for entry in "${DEFAULT_SURFACES[@]}"; do
      if [[ "${entry%%:*}" == "$key" ]]; then
        REQUESTED_SURFACES+=("$entry")
        found="yes"
        break
      fi
    done
    if [[ -z "$found" ]]; then
      echo "Unknown surface: $key" >&2
      echo "Known surfaces:" >&2
      for entry in "${DEFAULT_SURFACES[@]}"; do
        echo "  ${entry%%:*}" >&2
      done
      exit 2
    fi
  done
  SURFACES=("${REQUESTED_SURFACES[@]}")
else
  SURFACES=("${DEFAULT_SURFACES[@]}")
fi

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

# Capture each surface as its own fresh launch. Per-surface launches avoid
# state leakage between surfaces (no menu open from a prior surface, no
# scroll position carryover) and remove the need for any UI scripting.
for entry in "${SURFACES[@]}"; do
  KEY="${entry%%:*}"
  NAME="${entry##*:}"
  OUT_PATH="$OUT_DIR/${NAME}.png"

  # Stale window-id file from a prior surface would point at the prior
  # window's CGWindowID.
  rm -f "$WINDOW_ID_FILE"

  echo
  echo "==> [$KEY] terminating any existing instance"
  pkill -f "${APP_NAME}.*--screenshot-mode" 2>/dev/null || true
  for _ in 1 2 3 4 5 6; do
    if ! pgrep -f "${APP_NAME}.*--screenshot-mode" >/dev/null; then break; fi
    sleep 0.5
  done

  echo "==> [$KEY] launching (${WIDTH}x${HEIGHT})"
  open "$APP_PATH" --args \
    --screenshot-mode \
    "--screenshot-width=$WIDTH" \
    "--screenshot-height=$HEIGHT" \
    "--screenshot-surface=$KEY"

  echo "==> [$KEY] waiting for window id"
  for _ in $(seq 1 20); do
    if [[ -s "$WINDOW_ID_FILE" ]]; then break; fi
    sleep 0.5
  done
  if [[ ! -s "$WINDOW_ID_FILE" ]]; then
    echo "Timed out waiting for $WINDOW_ID_FILE on surface $KEY." >&2
    pkill -f "${APP_NAME}.*--screenshot-mode" 2>/dev/null || true
    exit 4
  fi
  WINDOW_ID="$(cat "$WINDOW_ID_FILE")"

  # Give SwiftUI a moment after the window settles so async thumbnail loads
  # finish before the capture lands. 1.0s is conservative; 0.5s leaves
  # gradient placeholders visible on slower hardware.
  sleep 1.0

  echo "==> [$KEY] capturing → $OUT_PATH (window $WINDOW_ID)"
  if ! /usr/sbin/screencapture -t png -o "-l${WINDOW_ID}" "$OUT_PATH"; then
    echo "screencapture failed. Most common cause: Screen Recording permission" >&2
    echo "not granted to your shell host. Grant in System Settings → Privacy &" >&2
    echo "Security → Screen Recording, then retry." >&2
    pkill -f "${APP_NAME}.*--screenshot-mode" 2>/dev/null || true
    exit 5
  fi
done

echo
echo "==> Terminating final screenshot instance"
pkill -f "${APP_NAME}.*--screenshot-mode" 2>/dev/null || true

if ! ls "$OUT_DIR"/*.png >/dev/null 2>&1; then
  echo "No screenshots produced; output dir is empty: $OUT_DIR" >&2
  exit 6
fi

echo
echo "Done. ${#SURFACES[@]} capture(s) landed in:"
echo "  $OUT_DIR"
ls -1 "$OUT_DIR"
