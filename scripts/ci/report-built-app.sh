#!/usr/bin/env bash
# Print which toolchain built the Release app and whether the export-compliance key reached its
# Info.plist, for the toolchain canary's record. Fails when the app's plist is missing or was
# built by a different Xcode than the one given, so a lane cannot pass without its evidence.
set -euo pipefail

version="${1:?usage: report-built-app.sh <xcode version, e.g. 26.6>}"
IFS=. read -r major minor patch <<< "${version}"
# Xcode 26.6 -> DTXcode 2660; 16.2.1 -> 1621.
expected="$(printf '%d%d%d' "${major}" "${minor:-0}" "${patch:-0}")"

settings="$(xcodebuild -project photo-export.xcodeproj -scheme "photo-export" \
  -configuration Release -showBuildSettings 2>/dev/null)"
setting() { awk -F' = ' -v key="$1" '$1 ~ "^ *" key "$" { print $2; exit }' <<< "${settings}"; }
plist="$(setting TARGET_BUILD_DIR)/$(setting FULL_PRODUCT_NAME)/Contents/Info.plist"

echo "::group::Built Release app"
echo "Info.plist: ${plist}"
if [[ ! -f "${plist}" ]]; then
  echo "::error::Release Info.plist not found at ${plist}" >&2
  exit 1
fi
for key in ITSAppUsesNonExemptEncryption DTXcode DTXcodeBuild DTSDKBuild DTSDKName; do
  echo "${key}: $(plutil -extract "${key}" raw -o - "${plist}" 2>/dev/null || echo absent)"
done
built="$(plutil -extract DTXcode raw -o - "${plist}" 2>/dev/null || echo absent)"
echo "::endgroup::"
if [[ "${built}" != "${expected}" ]]; then
  echo "::error::Release app was built by DTXcode ${built}, expected ${expected} for Xcode ${version}" >&2
  exit 1
fi
