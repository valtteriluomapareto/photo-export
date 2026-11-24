#!/usr/bin/env bash
# Analyze every tracked shell script, preserving filename boundaries.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
command -v shellcheck >/dev/null || { echo 'ShellCheck (shellcheck) is required; run scripts/ci/install-ci-tools.sh.' >&2; exit 1; }
git ls-files -z -- '*.sh' | xargs -0 shellcheck --
echo 'Shell script validation passed.'
