#!/usr/bin/env bash
# Run CI's static repository guards without a build, result bundle or release credentials.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

failed=()
run_guard() {
  local name="$1"
  shift
  echo "=== ${name} ==="
  if "$@"; then
    echo "PASS: ${name}"
  else
    local result=$?
    echo "FAIL: ${name} (exit ${result})"
    failed+=("${name}")
  fi
}

run_guard test-guards.sh bash scripts/ci/test-guards.sh
run_guard check-read-only-photos.py python3 -B scripts/ci/check-read-only-photos.py
run_guard check-no-plan-refs.py python3 -B scripts/ci/check-no-plan-refs.py
run_guard check-test-waits.py python3 -B scripts/ci/check-test-waits.py
run_guard check-test-scratch.py python3 -B scripts/ci/check-test-scratch.py
run_guard check-persistence-doc.py python3 -B scripts/ci/check-persistence-doc.py
run_guard check-version.py python3 -B scripts/ci/check-version.py
run_guard check-regression-gates.sh bash scripts/ci/check-regression-gates.sh
run_guard check-fingerprint-id-keying.sh bash scripts/ci/check-fingerprint-id-keying.sh

if (( ${#failed[@]} )); then
  echo "Static guards failed: ${failed[*]}"
  exit 1
fi
echo "All static guards passed."
