#!/bin/bash
set -euo pipefail

# Builds and archives the app with App Store signing configuration.
#
# Required environment variables:
#   PROJECT
#   SCHEME
#   RUNNER_TEMP
#   APPLE_TEAM_ID
#   KEYCHAIN_PATH
#   PROFILE_UUID
#   PROFILE_NAME
#   BUILD_NUMBER
#   APPSTORE_BUNDLE_ID

echo "=== App Store Archive ==="

for var in PROJECT SCHEME RUNNER_TEMP APPLE_TEAM_ID KEYCHAIN_PATH PROFILE_UUID PROFILE_NAME BUILD_NUMBER APPSTORE_BUNDLE_ID; do
  if [ -z "${!var:-}" ]; then
    echo "::error::Required environment variable ${var} is not set"
    exit 1
  fi
done

ARCHIVE_PATH="${RUNNER_TEMP}/photo-export-appstore.xcarchive"

echo "Build configuration:"
echo "  Project:              ${PROJECT}"
echo "  Scheme:               ${SCHEME}"
echo "  Archive path:         ${ARCHIVE_PATH}"
echo "  Architectures:        arm64 x86_64 (universal)"
echo "  Code sign style:      Manual"
echo "  Code sign identity:   Apple Distribution"
echo "  Development team:     [REDACTED]"
echo "  Bundle identifier:    ${APPSTORE_BUNDLE_ID}"
echo "  Provisioning profile: ${PROFILE_UUID}${PROFILE_NAME:+ (${PROFILE_NAME})}"
echo "  Build number:         ${BUILD_NUMBER}"
echo "  Keychain:             ${KEYCHAIN_PATH}"
echo ""

echo "Installed provisioning profiles before archive:"
ls -la "${PROFILES_DIR}/"

echo ""
echo "Relevant build settings:"
{
  xcodebuild -project "${PROJECT}" -scheme "${SCHEME}" -showBuildSettings \
    | grep -E 'CODE_SIGN|DEVELOPMENT_TEAM|PRODUCT_BUNDLE_IDENTIFIER|PROVISIONING_PROFILE' || true
} 2>&1 | python3 scripts/ci/sanitize-release-log.py

echo ""
set -o pipefail
xcodebuild archive \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -configuration Release \
  -destination 'platform=macOS' \
  -archivePath "${ARCHIVE_PATH}" \
  "ARCHS=arm64 x86_64" \
  CODE_SIGN_STYLE=Manual \
  "CODE_SIGN_IDENTITY=Apple Distribution" \
  DEVELOPMENT_TEAM="${APPLE_TEAM_ID}" \
  "OTHER_CODE_SIGN_FLAGS=--keychain ${KEYCHAIN_PATH}" \
  PRODUCT_BUNDLE_IDENTIFIER="${APPSTORE_BUNDLE_ID}" \
  "PROVISIONING_PROFILE_SPECIFIER=${PROFILE_NAME}" \
  CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
  2>&1 | python3 scripts/ci/sanitize-release-log.py \
    | tee "${RUNNER_TEMP}/photo-export-appstore-archive.log" | tail -30

echo ""
echo "Archive created at: ${ARCHIVE_PATH}"
echo "Archive size: $(du -sh "${ARCHIVE_PATH}" | cut -f1)"

echo ""
echo "Archive contents:"
ls -la "${ARCHIVE_PATH}/Products/Applications/"

# Verify the archive has the correct bundle ID and build number
echo ""
echo "Verifying archive Info.plist values..."
APP_IN_ARCHIVE=$(find "${ARCHIVE_PATH}/Products/Applications" -name "*.app" -maxdepth 1 | head -1)
if [ -n "${APP_IN_ARCHIVE}" ]; then
  ARCHIVED_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "${APP_IN_ARCHIVE}/Contents/Info.plist")
  ARCHIVED_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "${APP_IN_ARCHIVE}/Contents/Info.plist")
  ARCHIVED_BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "${APP_IN_ARCHIVE}/Contents/Info.plist")
  echo "  Bundle ID:      ${ARCHIVED_BUNDLE_ID}"
  echo "  Version:        ${ARCHIVED_VERSION}"
  echo "  Build number:   ${ARCHIVED_BUILD}"

  if [ "${ARCHIVED_BUNDLE_ID}" != "${APPSTORE_BUNDLE_ID}" ]; then
    echo "::error::Bundle ID mismatch! Expected ${APPSTORE_BUNDLE_ID}, got ${ARCHIVED_BUNDLE_ID}"
    exit 1
  fi
  echo "  Bundle ID verified."
else
  echo "::warning::Could not find .app in archive to verify — continuing anyway"
fi

echo "ARCHIVE_PATH=${ARCHIVE_PATH}" >> "$GITHUB_ENV"

echo ""
echo "=== Archive complete ==="
