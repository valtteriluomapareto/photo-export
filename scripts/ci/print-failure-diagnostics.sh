#!/usr/bin/env bash
# Print early failures from complete build and test logs, including warning checks.
set -euo pipefail

for log in debug-build.log debug-werror-build.log test.log release-build.log; do
  if [[ -f "$log" ]]; then
    echo "::group::Failure diagnostics: $log"
    grep -nE '✘|↳|recorded an issue|Expectation failed|error:' "$log" || true
    echo "::endgroup::"
  fi
done
