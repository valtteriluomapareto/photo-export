#!/usr/bin/env bash
# Build the app unsigned in the given configuration (Debug or Release). The full output is
# kept in <configuration>-build.log in the current directory; the failure-diagnostics step
# and the uploaded artifact read it from there.
set -euo pipefail

configuration="${1:?usage: build-app.sh Debug|Release}"
case "${configuration}" in
  Debug) log=debug-build.log; shown=200 ;;
  Release) log=release-build.log; shown=20 ;;
  *) echo "::error::Unknown configuration '${configuration}'" >&2; exit 64 ;;
esac

echo "::group::${configuration} build"
echo "Building ${configuration} configuration (CODE_SIGNING_ALLOWED=NO)..."
xcodebuild \
  -project photo-export.xcodeproj \
  -scheme "photo-export" \
  -configuration "${configuration}" \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tee "${log}" | tail -"${shown}"
echo "${configuration} build succeeded."
echo "::endgroup::"
