#!/usr/bin/env bash
# Build the app unsigned in the given configuration (Debug or Release). The full output is
# kept in <configuration>-build.log in the current directory; the failure-diagnostics step
# and the uploaded artifact read it from there.
#
# SWIFT_WARNINGS_AS_ERRORS=1 makes Swift compiler warnings in the app target fail the build
# (SWIFT_TREAT_WARNINGS_AS_ERRORS=YES) and writes the Debug log to debug-werror-build.log, so
# it never replaces a normal build's log. It is off by default; the release workflows never set it.
set -euo pipefail

configuration="${1:?usage: build-app.sh Debug|Release}"
case "${configuration}" in
  Debug) log=debug-build.log; shown=200 ;;
  Release) log=release-build.log; shown=20 ;;
  *) echo "::error::Unknown configuration '${configuration}'" >&2; exit 64 ;;
esac

settings=(CODE_SIGNING_ALLOWED=NO)
case "${SWIFT_WARNINGS_AS_ERRORS:-0}" in
  1) settings+=(SWIFT_TREAT_WARNINGS_AS_ERRORS=YES)
     log="${log%-build.log}-werror-build.log"
     warnings="Swift warnings are errors (SWIFT_WARNINGS_AS_ERRORS=1)" ;;
  0) warnings="Swift warnings are not errors (SWIFT_WARNINGS_AS_ERRORS is off)" ;;
  *) echo "::error::SWIFT_WARNINGS_AS_ERRORS must be 1 or 0, not '${SWIFT_WARNINGS_AS_ERRORS}'" >&2
     exit 64 ;;
esac

echo "::group::${configuration} build"
echo "Building ${configuration} configuration (${settings[*]})..."
echo "${warnings}; the full output goes to ${log}."
xcodebuild \
  -project photo-export.xcodeproj \
  -scheme "photo-export" \
  -configuration "${configuration}" \
  -destination 'platform=macOS' \
  "${settings[@]}" \
  build 2>&1 | tee "${log}" | tail -"${shown}"
echo "${configuration} build succeeded."
echo "::endgroup::"
