#!/bin/bash
# Pinned CI tools for macOS15+ arm64 with Command Line Tools installed (the CI image):
# SwiftLint, swift-format, actionlint and ShellCheck. Every archive is SHA256-checked and
# every binary must report its exact version before any path reaches GITHUB_PATH.
# SwiftLint: https://github.com/realm/SwiftLint/releases/tag/0.65.1
# swift-format bottle: Homebrew/homebrew-core@919ebb6e47be295a336446ea3e5a4a6637871748
# https://github.com/Homebrew/homebrew-core/blob/919ebb6e47be295a336446ea3e5a4a6637871748/Formula/s/swift-format.rb
# arm64_sequoia, no runtime dependencies, CLT required.
# actionlint: https://github.com/rhysd/actionlint/releases/tag/v1.7.12
# ShellCheck: https://github.com/koalaman/shellcheck/releases/tag/v0.11.0
set -euo pipefail
: "${RUNNER_TEMP:?RUNNER_TEMP must name a writable temporary directory}"
: "${GITHUB_PATH:?GITHUB_PATH must name the path output file}"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo "Pinned CI tools require macOS15+ arm64 with Command Line Tools installed." >&2
  exit 1
fi
macos_version="$(sw_vers -productVersion)"
if [[ "${macos_version%%.*}" -lt 15 ]]; then
  echo "Pinned CI tools require macOS15 or later." >&2
  exit 1
fi
install_root="$(mktemp -d "${RUNNER_TEMP}/ci-tools.XXXXXX")"
installed=false
trap 'if [[ "$installed" != true ]]; then rm -rf "$install_root"; fi' EXIT
lint_archive="$install_root/swiftlint.zip"
format_archive="$install_root/swift-format.tar.gz"
actionlint_archive="$install_root/actionlint.tar.gz"
shellcheck_archive="$install_root/shellcheck.tar.gz"

# Download one archive and stop unless it matches its pinned SHA256. Extra arguments go to curl.
download() {
  local label="$1" url="$2" sha256="$3" archive="$4"
  shift 4
  echo "Downloading $label from $url"
  curl --fail --location --retry 3 --silent --show-error "$@" "$url" --output "$archive"
  printf '%s  %s\n' "$sha256" "$archive" | shasum -a 256 -c
}

download 'SwiftLint 0.65.1' \
  'https://github.com/realm/SwiftLint/releases/download/0.65.1/portable_swiftlint.zip' \
  'c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0' "$lint_archive"
unzip -q "$lint_archive" -d "$install_root/swiftlint"

# GHCR's public anonymous token, not a signing credential or repository secret.
download 'swift-format 603.0.0' \
  'https://ghcr.io/v2/homebrew/core/swift-format/blobs/sha256:a32eef7ab3a18682cc5865060d25801dd948936704ff82f50cc0afeec1416ca9' \
  'a32eef7ab3a18682cc5865060d25801dd948936704ff82f50cc0afeec1416ca9' "$format_archive" \
  --header 'Authorization: Bearer QQ=='
tar -xzf "$format_archive" -C "$install_root"

download 'actionlint 1.7.12' \
  'https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_darwin_arm64.tar.gz' \
  'aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f' "$actionlint_archive"
mkdir "$install_root/actionlint"
tar -xzf "$actionlint_archive" -C "$install_root/actionlint"

download 'ShellCheck 0.11.0' \
  'https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.darwin.aarch64.tar.gz' \
  '339b930feb1ea764467013cc1f72d09cd6b869ebf1013296ba9055ab2ffbd26f' "$shellcheck_archive"
tar -xzf "$shellcheck_archive" -C "$install_root"

lint_bin="$install_root/swiftlint"
format_bin="$install_root/swift-format/603.0.0/bin"
actionlint_bin="$install_root/actionlint"
shellcheck_bin="$install_root/shellcheck-v0.11.0"
lint_version="$("$lint_bin/swiftlint" version)"
[[ "$lint_version" == '0.65.1' ]] || { echo "Unexpected SwiftLint version: $lint_version" >&2; exit 1; }
format_version="$("$format_bin/swift-format" --version)"
[[ "$format_version" == '603.0.0' ]] || { echo "Unexpected swift-format version: $format_version" >&2; exit 1; }
actionlint_version="$("$actionlint_bin/actionlint" -version)"
[[ "${actionlint_version%%$'\n'*}" == '1.7.12' ]] || { echo "Unexpected actionlint version: $actionlint_version" >&2; exit 1; }
shellcheck_version="$("$shellcheck_bin/shellcheck" --version)"
[[ "$shellcheck_version" == *$'\nversion: 0.11.0\n'* ]] || { echo "Unexpected ShellCheck version: $shellcheck_version" >&2; exit 1; }
rm -f "$lint_archive" "$format_archive" "$actionlint_archive" "$shellcheck_archive"
# Publish only after every tool validates; keep the binaries for later steps.
printf '%s\n' "$lint_bin" "$format_bin" "$actionlint_bin" "$shellcheck_bin" >> "$GITHUB_PATH"
installed=true
echo 'Installed SwiftLint 0.65.1, swift-format 603.0.0, actionlint 1.7.12 and ShellCheck 0.11.0 (verified SHA256 and versions).'
