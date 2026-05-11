#!/bin/bash
# Bump MARKETING_VERSION in project.pbxproj and create a git tag.
#
# Usage:
#   scripts/bump-version.sh 1.2.0           # set version, auto-tag v1.2.0
#   scripts/bump-version.sh 1.2.0 --no-tag  # set version only
#   scripts/bump-version.sh 1.3.0-beta.1    # pre-release; auto-tag v1.3.0-beta.1
#
# Pre-release tags (`X.Y.Z-<suffix>`) are handled specially downstream:
#   - The GitHub Releases workflow marks the release as a pre-release.
#   - The App Store Connect workflow is skipped (App Store rejects
#     hyphen-suffixed CFBundleShortVersionString).
#   - The catalog check below looks up the base `X.Y.Z` entry, since
#     betas of the same release reuse the stable's release notes.

set -euo pipefail

PROJECT_FILE="photo-export.xcodeproj/project.pbxproj"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <version> [--no-tag]"
  echo "Example: $0 1.2.0"
  echo "Example: $0 1.3.0-beta.1   # pre-release"
  exit 1
fi

NEW_VERSION="$1"
NO_TAG="${2:-}"

# Validate version format. Accepts strict semver (`X.Y.Z`) plus an
# optional pre-release suffix (`X.Y.Z-<identifier>`), e.g. `1.3.0-beta.1`.
if ! [[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]]; then
  echo "Error: Version must be in semver format (e.g. 1.2.0 or 1.3.0-beta.1)"
  exit 1
fi

# Pre-release detection: betas share the catalog entry of their base
# release rather than each suffix needing its own. `CATALOG_VERSION` is
# the version we expect to find in `ReleaseNotesCatalog.swift`.
CATALOG_VERSION="${NEW_VERSION%%-*}"
IS_PRERELEASE="false"
if [[ "$NEW_VERSION" != "$CATALOG_VERSION" ]]; then
  IS_PRERELEASE="true"
fi

if [[ ! -f "$PROJECT_FILE" ]]; then
  echo "Error: $PROJECT_FILE not found. Run from the repo root."
  exit 1
fi

# Catalog-entry check. The in-app "What's New" sheet reads from
# `ReleaseNotesCatalog.swift`; if the new version is missing from the
# catalog, users on the upgrade path see a generic "Photo Export has been
# updated — see release notes on GitHub" message instead of the
# release-specific highlights. Not fatal (the sheet still works) but
# almost always wrong — flag it loudly here so the maintainer notices
# before pushing the tag.
CATALOG_FILE="photo-export/Models/ReleaseNotesCatalog.swift"
if [[ -f "$CATALOG_FILE" ]]; then
  if ! grep -q "version: \"$CATALOG_VERSION\"" "$CATALOG_FILE"; then
    echo ""
    echo "⚠️  ReleaseNotesCatalog has no entry for $CATALOG_VERSION."
    echo "    Users upgrading will see the generic fallback message."
    echo "    Edit $CATALOG_FILE and append a ReleaseNote(version: \"$CATALOG_VERSION\", …)"
    echo "    before pushing the tag. See docs/project/release-process.md step 1."
    echo ""
    if [[ -t 0 ]]; then
      read -r -p "Proceed anyway? [y/N] " REPLY
      if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
        echo "Aborted. Add the catalog entry, then re-run this script."
        exit 1
      fi
    else
      echo "(non-interactive shell — pass --skip-catalog-check to suppress, or add the entry)"
      if [[ "${3:-}" != "--skip-catalog-check" && "$NO_TAG" != "--skip-catalog-check" ]]; then
        exit 1
      fi
    fi
  fi
fi

# Read current version
CURRENT_VERSION=$(grep -m1 'MARKETING_VERSION' "$PROJECT_FILE" | sed 's/.*= *\(.*\);/\1/')
echo "Current version: $CURRENT_VERSION"
echo "New version:     $NEW_VERSION"

if [[ "$CURRENT_VERSION" == "$NEW_VERSION" ]]; then
  echo "Version is already $NEW_VERSION — nothing to do."
  exit 0
fi

# Replace all occurrences of MARKETING_VERSION
sed -i '' "s/MARKETING_VERSION = $CURRENT_VERSION;/MARKETING_VERSION = $NEW_VERSION;/g" "$PROJECT_FILE"

UPDATED=$(grep -c "MARKETING_VERSION = $NEW_VERSION;" "$PROJECT_FILE")
echo "Updated $UPDATED MARKETING_VERSION entries to $NEW_VERSION"

if [[ "$NO_TAG" == "--no-tag" ]]; then
  echo "Skipping tag (--no-tag)."
  echo ""
  echo "Next steps:"
  echo "  git add $PROJECT_FILE"
  echo "  git commit -m \"Bump version to $NEW_VERSION\""
  exit 0
fi

# Commit and tag
git add "$PROJECT_FILE"
git commit -m "Bump version to $NEW_VERSION"
git tag "v$NEW_VERSION"

echo ""
echo "Committed and tagged v$NEW_VERSION."
if [[ "$IS_PRERELEASE" == "true" ]]; then
  echo ""
  echo "Pre-release tag detected:"
  echo "  - GitHub Releases will publish as a pre-release (marked unstable)."
  echo "  - App Store Connect upload is skipped (not supported for hyphen-suffixed versions)."
fi
echo "Push with: git push && git push origin v$NEW_VERSION"
