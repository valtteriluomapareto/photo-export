#!/usr/bin/env bash
# Exercise the actual guards using disposable fixtures. The release-row tests also
# check that every file in the app tree is mapped to a validation row.
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 -B -m unittest discover -s scripts/ci/tests -p 'test_*.py'
python3 -B -m unittest discover -s scripts/release/tests -p 'test_*.py'
./scripts/ci/check-fingerprint-id-keying.sh --self-test
