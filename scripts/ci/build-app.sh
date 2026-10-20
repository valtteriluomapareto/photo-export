#!/usr/bin/env bash
# Build the app unsigned in the given configuration (Debug or Release). The full output is
# kept in <configuration>-build.log in the current directory; the failure-diagnostics step
# and the uploaded artifact read it from there.
#
# SWIFT_WARNINGS_AS_ERRORS=1 makes Swift compiler warnings fail the build
# (SWIFT_TREAT_WARNINGS_AS_ERRORS=YES). It is off by default; the release workflows never set it.
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
     warnings="Swift warnings are errors (SWIFT_WARNINGS_AS_ERRORS=1)" ;;
  0|"") warnings="Swift warnings are not errors (SWIFT_WARNINGS_AS_ERRORS is off)" ;;
  *) echo "::error::SWIFT_WARNINGS_AS_ERRORS must be 1 or 0, not '${SWIFT_WARNINGS_AS_ERRORS}'" >&2
     exit 64 ;;
esac

echo "::group::${configuration} build"
echo "Building ${configuration} configuration (${settings[*]})..."
echo "${warnings}."
status=0
xcodebuild \
  -project photo-export.xcodeproj \
  -scheme "photo-export" \
  -configuration "${configuration}" \
  -destination 'platform=macOS' \
  "${settings[@]}" \
  build 2>&1 | tee "${log}" | tail -"${shown}" || status=$?
echo "::endgroup::"

if [[ "${status}" -ne 0 ]]; then
  # The tail above can cut off the first errors, so print each distinct error line from the
  # full log, without the source-snippet copies the compiler adds under it.
  echo "::group::${configuration} build errors (every error: line in ${log})"
  awk '/(^|: )error:/ && !seen[$0]++' "${log}" || true
  echo "::endgroup::"
  echo "::error::${configuration} build failed with status ${status}; the full output is in ${log}."
  exit "${status}"
fi
echo "${configuration} build succeeded."
