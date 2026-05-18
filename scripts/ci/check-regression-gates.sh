#!/usr/bin/env bash
#
# Verify that the regression-gate tests documented in
# docs/reference/architecture-conventions.md §Regression gates still exist
# under their documented names. Fails CI if a rename has rotted the doc.
#
# To add or remove a gate: update both this file AND the architecture-
# conventions doc in the same PR.

set -euo pipefail

cd "$(dirname "$0")/../.."

echo "Checking regression-gate test symbols against photo-exportTests/..."

# Each entry is "<test file>|<grep needle>".
# Class-level gates use "struct <Name>"; method-level gates use "func <name>".
# Method-level entries also pin the containing class via a separate row so a
# class rename is caught even if a same-named method survives in another file.
GATES=(
  "photo-exportTests/AutoSyncSeamCharacterizationTests.swift|struct AutoSyncSeamCharacterizationTests"
  "photo-exportTests/ExportQueueStateSnapshotTests.swift|struct ExportQueueStateSnapshotTests"
  "photo-exportTests/ExportQueueStateSnapshotTests.swift|func teardownQueue_synchronouslyClearsManagerMirrors"
  "photo-exportTests/ExportQueueStateSnapshotTests.swift|func pauseResumeCancelStateSnapshot_canonicalTransitions"
  "photo-exportTests/ScreenshotPhotoLibraryServiceOverridesTests.swift|struct ScreenshotPhotoLibraryServiceOverridesTests"
  "photo-exportTests/ImportIdempotencyTests.swift|struct ImportIdempotencyTests"
  "photo-exportTests/ExportManagerRunExportTests.swift|struct ExportManagerRunExportTests"
  "photo-exportTests/ExportManagerRunExportTests.swift|func autoSyncRunFilterAlreadyExportedBeforeRetryCheck"
)

failed=0
for entry in "${GATES[@]}"; do
  file="${entry%%|*}"
  needle="${entry##*|}"
  if [[ ! -f "$file" ]]; then
    echo "  MISSING FILE: $file (looking for: $needle)"
    failed=1
    continue
  fi
  if ! grep -q -- "$needle" "$file"; then
    echo "  MISSING SYMBOL: '$needle' not found in $file"
    failed=1
    continue
  fi
  echo "  OK: $needle in $file"
done

if [[ $failed -eq 1 ]]; then
  echo
  echo "One or more regression-gate symbols are missing from the codebase."
  echo "If a regression-gate test was intentionally renamed or moved, update:"
  echo "  - docs/reference/architecture-conventions.md §Regression gates"
  echo "  - scripts/ci/check-regression-gates.sh (this file)"
  exit 1
fi

echo "All regression-gate symbols present."
