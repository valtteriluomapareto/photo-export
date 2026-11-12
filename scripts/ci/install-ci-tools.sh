#!/usr/bin/env bash
# Pinned native CI validators for the macOS arm64 runner.
# https://github.com/rhysd/actionlint/releases/tag/v1.7.12
# https://github.com/koalaman/shellcheck/releases/tag/v0.11.0
set -euo pipefail
: "${RUNNER_TEMP:?RUNNER_TEMP must name a writable temporary directory}"
: "${GITHUB_PATH:?GITHUB_PATH must name the path output file}"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo "Pinned CI tools require macOS arm64." >&2
  exit 1
fi

install_root="$(mktemp -d "${RUNNER_TEMP}/ci-tools.XXXXXX")"
installed=false
trap 'if [[ "$installed" != true ]]; then rm -rf "$install_root"; fi' EXIT
actionlint_archive="$install_root/actionlint.tar.gz"
shellcheck_archive="$install_root/shellcheck.tar.gz"

curl --fail --location --retry 3 --silent --show-error \
  'https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_darwin_arm64.tar.gz' \
  --output "$actionlint_archive"
printf '%s  %s\n' 'aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f' "$actionlint_archive" | shasum -a 256 -c
mkdir "$install_root/actionlint"
tar -xzf "$actionlint_archive" -C "$install_root/actionlint"

curl --fail --location --retry 3 --silent --show-error \
  'https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.darwin.aarch64.tar.gz' \
  --output "$shellcheck_archive"
printf '%s  %s\n' '339b930feb1ea764467013cc1f72d09cd6b869ebf1013296ba9055ab2ffbd26f' "$shellcheck_archive" | shasum -a 256 -c
tar -xzf "$shellcheck_archive" -C "$install_root"

actionlint_bin="$install_root/actionlint"
shellcheck_bin="$install_root/shellcheck-v0.11.0"
actionlint_version="$("$actionlint_bin/actionlint" -version)"
[[ "${actionlint_version%%$'\n'*}" == '1.7.12' ]] || { echo 'Unexpected actionlint version' >&2; exit 1; }
shellcheck_version="$("$shellcheck_bin/shellcheck" --version)"
[[ "$shellcheck_version" == *$'\nversion: 0.11.0\n'* ]] || { echo 'Unexpected ShellCheck version' >&2; exit 1; }
rm -f "$actionlint_archive" "$shellcheck_archive"
# Publish the pair only after both checksums, extractions and version commands succeed.
printf '%s\n' "$actionlint_bin" "$shellcheck_bin" >> "$GITHUB_PATH"
installed=true
echo 'Installed actionlint 1.7.12 and ShellCheck 0.11.0 (verified SHA256 and versions).'
