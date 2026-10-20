#!/usr/bin/env bash
# Check a built app before it ships or is recorded: it must have been built by the expected Xcode
# and carry the export-compliance key. Without the key, App Store Connect asks the encryption
# question again for every build.
#
# Usage: check-built-app.sh [--app <path to .app>] [<xcode version>]
#   --app      check this app (a release archive or export); without it, the Release build's
#              product is found through `xcodebuild -showBuildSettings`.
#   version    the Xcode that must have built it; defaults to .xcode-version. Only the canary
#              passes one.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
app=""
if [[ "${1:-}" == "--app" ]]; then
  app="${2:?--app needs a path}"
  shift 2
fi
if [[ $# -gt 0 ]]; then
  version="$1"
else
  version="$(tr -d '[:space:]' < "${repo_root}/.xcode-version")"
fi
IFS=. read -r major minor patch <<< "${version}"
# Xcode 26.6 -> DTXcode 2660; 16.2.1 -> 1621.
expected="$(printf '%d%d%d' "${major}" "${minor:-0}" "${patch:-0}")"

if [[ -z "${app}" ]]; then
  if ! settings="$(xcodebuild -project photo-export.xcodeproj -scheme "photo-export" \
    -configuration Release -showBuildSettings 2>&1)"; then
    echo "${settings}" | tail -20
    echo "::error::xcodebuild -showBuildSettings failed; cannot locate the Release app" >&2
    exit 1
  fi
  setting() { awk -F' = ' -v key="$1" '$1 ~ "^ *" key "$" { print $2; exit }' <<< "${settings}"; }
  app="$(setting TARGET_BUILD_DIR)/$(setting FULL_PRODUCT_NAME)"
fi
plist="${app}/Contents/Info.plist"

echo "::group::Built app"
echo "App: ${app}"
if [[ ! -f "${plist}" ]]; then
  echo "::error::Info.plist not found at ${plist}" >&2
  exit 1
fi
# Decide from plutil's status: some macOS versions print the "no value" error to stdout.
value() {
  local extracted
  if extracted="$(plutil -extract "$1" raw -o - "${plist}" 2>/dev/null)"; then
    printf '%s' "${extracted}"
  else
    printf 'absent'
  fi
}
for key in ITSAppUsesNonExemptEncryption DTXcode DTXcodeBuild DTSDKBuild DTSDKName \
  LSMinimumSystemVersion; do
  echo "${key}: $(value "${key}")"
done
built="$(value DTXcode)"
compliance="$(value ITSAppUsesNonExemptEncryption)"
echo "::endgroup::"
if [[ "${built}" != "${expected}" ]]; then
  echo "::error::App was built by DTXcode ${built}, expected ${expected} for Xcode ${version}" >&2
  exit 1
fi
if [[ "${compliance}" != "false" ]]; then
  echo "::error::ITSAppUsesNonExemptEncryption is ${compliance}, expected false" >&2
  exit 1
fi
