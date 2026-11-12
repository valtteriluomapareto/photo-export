#!/bin/bash
# Convert Xcode .xcresult coverage data to LCOV format.
# Usage: ./scripts/xccov2lcov.sh TestResults.xcresult [output.lcov]
set -euo pipefail

XCRESULT="${1:?Usage: $0 <path-to.xcresult> [output.lcov]}"
OUTPUT="${2:-lcov.info}"

if [ ! -d "$XCRESULT" ]; then
  echo "Error: $XCRESULT not found" >&2
  exit 1
fi

FILES=$(xcrun xccov view --archive --file-list "$XCRESULT")

: > "$OUTPUT"

while IFS= read -r filepath; do
  # Skip test files
  case "$filepath" in
    *Tests*) continue ;;
  esac

  echo "TN:" >> "$OUTPUT"
  echo "SF:$filepath" >> "$OUTPUT"

  # xccov output format per line:
  #   " 1: *"         - non-executable line
  #   " 2: 5"         - executable line hit 5 times
  #   " 3: 0"         - executable line not hit
  #   " 4: 3 ["       - line with sub-region data (take leading count)
  #   "(col, col, 0)" - sub-region detail (skip)
  #   "]"             - end sub-region (skip)
  while IFS= read -r line; do
    # Skip sub-region lines: "(..." and "]"
    [[ "$line" =~ ^[[:space:]]*[\(\]] ]] && continue
    # Parse "  <num>: <count>" or "  <num>: *"
    if [[ "$line" =~ ^[[:space:]]*([0-9]+):[[:space:]]*(.*) ]]; then
      line_num="${BASH_REMATCH[1]}"
      rest="${BASH_REMATCH[2]}"
      # Skip non-executable lines
      [ "$rest" = "*" ] && continue
      # Strip sub-region bracket: "3 [" -> "3"
      count="${rest%% \[*}"
      echo "DA:$line_num,$count" >> "$OUTPUT"
    fi
  done < <(xcrun xccov view --archive --file "$filepath" "$XCRESULT")

  echo "end_of_record" >> "$OUTPUT"
done <<< "$FILES"

echo "Coverage written to $OUTPUT"
