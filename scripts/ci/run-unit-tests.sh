#!/usr/bin/env bash
# Run the unit tests with coverage. Writes test-start.marker (the diagnostics collector keeps
# only crash reports newer than it), test.log and TestResults.xcresult to the current directory.
set -euo pipefail

echo "::group::Unit tests"
echo "Running unit tests with code coverage enabled..."
# Retain full output; the failure step prints reasons outside this tail.
touch test-start.marker
xcodebuild \
  -project photo-export.xcodeproj \
  -scheme "photo-export" \
  -destination 'platform=macOS' \
  -enableCodeCoverage YES \
  -resultBundlePath TestResults.xcresult \
  CODE_SIGNING_ALLOWED=NO \
  test 2>&1 | tee test.log | tail -300
echo "Unit tests passed."
echo "Result bundle: $(du -sh TestResults.xcresult)"
echo "::endgroup::"
