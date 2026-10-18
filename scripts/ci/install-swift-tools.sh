#!/bin/bash
# Exact tools for macOS15+ arm64 with Command Line Tools installed (the CI image).
# SwiftLint: https://github.com/realm/SwiftLint/releases/tag/0.65.1
# swift-format bottle: Homebrew/homebrew-core@919ebb6e47be295a336446ea3e5a4a6637871748
# https://github.com/Homebrew/homebrew-core/blob/919ebb6e47be295a336446ea3e5a4a6637871748/Formula/s/swift-format.rb
# arm64_sequoia, no runtime dependencies, CLT required.
set -euo pipefail
: "${RUNNER_TEMP:?RUNNER_TEMP must name a writable temporary directory}"
: "${GITHUB_PATH:?GITHUB_PATH must name the path output file}"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo "Pinned Swift tools require macOS15+ arm64 with Command Line Tools installed." >&2
  exit 1
fi
macos_version="$(sw_vers -productVersion)"
if [[ "${macos_version%%.*}" -lt 15 ]]; then
  echo "Pinned Swift tools require macOS15 or later." >&2
  exit 1
fi
install_root="$(mktemp -d "${RUNNER_TEMP}/swift-tools.XXXXXX")"
installed=false
trap 'if [[ "$installed" != true ]]; then rm -rf "$install_root"; fi' EXIT
lint_archive="$install_root/swiftlint.zip"
format_archive="$install_root/swift-format.tar.gz"

curl --fail --location --retry 3 --silent --show-error \
  'https://github.com/realm/SwiftLint/releases/download/0.65.1/portable_swiftlint.zip' \
  --output "$lint_archive"
printf '%s  %s\n' 'c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0' "$lint_archive" | shasum -a 256 -c
unzip -q "$lint_archive" -d "$install_root/swiftlint"

# GHCR's public anonymous token, not a signing credential or repository secret.
curl --fail --location --retry 3 --silent --show-error --header 'Authorization: Bearer QQ==' \
  'https://ghcr.io/v2/homebrew/core/swift-format/blobs/sha256:a32eef7ab3a18682cc5865060d25801dd948936704ff82f50cc0afeec1416ca9' \
  --output "$format_archive"
printf '%s  %s\n' 'a32eef7ab3a18682cc5865060d25801dd948936704ff82f50cc0afeec1416ca9' "$format_archive" | shasum -a 256 -c
tar -xzf "$format_archive" -C "$install_root"

lint_bin="$install_root/swiftlint"
format_bin="$install_root/swift-format/603.0.0/bin"
lint_version="$("$lint_bin/swiftlint" version)"
[[ "$lint_version" == '0.65.1' ]] || { echo 'Unexpected SwiftLint version' >&2; exit 1; }
format_version="$("$format_bin/swift-format" --version)"
[[ "$format_version" == '603.0.0' ]] || { echo 'Unexpected swift-format version' >&2; exit 1; }
rm -f "$lint_archive" "$format_archive"
# Publish only after both complete tools validate; keep their binaries for later steps.
printf '%s\n' "$lint_bin" "$format_bin" >> "$GITHUB_PATH"
installed=true
echo 'Installed SwiftLint 0.65.1 and swift-format 603.0.0 (verified SHA256 and versions).'
