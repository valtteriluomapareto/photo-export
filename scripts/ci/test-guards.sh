#!/usr/bin/env bash
# Exercise the actual guards using disposable fixtures, never the working tree.
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 -B -m unittest discover -s scripts/ci/tests -p 'test_*.py'
./scripts/ci/check-fingerprint-id-keying.sh --self-test
