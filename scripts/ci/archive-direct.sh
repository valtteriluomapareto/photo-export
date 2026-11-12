#!/usr/bin/env bash
# Archive Developer ID distribution with complete sanitized diagnostics.
set -euo pipefail

echo "::group::Archive"
ARCHIVE_PATH="${RUNNER_TEMP}/photo-export.xcarchive"

BUILD_NUMBER="${GITHUB_RUN_NUMBER}"
echo "Archiving Release build..."
echo "  ARCHS=arm64 x86_64 (universal)"
echo "  CODE_SIGN_STYLE=Manual"
echo "  CODE_SIGN_IDENTITY=Developer ID Application"
echo "  DEVELOPMENT_TEAM=[REDACTED]"
echo "  KEYCHAIN_PATH=${KEYCHAIN_PATH}"
echo "  CURRENT_PROJECT_VERSION=${BUILD_NUMBER}"

set -o pipefail
xcodebuild archive \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -configuration Release \
  -destination 'platform=macOS' \
  -archivePath "${ARCHIVE_PATH}" \
  "ARCHS=arm64 x86_64" \
  CODE_SIGN_STYLE=Manual \
  "CODE_SIGN_IDENTITY=Developer ID Application" \
  DEVELOPMENT_TEAM="${APPLE_TEAM_ID}" \
  "OTHER_CODE_SIGN_FLAGS=--keychain ${KEYCHAIN_PATH}" \
  CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
  2>&1 | python3 scripts/ci/sanitize-release-log.py \
    | tee "${RUNNER_TEMP}/photo-export-direct-archive.log" | tail -30

echo ""
echo "Archive created at: ${ARCHIVE_PATH}"
echo "Archive size: $(du -sh "${ARCHIVE_PATH}" | cut -f1)"
ls -la "${ARCHIVE_PATH}/Products/Applications/"

echo "ARCHIVE_PATH=${ARCHIVE_PATH}" >> "$GITHUB_ENV"
echo "::endgroup::"
