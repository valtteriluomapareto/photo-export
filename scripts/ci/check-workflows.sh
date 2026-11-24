#!/usr/bin/env bash
# Native GitHub Actions validation includes ShellCheck for embedded shell steps.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
command -v actionlint >/dev/null || { echo 'actionlint is required; run scripts/ci/install-ci-tools.sh.' >&2; exit 1; }
shellcheck_bin="$(command -v shellcheck)" || { echo 'ShellCheck (shellcheck) is required; run scripts/ci/install-ci-tools.sh.' >&2; exit 1; }
actionlint -shellcheck "$shellcheck_bin"
echo 'Workflow validation passed.'
