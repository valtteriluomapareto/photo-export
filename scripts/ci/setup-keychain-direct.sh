#!/usr/bin/env bash
# Prepare the temporary Developer ID keychain and notary profile.
set -euo pipefail

echo "::group::Keychain setup"

KEYCHAIN_PATH="${RUNNER_TEMP}/release.keychain-db"
KEYCHAIN_PASSWORD="$(uuidgen)"
echo "::add-mask::${KEYCHAIN_PASSWORD}"

echo "Creating temporary keychain at ${KEYCHAIN_PATH}..."
security create-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_PATH}"

echo "Configuring keychain settings (no auto-lock)..."
security set-keychain-settings -lut 21600 "${KEYCHAIN_PATH}"

echo "Unlocking keychain..."
security unlock-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_PATH}"

echo "Adding keychain to search list..."
existing_keychain_list="$(security list-keychains -d user)"
keychain_search_paths=("${KEYCHAIN_PATH}")
while IFS= read -r keychain_entry; do
  keychain_entry="${keychain_entry#"${keychain_entry%%[![:space:]]*}"}"
  keychain_entry="${keychain_entry#\"}"
  keychain_entry="${keychain_entry%\"}"
  if [[ -n "$keychain_entry" ]]; then keychain_search_paths+=("$keychain_entry"); fi
done <<< "$existing_keychain_list"
security list-keychains -d user -s "${keychain_search_paths[@]}"

echo "Decoding and importing Developer ID certificate..."
CERT_PATH="${RUNNER_TEMP}/certificate.p12"
echo "${CERTIFICATE_P12_BASE64}" | base64 --decode > "${CERT_PATH}"
security import "${CERT_PATH}" \
  -k "${KEYCHAIN_PATH}" \
  -P "${CERTIFICATE_PASSWORD}" \
  -T /usr/bin/codesign \
  -T /usr/bin/security
rm -f "${CERT_PATH}"

echo "Setting key partition list for codesign access..."
security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s -k "${KEYCHAIN_PASSWORD}" \
  "${KEYCHAIN_PATH}"

echo "Storing notarytool credentials in keychain..."
xcrun notarytool store-credentials "notarytool-profile" \
  --apple-id "${APPLE_ID}" \
  --team-id "${APPLE_TEAM_ID}" \
  --password "${APPLE_APP_SPECIFIC_PASSWORD}" \
  --keychain "${KEYCHAIN_PATH}"

echo "Verifying certificate was imported:"
security find-identity -v -p codesigning "${KEYCHAIN_PATH}"

# Export for later steps
{
  echo "KEYCHAIN_PATH=${KEYCHAIN_PATH}"
  echo "KEYCHAIN_PASSWORD=${KEYCHAIN_PASSWORD}"
} >> "$GITHUB_ENV"

echo "Keychain setup complete."
echo "::endgroup::"
