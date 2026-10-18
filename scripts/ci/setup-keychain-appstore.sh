#!/bin/bash
set -euo pipefail

# Creates a temporary keychain and imports Apple Distribution and
# Mac Installer Distribution certificates for App Store signing.
#
# Required environment variables:
#   RUNNER_TEMP
#   APPLE_DISTRIBUTION_CERTIFICATE_P12_BASE64
#   APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD
#   MAC_INSTALLER_DISTRIBUTION_CERTIFICATE_P12_BASE64
#   MAC_INSTALLER_DISTRIBUTION_CERTIFICATE_PASSWORD
#
# Exports via GITHUB_ENV:
#   KEYCHAIN_PATH
#   KEYCHAIN_PASSWORD
#   INSTALLER_SIGNING_CERTIFICATE

echo "=== App Store Keychain Setup ==="

# Validate required env vars
for var in RUNNER_TEMP APPLE_DISTRIBUTION_CERTIFICATE_P12_BASE64 APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD MAC_INSTALLER_DISTRIBUTION_CERTIFICATE_P12_BASE64 MAC_INSTALLER_DISTRIBUTION_CERTIFICATE_PASSWORD; do
  if [ -z "${!var:-}" ]; then
    echo "::error::Required environment variable ${var} is not set"
    exit 1
  fi
done

KEYCHAIN_PATH="${RUNNER_TEMP}/appstore-release.keychain-db"
KEYCHAIN_PASSWORD="$(uuidgen)"
echo "::add-mask::${KEYCHAIN_PASSWORD}"

echo "Creating temporary keychain at ${KEYCHAIN_PATH}..."
security create-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_PATH}"

echo "Configuring keychain settings (no auto-lock, 6-hour timeout)..."
security set-keychain-settings -lut 21600 "${KEYCHAIN_PATH}"

echo "Unlocking keychain..."
security unlock-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_PATH}"

echo "Adding keychain to search list and setting as default..."
security list-keychains -d user -s "${KEYCHAIN_PATH}" $(security list-keychains -d user | tr -d '"')
security default-keychain -s "${KEYCHAIN_PATH}"

# ── Apple Distribution certificate ──────────────────────────────────
echo ""
echo "Decoding Apple Distribution certificate..."
APP_CERT_PATH="${RUNNER_TEMP}/apple-distribution.p12"
echo "${APPLE_DISTRIBUTION_CERTIFICATE_P12_BASE64}" | base64 --decode > "${APP_CERT_PATH}"

echo "Importing Apple Distribution certificate..."
security import "${APP_CERT_PATH}" \
  -k "${KEYCHAIN_PATH}" \
  -P "${APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD}" \
  -A
rm -f "${APP_CERT_PATH}"
echo "Apple Distribution certificate imported."

# ── Mac Installer Distribution certificate ──────────────────────────
echo ""
echo "Decoding Mac Installer Distribution certificate..."
INSTALLER_CERT_PATH="${RUNNER_TEMP}/mac-installer-distribution.p12"
echo "${MAC_INSTALLER_DISTRIBUTION_CERTIFICATE_P12_BASE64}" | base64 --decode > "${INSTALLER_CERT_PATH}"

echo "Importing Mac Installer Distribution certificate..."
security import "${INSTALLER_CERT_PATH}" \
  -k "${KEYCHAIN_PATH}" \
  -P "${MAC_INSTALLER_DISTRIBUTION_CERTIFICATE_PASSWORD}" \
  -A
rm -f "${INSTALLER_CERT_PATH}"
echo "Mac Installer Distribution certificate imported."

# ── Key partition list ──────────────────────────────────────────────
echo ""
echo "Setting key partition list for codesign access..."
security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s -k "${KEYCHAIN_PASSWORD}" \
  "${KEYCHAIN_PATH}"

echo ""
echo "Verifying imported certificates:"
security find-identity -v "${KEYCHAIN_PATH}"

echo ""
echo "Codesigning identities:"
security find-identity -v -p codesigning "${KEYCHAIN_PATH}"

echo ""
echo "Imported Apple Distribution certificates:"
security find-certificate -a -c "Apple Distribution" -Z "${KEYCHAIN_PATH}" || true

echo ""
echo "Imported Mac Installer Distribution certificates:"
security find-certificate -a -c "Mac Installer Distribution" -Z "${KEYCHAIN_PATH}" || true
security find-certificate -a -c "3rd Party Mac Developer Installer" -Z "${KEYCHAIN_PATH}" || true

INSTALLER_SIGNING_CERTIFICATE="$(security find-identity -v "${KEYCHAIN_PATH}" | awk '/3rd Party Mac Developer Installer:|Mac Installer Distribution:/{print $2; exit}')"
if [ -z "${INSTALLER_SIGNING_CERTIFICATE}" ]; then
  echo "::error::Unable to determine installer signing certificate identity"
  exit 1
fi

echo ""
echo "Selected installer signing certificate: ${INSTALLER_SIGNING_CERTIFICATE}"

# Export for later steps
echo "KEYCHAIN_PATH=${KEYCHAIN_PATH}" >> "$GITHUB_ENV"
echo "KEYCHAIN_PASSWORD=${KEYCHAIN_PASSWORD}" >> "$GITHUB_ENV"
echo "INSTALLER_SIGNING_CERTIFICATE=${INSTALLER_SIGNING_CERTIFICATE}" >> "$GITHUB_ENV"

echo ""
echo "=== Keychain setup complete ==="
