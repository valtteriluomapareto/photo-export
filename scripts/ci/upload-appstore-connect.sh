#!/bin/bash
set -euo pipefail

# Uploads the .pkg to App Store Connect via xcrun altool.
#
# The API key is placed in the standard search directory so altool
# discovers it automatically via --apiKey / --apiIssuer.
#
# altool is deprecated for notarization (replaced by notarytool) but is
# still the App Store upload tool; the preflight below fails before an
# upload if a future Xcode drops --upload-package. The replacement then is
# iTMSTransporter or the App Store Connect REST API.
#
# Required environment variables:
#   PKG_PATH
#   PKG_NAME
#   BUILD_NUMBER
#   VERSION
#   APPSTORE_BUNDLE_ID
#   APP_STORE_APP_APPLE_ID               — numeric Apple ID from App Store Connect
#   APP_STORE_CONNECT_API_KEY_BASE64
#   APP_STORE_CONNECT_API_KEY_ID
#   APP_STORE_CONNECT_API_ISSUER_ID

echo "=== Upload to App Store Connect ==="

for var in PKG_PATH PKG_NAME BUILD_NUMBER VERSION APPSTORE_BUNDLE_ID APP_STORE_APP_APPLE_ID APP_STORE_CONNECT_API_KEY_BASE64 APP_STORE_CONNECT_API_KEY_ID APP_STORE_CONNECT_API_ISSUER_ID; do
  if [ -z "${!var:-}" ]; then
    echo "::error::Required environment variable ${var} is not set"
    exit 1
  fi
done

# Place the API key where altool expects it
echo "Setting up App Store Connect API key..."
API_KEY_DIR="${HOME}/.appstoreconnect/private_keys"
mkdir -p "${API_KEY_DIR}"
API_KEY_PATH="${API_KEY_DIR}/AuthKey_${APP_STORE_CONNECT_API_KEY_ID}.p8"
echo "${APP_STORE_CONNECT_API_KEY_BASE64}" | base64 --decode > "${API_KEY_PATH}"
echo "API key placed at: ${API_KEY_PATH}"

echo ""
echo "Upload details:"
echo "  Package:    ${PKG_NAME}"
echo "  Bundle ID:  ${APPSTORE_BUNDLE_ID}"
echo "  Apple ID:   ${APP_STORE_APP_APPLE_ID}"
echo "  Version:    ${VERSION}"
echo "  Build:      ${BUILD_NUMBER}"
echo "  API Key ID: ${APP_STORE_CONNECT_API_KEY_ID}"
echo "  Issuer ID:  ${APP_STORE_CONNECT_API_ISSUER_ID}"
echo ""

echo "Checking that altool still uploads packages..."
if ! xcrun altool --help 2>&1 | grep -q -- '--upload-package'; then
  echo "::error::xcrun altool in $(xcode-select -p) has no --upload-package"
  exit 1
fi

# altool upload synopsis:
#   xcrun altool --upload-package <file> --type <macos|ios|...>
#     --apple-id <id> --bundle-id <id> --bundle-version <string>
#     --bundle-short-version-string <string> authentication [options]
echo "Uploading to App Store Connect..."
xcrun altool --upload-package "${PKG_PATH}" \
  --type macos \
  --apple-id "${APP_STORE_APP_APPLE_ID}" \
  --bundle-id "${APPSTORE_BUNDLE_ID}" \
  --bundle-version "${BUILD_NUMBER}" \
  --bundle-short-version-string "${VERSION}" \
  --apiKey "${APP_STORE_CONNECT_API_KEY_ID}" \
  --apiIssuer "${APP_STORE_CONNECT_API_ISSUER_ID}" \
  --show-progress

echo ""
echo "Upload complete."
echo "The build will appear in App Store Connect / TestFlight within 5-30 minutes."
echo "Review submission remains manual."

echo ""
echo "=== App Store Connect upload complete ==="
