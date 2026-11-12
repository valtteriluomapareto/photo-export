#!/bin/bash
set -euo pipefail

# Installs the App Store provisioning profile where Xcode can find it.
#
# Required environment variables:
#   RUNNER_TEMP
#   APP_STORE_PROVISIONING_PROFILE_BASE64
#
# Exports via GITHUB_ENV:
#   PROFILE_UUID
#   PROFILE_NAME
#   PROFILES_DIR

echo "=== Provisioning Profile Installation ==="

for var in RUNNER_TEMP APP_STORE_PROVISIONING_PROFILE_BASE64; do
  if [ -z "${!var:-}" ]; then
    echo "::error::Required environment variable ${var} is not set"
    exit 1
  fi
done

echo "Decoding provisioning profile..."
PROFILE_PATH="${RUNNER_TEMP}/appstore.provisioningprofile"
PROFILE_PLIST_PATH="${RUNNER_TEMP}/appstore.provisioningprofile.plist"
echo "${APP_STORE_PROVISIONING_PROFILE_BASE64}" | base64 --decode > "${PROFILE_PATH}"
echo "Profile decoded to: ${PROFILE_PATH}"
echo "Profile size: $(wc -c < "${PROFILE_PATH}") bytes"

echo ""
echo "Extracting profile metadata..."
security cms -D -i "${PROFILE_PATH}" > "${PROFILE_PLIST_PATH}"

PROFILE_UUID=$(/usr/libexec/PlistBuddy -c "Print UUID" "${PROFILE_PLIST_PATH}")
PROFILE_NAME=$(/usr/libexec/PlistBuddy -c "Print Name" "${PROFILE_PLIST_PATH}")
PROFILE_TEAM=$(/usr/libexec/PlistBuddy -c "Print TeamIdentifier:0" "${PROFILE_PLIST_PATH}" 2>/dev/null || echo "unknown")
PROFILE_EXPIRY=$(/usr/libexec/PlistBuddy -c "Print ExpirationDate" "${PROFILE_PLIST_PATH}" 2>/dev/null || echo "unknown")
PROFILE_PLATFORM=$(/usr/libexec/PlistBuddy -c "Print Platform:0" "${PROFILE_PLIST_PATH}" 2>/dev/null || echo "unknown")

# On macOS profiles the standard App ID entitlement is
# `com.apple.application-identifier`; on other platforms it is
# `application-identifier`.
PROFILE_APP_ID=$(/usr/libexec/PlistBuddy -c "Print Entitlements:com.apple.application-identifier" "${PROFILE_PLIST_PATH}" 2>/dev/null || true)
if [ -z "${PROFILE_APP_ID}" ]; then
  PROFILE_APP_ID=$(/usr/libexec/PlistBuddy -c "Print Entitlements:application-identifier" "${PROFILE_PLIST_PATH}" 2>/dev/null || true)
fi
if [ -z "${PROFILE_APP_ID}" ]; then
  PROFILE_APP_ID="unknown"
fi

echo ""
echo "Profile details:"
echo "  UUID:       ${PROFILE_UUID}"
echo "  Name:       ${PROFILE_NAME}"
echo "  Platform:   ${PROFILE_PLATFORM}"
echo "  Team:       ${PROFILE_TEAM}"
echo "  App ID:     ${PROFILE_APP_ID}"
echo "  Expires:    ${PROFILE_EXPIRY}"

if [ -n "${APPSTORE_BUNDLE_ID:-}" ]; then
  EXPECTED_SUFFIX=".${APPSTORE_BUNDLE_ID}"
  if [[ "${PROFILE_APP_ID}" != *"${EXPECTED_SUFFIX}" ]]; then
    echo "::error::Provisioning profile App ID does not match expected bundle ID."
    echo "::error::Expected suffix: ${EXPECTED_SUFFIX}"
    echo "::error::Actual App ID:  ${PROFILE_APP_ID}"
    exit 1
  fi
  echo "  Bundle ID verified for ${APPSTORE_BUNDLE_ID}."
fi

echo ""
echo "Profile developer certificates:"
PROFILE_CERT_COUNT=0
PROFILE_CERT_TMP_DIR="${RUNNER_TEMP}/profile-certs"
rm -rf "${PROFILE_CERT_TMP_DIR}"
mkdir -p "${PROFILE_CERT_TMP_DIR}"

while true; do
  CERT_PATH="${PROFILE_CERT_TMP_DIR}/developer-cert-${PROFILE_CERT_COUNT}.cer"
  if ! plutil -extract "DeveloperCertificates.${PROFILE_CERT_COUNT}" raw -o - "${PROFILE_PLIST_PATH}" | base64 -D > "${CERT_PATH}" 2>/dev/null; then
    rm -f "${CERT_PATH}"
    break
  fi

  echo "  DeveloperCertificates[${PROFILE_CERT_COUNT}]:"
  openssl x509 -inform DER -in "${CERT_PATH}" -noout -subject -serial -fingerprint -sha1
  PROFILE_CERT_COUNT=$((PROFILE_CERT_COUNT + 1))
done

echo "  Count: ${PROFILE_CERT_COUNT}"

PROFILES_DIR="${HOME}/Library/MobileDevice/Provisioning Profiles"
XCODE_PROFILES_DIR="${HOME}/Library/Developer/Xcode/UserData/Provisioning Profiles"
mkdir -p "${PROFILES_DIR}" "${XCODE_PROFILES_DIR}"

echo ""
echo "Installing profile to: ${PROFILES_DIR}/${PROFILE_UUID}.provisionprofile"
cp "${PROFILE_PATH}" "${PROFILES_DIR}/${PROFILE_UUID}.provisionprofile"
echo "Installing profile to: ${XCODE_PROFILES_DIR}/${PROFILE_UUID}.provisionprofile"
cp "${PROFILE_PATH}" "${XCODE_PROFILES_DIR}/${PROFILE_UUID}.provisionprofile"
rm -f "${PROFILE_PATH}" "${PROFILE_PLIST_PATH}"
rm -rf "${PROFILE_CERT_TMP_DIR}"

echo ""
echo "Installed profiles (MobileDevice):"
ls -la "${PROFILES_DIR}/"

echo ""
echo "Installed profiles (Xcode UserData):"
ls -la "${XCODE_PROFILES_DIR}/"

# Export for later steps
{
  echo "PROFILE_UUID=${PROFILE_UUID}"
  echo "PROFILE_NAME=${PROFILE_NAME}"
  echo "PROFILES_DIR=${XCODE_PROFILES_DIR}"
} >> "$GITHUB_ENV"

echo ""
echo "=== Provisioning profile installation complete ==="
