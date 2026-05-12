#!/usr/bin/env bash
#
# scripts/screenshots/optimize-bundle.sh
#
# Batch-resizes + re-encodes the bundled stock photos in
# `photo-export/Resources/screenshots/` so the app binary doesn't bloat past
# the screenshot plan's size budget. Defaults: cap the long edge at 1600px,
# re-encode PNGs as JPEG at quality 85, delete the source PNG on success.
#
# Uses `sips` (macOS built-in) so there are no third-party dependencies.
#
# Usage:
#   scripts/screenshots/optimize-bundle.sh              # in-place, default knobs
#   scripts/screenshots/optimize-bundle.sh --max 2400   # taller resize
#   scripts/screenshots/optimize-bundle.sh --quality 75 # smaller files
#
# Safe to re-run: a PNG that already has a matching JPG sibling is skipped,
# so re-running after dropping new PNGs only touches the newcomers.

set -euo pipefail

MAX_DIM=1600
QUALITY=85

while (("$#")); do
  case "$1" in
    --max)
      MAX_DIM="$2"
      shift 2
      ;;
    --quality)
      QUALITY="$2"
      shift 2
      ;;
    -h | --help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -20
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DIR="$REPO_ROOT/photo-export/Resources/screenshots"

if [[ ! -d "$DIR" ]]; then
  echo "No bundle screenshots dir at $DIR; nothing to do." >&2
  exit 0
fi

cd "$DIR"

shopt -s nullglob
pngs=(*.png)
if ((${#pngs[@]} == 0)); then
  echo "No PNGs in $DIR; nothing to do."
  exit 0
fi

echo "Optimising ${#pngs[@]} PNG(s) (max ${MAX_DIM}px, JPEG quality ${QUALITY}):"

total_before=0
total_after=0
converted=0
skipped=0

for src in "${pngs[@]}"; do
  base="${src%.png}"
  if [[ -f "${base}.jpg" ]] || [[ -f "${base}.heic" ]]; then
    echo "  $src: skipped (${base}.jpg or .heic already present)"
    skipped=$((skipped + 1))
    continue
  fi
  before=$(stat -f %z "$src")
  total_before=$((total_before + before))

  # `-Z` resamples to fit within MAX_DIM on the longest edge while preserving
  # aspect; `--setProperty format jpeg --setProperty formatOptions N` does the
  # re-encode with quality N (1-100, where 100 is largest-file/least-loss).
  sips \
    -Z "$MAX_DIM" \
    --setProperty format jpeg \
    --setProperty formatOptions "$QUALITY" \
    "$src" --out "${base}.jpg" >/dev/null

  after=$(stat -f %z "${base}.jpg")
  total_after=$((total_after + after))
  pct=$((after * 100 / before))
  printf "  %-22s  %5d KB → %5d KB (%d%%)\n" \
    "$src" $((before / 1024)) $((after / 1024)) "$pct"
  rm "$src"
  converted=$((converted + 1))
done

echo
if ((converted == 0)); then
  echo "Nothing converted; $skipped file(s) skipped."
  exit 0
fi

savings_pct=$((total_after * 100 / total_before))
printf "Converted %d file(s). Total: %d KB → %d KB (%d%% of original).\n" \
  "$converted" $((total_before / 1024)) $((total_after / 1024)) "$savings_pct"
echo "Rebuild + re-run scripts/screenshots/capture.sh to verify the JPEGs render."
