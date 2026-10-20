#!/usr/bin/env bash
# Print which toolchain built the Release app and whether the export-compliance key reached
# its Info.plist. Report only: the toolchain canary records these values for the bump.
set -uo pipefail

settings="$(xcodebuild -project photo-export.xcodeproj -scheme "photo-export" \
  -configuration Release -showBuildSettings 2>/dev/null)"
setting() { awk -F' = ' -v key="$1" '$1 ~ "^ *" key "$" { print $2; exit }' <<< "${settings}"; }
plist="$(setting TARGET_BUILD_DIR)/$(setting FULL_PRODUCT_NAME)/Contents/Info.plist"

echo "::group::Built Release app"
echo "Info.plist: ${plist}"
if [[ ! -f "${plist}" ]]; then
  echo "::warning::Release Info.plist not found"
else
  for key in ITSAppUsesNonExemptEncryption DTXcode DTXcodeBuild DTSDKBuild DTSDKName; do
    echo "${key}: $(plutil -extract "${key}" raw -o - "${plist}" 2>/dev/null || echo absent)"
  done
fi
echo "::endgroup::"
