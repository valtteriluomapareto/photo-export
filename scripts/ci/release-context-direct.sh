#!/usr/bin/env bash
# Compute direct-distribution context; publication remains gated by the workflow.
set -euo pipefail

echo "::group::Build context"
IS_TAG="false"
VERSION="0.0.0-dev"
IS_DRY_RUN="true"
SHOULD_CREATE_RELEASE="false"

if [[ "$GITHUB_REF" == refs/tags/v* ]]; then
  IS_TAG="true"
  VERSION="${GITHUB_REF#refs/tags/v}"
  echo "Version tag selected: v${VERSION}"
fi

# Ref identity never overrides a manual build-only request.
if [[ "$GITHUB_EVENT_NAME" == "push" && "$IS_TAG" == "true" ]]; then
  IS_DRY_RUN="false"
elif [[ "$GITHUB_EVENT_NAME" == "workflow_dispatch" && "${INPUT_DRY_RUN:-}" == "false" \
  && ( "$IS_TAG" == "true" || "$GITHUB_REF" == refs/heads/* ) ]]; then
  IS_DRY_RUN="false"
fi
if [[ "$IS_TAG" == "true" && "$IS_DRY_RUN" == "false" ]]; then
  SHOULD_CREATE_RELEASE="true"
fi

{
  echo "is_tag=${IS_TAG}"
  echo "version=${VERSION}"
  echo "is_dry_run=${IS_DRY_RUN}"
  echo "should_create_release=${SHOULD_CREATE_RELEASE}"
} >> "$GITHUB_OUTPUT"

echo "is_tag=${IS_TAG}"
echo "version=${VERSION}"
echo "is_dry_run=${IS_DRY_RUN}"
echo "should_create_release=${SHOULD_CREATE_RELEASE}"
echo "::endgroup::"
