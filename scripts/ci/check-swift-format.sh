#!/usr/bin/env bash
# Keep the local and CI formatter scope and explicit configuration together.
set -euo pipefail
cd "$(dirname "$0")/../.."

echo "Running strict swift-format lint on photo-export/ and photo-exportTests/..."
swift-format lint --strict --configuration .swift-format.json --recursive photo-export photo-exportTests
echo "swift-format lint passed."
