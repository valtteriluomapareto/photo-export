#!/bin/bash
# Prepare project/website version changes for a reviewed PR. Never commit or tag.
# Usage: scripts/bump-version.sh <version> [--no-tag] [--skip-catalog-check]
# --no-tag remains an explicit alias for the preparation-only default.
# Prereleases use the base X.Y.Z catalog entry and website version.
set -euo pipefail

usage() {
  echo "Usage: $0 <version> [--no-tag] [--skip-catalog-check]"
}
if [[ $# -lt 1 ]]; then usage; exit 1; fi
NEW_VERSION="$1"
shift
SKIP_CATALOG_CHECK=false
for option in "$@"; do
  case "$option" in
    --no-tag) ;;
    --skip-catalog-check) SKIP_CATALOG_CHECK=true ;;
    *) echo "Error: Unknown option: $option"; usage; exit 1 ;;
  esac
done
if ! [[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]]; then
  echo "Error: Version must be in semver format (e.g. 1.2.0 or 1.3.0-beta.1)"
  exit 1
fi
CATALOG_VERSION="${NEW_VERSION%%-*}"
PROJECT_FILE="photo-export.xcodeproj/project.pbxproj"
WEBSITE_LAYOUT="website/src/layouts/MarketingLayout.astro"
CATALOG_FILE="photo-export/Models/ReleaseNotesCatalog.swift"
if [[ ! -f "$PROJECT_FILE" ]]; then
  echo "Error: $PROJECT_FILE not found. Run from the repo root."
  exit 1
fi
if [[ -f "$CATALOG_FILE" ]] && ! grep -Fq "version: \"$CATALOG_VERSION\"" "$CATALOG_FILE"; then
  echo "ReleaseNotesCatalog has no entry for $CATALOG_VERSION."
  echo "Add it before releasing; otherwise users see generic What's New copy."
  if [[ "$SKIP_CATALOG_CHECK" != true ]]; then
    if [[ -t 0 ]]; then
      read -r -p "Prepare changes anyway? [y/N] " REPLY
      if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then exit 1; fi
    else
      echo "Add the catalog entry or pass --skip-catalog-check explicitly."
      exit 1
    fi
  fi
fi

# Standard-library replacement works on macOS and Linux; leave the Git index alone.
python3 - "$NEW_VERSION" "$CATALOG_VERSION" "$PROJECT_FILE" "$WEBSITE_LAYOUT" <<'PY'
from pathlib import Path
import re
import sys
version, base, project_name, website_name = sys.argv[1:]
project = Path(project_name)
before = project.read_text()
after, count = re.subn(r"MARKETING_VERSION = [^;\n]+;", f"MARKETING_VERSION = {version};", before)
if not count:
    raise SystemExit("Error: No MARKETING_VERSION assignments found")
if before != after:
    project.write_text(after)
    print(f"Updated {count} MARKETING_VERSION entries to {version}")
else:
    print(f"Version is already {version}; checking the website version too.")
website = Path(website_name)
if website.is_file():
    before = website.read_text()
    after = re.sub(r"const softwareVersion = '[^']*';", f"const softwareVersion = '{base}';", before)
    if before != after:
        website.write_text(after)
        print(f"Updated website softwareVersion to {base}")
PY

echo ""
echo "Prepared changes only; no Git index, commit or tag changes."
echo "Review the diff, commit the intended release changes on a branch, and open a PR."
echo "After green CI and merge, validate the exact clean merged candidate."
echo "Then create the tag explicitly with git tag v${NEW_VERSION} at that candidate SHA."
echo "Same-version recovery also requires explicit tagging; this helper never recreates tags."
echo "Follow docs/project/release-process.md before any tag push."
