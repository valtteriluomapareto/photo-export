#!/bin/bash
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  echo "Usage: scripts/perf/run-main-thread-bench.sh"
  echo "Runs three optimized Debug samples using scratch-only fake exports. Prints BENCH medians."
  exit 0
fi
if [[ $# -ne 0 ]]; then
  echo "Unknown argument: $1" >&2
  exit 2
fi
if [[ "${CI:-}" == "true" ]]; then
  echo "This timing benchmark is for local runs, not CI." >&2
  exit 2
fi
cd "$(dirname "$0")/../.."
bench_root=$(mktemp -d "${TMPDIR:-/tmp}/photo-export-main-thread-bench.XXXXXX")
trap 'rm -rf "$bench_root"' EXIT
if ! TEST_RUNNER_PHOTO_EXPORT_PERF=1 caffeinate -du xcodebuild \
  -project photo-export.xcodeproj -scheme photo-export -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$bench_root/DerivedData" \
  -only-testing:photo-exportTests/MainThreadExportBenchmark \
  CODE_SIGNING_ALLOWED=NO SWIFT_OPTIMIZATION_LEVEL=-O test > "$bench_root/run.log" 2>&1; then
  tail -100 "$bench_root/run.log" >&2
  exit 1
fi
awk '/BENCH / { sub(/^.*BENCH /, "BENCH "); print; found=1 } END { if (!found) exit 1 }' "$bench_root/run.log"
