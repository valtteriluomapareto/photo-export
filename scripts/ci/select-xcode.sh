#!/usr/bin/env bash
# Select the Xcode pinned in .xcode-version (or the version given as the first argument)
# and prove it is the toolchain that later steps will use. Never falls back to another
# installed Xcode.
#
# Test seams: XCODE_APPS_DIR (default /Applications) and XCODE_SELECT_CMD
# (default "sudo xcode-select"; selecting needs root on the runners).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
apps_dir="${XCODE_APPS_DIR:-/Applications}"
select_cmd="${XCODE_SELECT_CMD:-sudo xcode-select}"

fail() {
  echo "::error::$1" >&2
  exit 1
}

echo "::group::Xcode selection"
if [[ $# -gt 0 ]]; then
  version="$1"
  echo "Requested Xcode: ${version} (argument)"
else
  [[ -f "${repo_root}/.xcode-version" ]] || fail "Missing ${repo_root}/.xcode-version"
  version="$(tr -d '[:space:]' < "${repo_root}/.xcode-version")"
  echo "Requested Xcode: ${version} (.xcode-version)"
fi
[[ "${version}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] \
  || fail "Xcode version '${version}' must look like 26.6 or 26.6.1"

echo "Installed Xcode apps in ${apps_dir}:"
shopt -s nullglob
installed=("${apps_dir}"/Xcode*.app)
if [[ ${#installed[@]} -eq 0 ]]; then
  echo "  (none)"
else
  for app in "${installed[@]}"; do
    if [[ -L "${app}" ]]; then
      echo "  $(basename "${app}") -> $(basename "$(cd "${app}" && pwd -P)")"
    else
      echo "  $(basename "${app}")"
    fi
  done
fi

# DEVELOPER_DIR overrides xcode-select for every tool and TOOLCHAINS swaps the Swift toolchain,
# so either would silently bypass the selection.
[[ -z "${DEVELOPER_DIR:-}" ]] || fail "DEVELOPER_DIR is set (${DEVELOPER_DIR}); it would override the selected Xcode"
[[ -z "${TOOLCHAINS:-}" ]] || fail "TOOLCHAINS is set (${TOOLCHAINS}); it would override the selected Swift toolchain"

app="${apps_dir}/Xcode_${version}.app"
[[ -d "${app}" ]] || fail "Xcode ${version} is not installed at ${app}; installed apps are listed above"
resolved="$(cd "${app}" && pwd -P)"
echo "Selecting ${resolved}"
${select_cmd} -s "${resolved}"

active="$(xcode-select -p)"
echo "Active developer directory: ${active}"
[[ "${active}" == "${resolved}/Contents/Developer" ]] \
  || fail "Active developer directory ${active} is not ${resolved}/Contents/Developer"

version_output="$(xcodebuild -version)"
echo "${version_output}"
reported="${version_output%%$'\n'*}"
[[ "${reported}" == "Xcode ${version}" ]] || fail "Selected app reports '${reported}', expected 'Xcode ${version}'"

echo "Swift: $(swift --version 2>&1 | head -1)"
echo "macOS SDKs:"
xcodebuild -showsdks 2>/dev/null | grep macosx || echo "  (none listed)"
echo "::endgroup::"
