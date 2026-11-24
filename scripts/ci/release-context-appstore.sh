#!/usr/bin/env bash
# Compute App Store context; publication remains gated by the workflow.
set -euo pipefail

echo "::group::Build context"
IS_TAG="false"
SHOULD_UPLOAD="false"

if [[ "$GITHUB_REF" == refs/tags/v* ]]; then
  IS_TAG="true"
  VERSION="${GITHUB_REF#refs/tags/v}"
  echo "Version tag selected: v${VERSION}"
fi

# For non-tag runs, read version from project.pbxproj
if [[ "${IS_TAG}" != "true" ]]; then
  VERSION=$(grep -m1 'MARKETING_VERSION' photo-export.xcodeproj/project.pbxproj | sed 's/.*= *\(.*\);/\1/')
  echo "Using MARKETING_VERSION from project: ${VERSION}"
fi

# Only an automatic tag push or an explicit manual opt-in may upload.
if [[ "$GITHUB_EVENT_NAME" == "push" && "$IS_TAG" == "true" ]]; then
  SHOULD_UPLOAD="true"
elif [[ "$GITHUB_EVENT_NAME" == "workflow_dispatch" && "${INPUT_SKIP_UPLOAD:-}" == "false" \
  && ( "$IS_TAG" == "true" || "$GITHUB_REF" == refs/heads/* ) ]]; then
  SHOULD_UPLOAD="true"
fi
# Branch dispatches can also contain a prerelease project version.
if [[ "$VERSION" == *-* ]]; then
  SHOULD_UPLOAD="false"
fi

BUILD_NUMBER="${GITHUB_RUN_NUMBER}.${GITHUB_RUN_ATTEMPT}"

{
  echo "is_tag=${IS_TAG}"
  echo "version=${VERSION}"
  echo "should_upload=${SHOULD_UPLOAD}"
  echo "build_number=${BUILD_NUMBER}"
} >> "$GITHUB_OUTPUT"

echo ""
echo "Summary:"
echo "  is_tag=${IS_TAG}"
echo "  version=${VERSION}"
echo "  build_number=${BUILD_NUMBER}"
echo "  should_upload=${SHOULD_UPLOAD}"
echo "::endgroup::"
