#!/usr/bin/env bash
# Check that the selected Xcode's altool can still upload packages to App Store Connect, so a
# toolchain that dropped `--upload-package` fails a build-only run instead of the release upload.
# Needs no credentials.
set -euo pipefail

echo "::group::altool upload support"
echo "Developer directory: $(xcode-select -p)"
# Capture first: `altool --help` may exit non-zero, and grep -q closing the pipe early would
# otherwise read as a missing flag.
help="$(xcrun altool --help 2>&1 || true)"
if ! grep -q -- '--upload-package' <<< "${help}"; then
  echo "${help}" | head -40
  echo "::error::xcrun altool has no --upload-package; switch uploads to iTMSTransporter or the App Store Connect API"
  exit 1
fi
echo "xcrun altool supports --upload-package."
echo "::endgroup::"
